import Darwin
import Foundation

struct MetricsSample: Sendable {
    var system: SystemSnapshot
    /// Usage per bundle identifier, including each app's child processes.
    var apps: [String: ResourceUsage]
    /// Aggregate usage of the container VM processes, when requested.
    var vm: ResourceUsage?
}

/// Samples global and per-process metrics with Mach/libproc. CPU percentages
/// are deltas between consecutive samples, so the actor keeps the previous
/// tick counters.
actor MetricsSampler {
    private struct CPUTicks {
        var busy: UInt64
        var total: UInt64
    }

    private struct ProcessEntry {
        var parent: pid_t
        var name: String
    }

    /// Process names belonging to Podman/Docker/Virtualization.framework VMs.
    static let vmProcessNames: Set<String> = ["vfkit", "krunkit", "gvproxy", "qemu-system-aarch64", "qemu-system-x86_64"]
    static let vmProcessPrefixes = ["com.apple.Virtualization.", "com.docker.virtualization"]

    private let host = mach_host_self()
    private let pageSize = UInt64(getpagesize())
    private let timebase: mach_timebase_info_data_t
    private var previousTicks: [CPUTicks] = []
    private var previousProcessTimes: [pid_t: UInt64] = [:]
    private var previousTimestamp: UInt64 = 0

    init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        timebase = info
    }

    func sample(roots: [String: [pid_t]], includeVM: Bool) -> MetricsSample {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = previousTimestamp == 0 ? 0 : now - previousTimestamp
        previousTimestamp = now

        var system = SystemSnapshot()
        system.cpuPercent = sampleCPU()
        sampleMemory(into: &system)
        system.pressure = Self.memoryPressure()
        system.swapUsed = Self.swapUsed()
        var load = [Double](repeating: 0, count: 3)
        if getloadavg(&load, 3) > 0 { system.loadAverage = load[0] }

        let table = Self.processTable()
        var children: [pid_t: [pid_t]] = [:]
        for (pid, entry) in table { children[entry.parent, default: []].append(pid) }

        let cores = Double(max(1, system.coreCount))
        var currentTimes: [pid_t: UInt64] = [:]

        func usage(of pids: some Sequence<pid_t>) -> ResourceUsage {
            var total = ResourceUsage()
            for pid in pids {
                guard let info = Self.rusage(pid) else { continue }
                let cpuNanos = toNanoseconds(info.ri_user_time + info.ri_system_time)
                currentTimes[pid] = cpuNanos
                if elapsed > 0, let previous = previousProcessTimes[pid], cpuNanos >= previous {
                    total.cpuPercent += Double(cpuNanos - previous) / Double(elapsed) * 100 / cores
                }
                total.memoryBytes += info.ri_phys_footprint
                total.processCount += 1
            }
            return total
        }

        var apps: [String: ResourceUsage] = [:]
        for (bundleID, rootPIDs) in roots {
            apps[bundleID] = usage(of: Self.descendants(of: rootPIDs, children: children))
        }

        var vm: ResourceUsage?
        if includeVM {
            let vmPIDs = table.compactMap { pid, entry -> pid_t? in
                let isVM = Self.vmProcessNames.contains(entry.name)
                    || Self.vmProcessPrefixes.contains { entry.name.hasPrefix($0) }
                return isVM ? pid : nil
            }
            vm = vmPIDs.isEmpty ? nil : usage(of: vmPIDs)
        }

        previousProcessTimes = currentTimes
        return MetricsSample(system: system, apps: apps, vm: vm)
    }

    // MARK: CPU & memory

    private func sampleCPU() -> Double {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return 0 }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        var ticks: [CPUTicks] = []
        ticks.reserveCapacity(Int(cpuCount))
        for cpu in 0..<Int(cpuCount) {
            let base = cpu * Int(CPU_STATE_MAX)
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            ticks.append(CPUTicks(busy: user + system + nice, total: user + system + nice + idle))
        }
        defer { previousTicks = ticks }
        guard previousTicks.count == ticks.count else { return 0 }

        var busy: UInt64 = 0
        var total: UInt64 = 0
        for (now, before) in zip(ticks, previousTicks) where now.total >= before.total && now.busy >= before.busy {
            busy += now.busy - before.busy
            total += now.total - before.total
        }
        return total == 0 ? 0 : Double(busy) / Double(total) * 100
    }

    /// Mirrors Activity Monitor's "Memory Used": app memory + wired + compressed.
    private func sampleMemory(into snapshot: inout SystemSnapshot) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        let appPages = UInt64(stats.internal_page_count) - min(UInt64(stats.internal_page_count), UInt64(stats.purgeable_count))
        let used = (appPages + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * pageSize
        snapshot.memoryUsed = min(used, snapshot.memoryTotal)
    }

    private static func memoryPressure() -> MemoryPressure {
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        return MemoryPressure(rawValue: Int(level)) ?? .normal
    }

    private static func swapUsed() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return usage.xsu_used
    }

    // MARK: Processes

    private static func processTable() -> [pid_t: ProcessEntry] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [:] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return [:] }

        var table: [pid_t: ProcessEntry] = [:]
        table.reserveCapacity(Int(count))
        let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, infoSize) == infoSize else { continue }
            var name = cString(info.pbi_name)
            if name.isEmpty { name = cString(info.pbi_comm) }
            table[pid] = ProcessEntry(parent: pid_t(info.pbi_ppid), name: name)
        }
        return table
    }

    private static func cString<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private static func descendants(of roots: [pid_t], children: [pid_t: [pid_t]]) -> Set<pid_t> {
        var result = Set<pid_t>()
        var stack = roots
        while let pid = stack.popLast() {
            guard result.insert(pid).inserted else { continue }
            stack.append(contentsOf: children[pid] ?? [])
        }
        return result
    }

    private static func rusage(_ pid: pid_t) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? info : nil
    }

    /// `ri_user_time`/`ri_system_time` are Mach ticks on Apple Silicon.
    private func toNanoseconds(_ ticks: UInt64) -> UInt64 {
        guard timebase.denom != 0 else { return ticks }
        return ticks / UInt64(timebase.denom) * UInt64(timebase.numer)
            + (ticks % UInt64(timebase.denom)) * UInt64(timebase.numer) / UInt64(timebase.denom)
    }
}

