import Foundation
import Observation

/// Polls system metrics, per-group process usage, listening ports and custom
/// commands, publishing only values that actually changed so the dock doesn't
/// re-render on every tick.
@MainActor
@Observable
final class TelemetryService {
    private(set) var system = SystemSnapshot()
    /// Usage per bundle identifier (app + child processes).
    private(set) var appUsage: [String: ResourceUsage] = [:]
    /// Usage of the Podman/Docker VM processes.
    private(set) var vmUsage: ResourceUsage?
    /// Listening TCP port → owning process name ("" when only reachable).
    private(set) var listeningPorts: [Int: String] = [:]
    /// Custom command and command-probe results keyed by `commandKey`.
    private(set) var commandResults: [String: ProbeResult] = [:]
    /// Read only while a battery tile is on the bar.
    private(set) var battery: BatteryStatus?
    /// Measured only while a network tile is on the bar.
    private(set) var network: NetworkRate?

    @ObservationIgnored private let configService: ConfigService
    @ObservationIgnored private let workspace: WorkspaceService
    @ObservationIgnored private let sampler = MetricsSampler()
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var isSampling = false
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var lastRun: [String: Date] = [:]
    @ObservationIgnored private var networkFirst: NetworkCounters.Totals?
    @ObservationIgnored private var networkLast: (totals: NetworkCounters.Totals, at: ContinuousClock.Instant)?

    init(configService: ConfigService, workspace: WorkspaceService) {
        self.configService = configService
        self.workspace = workspace
    }

    func start() {
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sample()
                let interval = max(1, self.configService.config.telemetry.pollInterval)
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    func refreshNow() {
        Task { await sample() }
    }

    static func commandKey(group: DockGroup) -> String { group.id }
    /// Group ids are slugs without a colon, so tile keys never collide with them.
    static func commandKey(tile: DockTile) -> String { "tile:\(tile.id)" }
    static func commandKey(group: DockGroup, probe: HealthProbe) -> String { "\(group.id)/\(probe.id)" }

    func isListening(_ port: Int) -> Bool { listeningPorts[port] != nil }

    /// Forces the group's command and command probes to run immediately.
    func runCommandsNow(for group: DockGroup) {
        lastRun[Self.commandKey(group: group)] = nil
        for probe in group.widget.probes { lastRun[Self.commandKey(group: group, probe: probe)] = nil }
        scheduleCommands(for: [group])
    }

    /// Forces a command tile to run immediately.
    func runCommandNow(for tile: DockTile) {
        lastRun[Self.commandKey(tile: tile)] = nil
        scheduleCommands(for: [], tiles: [tile])
    }

    // MARK: Sampling

    private func sample() async {
        guard !isSampling else { return }
        isSampling = true
        defer { isSampling = false }

        let groups = configService.config.groups
        var roots: [String: [pid_t]] = [:]
        for group in groups {
            for app in group.apps {
                guard let id = workspace.bundleID(for: app), let state = workspace.states[id] else { continue }
                roots[id] = state.pids
            }
        }
        let includeVM = groups.contains { $0.widget.type == .podman }
        var wantedPorts = Set<Int>()
        for group in groups {
            if group.widget.type == .portProbe { wantedPorts.formUnion(group.widget.ports) }
            wantedPorts.formUnion(group.widget.probes.compactMap(\.port))
        }

        let sampler = self.sampler
        let rootPIDs = roots
        let portsToScan = wantedPorts
        async let metrics = sampler.sample(roots: rootPIDs, includeVM: includeVM)
        async let ports = PortScanner.scan(wanted: portsToScan)
        let (sample, scannedPorts) = await (metrics, ports)

        if sample.system != system { system = sample.system }
        if sample.apps != appUsage { appUsage = sample.apps }
        if sample.vm != vmUsage { vmUsage = sample.vm }
        if scannedPorts != listeningPorts { listeningPorts = scannedPorts }

        let tiles = configService.config.tiles
        sampleSensors(for: tiles)
        scheduleCommands(for: groups, tiles: tiles)
        pruneCommandResults(groups, tiles: tiles)
    }

    private func sampleSensors(for tiles: [DockTile]) {
        let kinds = Set(tiles.map(\.kind))
        let nextBattery = kinds.contains(.battery) ? PowerSource.battery() : nil
        if nextBattery != battery { battery = nextBattery }

        guard kinds.contains(.network), let totals = NetworkCounters.totals() else {
            if network != nil { network = nil }
            networkFirst = nil
            networkLast = nil
            return
        }
        let now = ContinuousClock.now
        let first = networkFirst ?? totals
        networkFirst = first
        var rate = network ?? NetworkRate()
        if let last = networkLast {
            let seconds = (now - last.at) / .seconds(1)
            // Counters only go back when an interface resets; skip that reading.
            if seconds > 0, totals.received >= last.totals.received, totals.sent >= last.totals.sent {
                rate.receivedPerSecond = Double(totals.received - last.totals.received) / seconds
                rate.sentPerSecond = Double(totals.sent - last.totals.sent) / seconds
            }
        }
        rate.receivedSinceStart = totals.received >= first.received ? totals.received - first.received : 0
        rate.sentSinceStart = totals.sent >= first.sent ? totals.sent - first.sent : 0
        networkLast = (totals, now)
        if rate != network { network = rate }
    }

    private func scheduleCommands(for groups: [DockGroup], tiles: [DockTile] = []) {
        let settings = configService.config.telemetry
        for tile in tiles where tile.kind == .command {
            guard let command = tile.command, !command.isBlank else { continue }
            let interval = max(1, tile.interval ?? settings.pollInterval)
            run(command, key: Self.commandKey(tile: tile), interval: interval, timeout: settings.commandTimeout)
        }
        for group in groups {
            let interval = max(1, group.widget.interval ?? settings.pollInterval)
            if group.widget.type == .customCommand, let command = group.widget.command, !command.isBlank {
                run(command, key: Self.commandKey(group: group), interval: interval, timeout: settings.commandTimeout)
            }
            for probe in group.widget.probes {
                guard let command = probe.command, !command.isBlank else { continue }
                run(command, key: Self.commandKey(group: group, probe: probe), interval: interval, timeout: settings.commandTimeout)
            }
        }
    }

    private func run(_ command: String, key: String, interval: Double, timeout: Double) {
        guard !inFlight.contains(key) else { return }
        if let last = lastRun[key], Date().timeIntervalSince(last) < interval - 0.25 { return }
        inFlight.insert(key)
        lastRun[key] = Date()
        Task { [weak self] in
            let result = ProbeResult(shell: await ShellRunner.shell(command, timeout: max(1, timeout)))
            guard let self else { return }
            self.inFlight.remove(key)
            if self.commandResults[key] != result || self.commandResults[key] == nil {
                self.commandResults[key] = result
            }
        }
    }

    private func pruneCommandResults(_ groups: [DockGroup], tiles: [DockTile]) {
        var valid = Set(tiles.map(Self.commandKey(tile:)))
        for group in groups {
            valid.insert(Self.commandKey(group: group))
            for probe in group.widget.probes { valid.insert(Self.commandKey(group: group, probe: probe)) }
        }
        let stale = commandResults.keys.filter { !valid.contains($0) }
        guard !stale.isEmpty else { return }
        for key in stale {
            commandResults[key] = nil
            lastRun[key] = nil
        }
    }
}

extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
