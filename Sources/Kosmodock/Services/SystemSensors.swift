import Darwin
import Foundation
import IOKit
import IOKit.ps

struct BatteryStatus: Equatable, Sendable {
    var percent: Int
    var isCharging: Bool
    var isPluggedIn: Bool
    var isCharged: Bool
    /// To empty on battery, to full while charging; `nil` while macOS estimates.
    var minutesRemaining: Int?
    var cycleCount: Int?
}

/// The internal battery, read from IOKit's power sources.
enum PowerSource {
    /// `nil` on Macs without a battery.
    static func battery() -> BatteryStatus? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }
            return status(from: description, cycleCount: cycleCount())
        }
        return nil
    }

    /// Separate from IOKit so the mapping can be tested.
    static func status(from description: [String: Any], cycleCount: Int?) -> BatteryStatus {
        let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
        let maximum = description[kIOPSMaxCapacityKey] as? Int ?? 100
        let charging = description[kIOPSIsChargingKey] as? Bool ?? false
        let minutes = description[charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? Int
        return BatteryStatus(
            percent: maximum > 0 ? Int((Double(current) / Double(maximum) * 100).rounded()) : current,
            isCharging: charging,
            isPluggedIn: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
            isCharged: description[kIOPSIsChargedKey] as? Bool ?? false,
            // -1 while estimating, 0 when there's nothing to estimate.
            minutesRemaining: minutes.flatMap { $0 > 0 ? $0 : nil },
            cycleCount: cycleCount
        )
    }

    private static func cycleCount() -> Int? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "CycleCount" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Int
    }
}

/// Bytes moved by the network interfaces, as macOS counts them since boot.
enum NetworkCounters {
    struct Totals: Equatable, Sendable {
        var received: UInt64
        var sent: UInt64
    }

    /// Ethernet-type interfaces only (Wi-Fi, Ethernet, Thunderbolt), so VPN
    /// tunnels and VM bridges don't count the same traffic twice.
    static func totals() -> Totals? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return nil }

        var totals = Totals(received: 0, sent: 0)
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                    let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if Int32(message.ifm_data.ifi_type) == IFT_ETHER, counts(interface: message.ifm_index) {
                        totals.received &+= message.ifm_data.ifi_ibytes
                        totals.sent &+= message.ifm_data.ifi_obytes
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return totals
    }

    /// Podman's and Docker's VM interfaces are Ethernet-type too.
    private static func counts(interface index: UInt16) -> Bool {
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        guard if_indextoname(UInt32(index), &name) != nil else { return false }
        let text = String(cString: name)
        return !text.hasPrefix("vmenet") && !text.hasPrefix("bridge")
    }
}

/// Download and upload speed between two readings, plus what moved since the
/// first one.
struct NetworkRate: Equatable, Sendable {
    var receivedPerSecond: Double = 0
    var sentPerSecond: Double = 0
    var receivedSinceStart: UInt64 = 0
    var sentSinceStart: UInt64 = 0
}