/// Discovers listening TCP ports with `lsof`, falling back to a localhost
/// connect for ports owned by processes lsof can't see (other users / root).
enum PortScanner {
    static func scan(wanted: Set<Int>) async -> [Int: String] {
        guard !wanted.isEmpty else { return [:] }
        let result = await ShellRunner.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"], timeout: 8)
        var ports = parse(result.stdout)
        for port in wanted where ports[port] == nil && isReachable(port: port) {
            ports[port] = ""
        }
        return ports
    }

    /// Parses `lsof -F pcn` output into port → command name.
    static func parse(_ output: String) -> [Int: String] {
        var ports: [Int: String] = [:]
        var command = ""
        for line in output.split(whereSeparator: \.isNewline) {
            guard let tag = line.first else { continue }
            let value = line.dropFirst()
            switch tag {
            case "p": command = ""
            case "c": command = String(value)
            case "n":
                guard let colon = value.lastIndex(of: ":"),
                      let port = Int(value[value.index(after: colon)...]) else { continue }
                if ports[port] == nil || ports[port]?.isEmpty == true { ports[port] = command }
            default: continue
            }
        }
        return ports
    }

    static func isReachable(port: Int, timeoutMilliseconds: Int32 = 200) -> Bool {
        guard (1...65535).contains(port) else { return false }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL, 0) | O_NONBLOCK)

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connected == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var poller = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        guard poll(&poller, 1, timeoutMilliseconds) > 0 else { return false }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &length)
        return error == 0
    }
}
