import Foundation
import Observation

/// Monitors and controls Podman (or Docker) from the dock: VM status, the
/// container list, and start/stop/restart actions.
@MainActor
@Observable
final class ContainerMonitorService {
    static let machineKey = "__machine__"

    private(set) var runtime: ContainerRuntime?
    private(set) var status: MachineStatus = .unknown
    private(set) var machine: PodmanMachine?
    private(set) var containers: [ContainerInfo] = []
    /// Container ids (and `machineKey`) with an action in flight.
    private(set) var busyIDs: Set<String> = []
    private(set) var machineOperation: MachineOperation?
    private(set) var lastError: String?
    private(set) var isEnabled = false

    @ObservationIgnored private let configService: ConfigService
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var needsAnotherRefresh = false

    init(configService: ConfigService) {
        self.configService = configService
    }

    var runningCount: Int { containers.filter(\.isRunning).count }

    /// Polling only runs while at least one group uses the Podman widget.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        loopTask?.cancel()
        loopTask = nil
        guard enabled else { return }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let interval = max(3, self.configService.config.telemetry.pollInterval)
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// Refreshes state; concurrent calls coalesce into one extra pass.
    func refresh() async {
        if isRefreshing {
            needsAnotherRefresh = true
            return
        }
        isRefreshing = true
        repeat {
            needsAnotherRefresh = false
            await performRefresh()
        } while needsAnotherRefresh
        isRefreshing = false
    }

    // MARK: Actions

    func perform(_ action: ContainerAction, on container: ContainerInfo) async {
        guard let runtime, !busyIDs.contains(container.id) else { return }
        busyIDs.insert(container.id)
        let result = await ShellRunner.run(runtime.path, [action.rawValue, container.id], timeout: 90)
        busyIDs.remove(container.id)
        lastError = result.succeeded ? nil : action.failureMessage(container: container.name, detail: result.errorSummary)
        await refresh()
    }

    func startMachine() async {
        await machineCommand(.starting, ["machine", "start"] + machineNameArgument, timeout: 300)
    }

    func stopMachine() async {
        await machineCommand(.stopping, ["machine", "stop"] + machineNameArgument, timeout: 120)
    }

    /// `podman machine init --now` downloads the VM image and boots it.
    func initializeMachine() async {
        await machineCommand(.initializing, ["machine", "init", "--now"], timeout: 1200)
    }

    private var machineNameArgument: [String] {
        machine.map { [$0.name] } ?? []
    }

    private func machineCommand(_ operation: MachineOperation, _ arguments: [String], timeout: TimeInterval) async {
        guard let runtime, runtime.kind == .podman, machineOperation == nil else { return }
        machineOperation = operation
        busyIDs.insert(Self.machineKey)
        let result = await ShellRunner.run(runtime.path, arguments, timeout: timeout)
        busyIDs.remove(Self.machineKey)
        machineOperation = nil
        lastError = result.succeeded ? nil : operation.failureMessage(result.errorSummary)
        await refresh()
    }

    // MARK: Refresh

    private func performRefresh() async {
        let settings = configService.config.telemetry
        guard let runtime = ContainerRuntime.resolve(
            kind: settings.containerRuntime,
            overridePath: settings.runtimePath,
            allowFallback: settings.fallbackToDocker
        ) else {
            self.runtime = nil
            set(status: .notInstalled)
            set(containers: [])
            return
        }
        if self.runtime != runtime { self.runtime = runtime }

        switch runtime.kind {
        case .podman: await refreshPodman(runtime)
        case .docker: await refreshDocker(runtime)
        }
    }

    private func refreshPodman(_ runtime: ContainerRuntime) async {
        let list = await ShellRunner.run(runtime.path, ["machine", "list", "--format", "json"], timeout: 15)
        guard list.succeeded else {
            lastError = "podman machine list: \(list.errorSummary)"
            set(status: .unknown)
            return
        }
        let machines = PodmanMachine.parseList(list.stdout)
        guard let current = machines.first(where: \.isDefault) ?? machines.first else {
            if machine != nil { machine = nil }
            set(status: machineOperation == .initializing ? .starting("podman-machine-default") : .noMachine)
            set(containers: [])
            return
        }
        if machine != current { machine = current }

        if current.running {
            set(status: .running(current.name))
        } else if current.starting || machineOperation == .starting || machineOperation == .initializing {
            set(status: .starting(current.name))
        } else {
            set(status: .stopped(current.name))
        }

        guard current.running else {
            set(containers: [])
            return
        }
        await refreshContainers(runtime, ["ps", "-a", "--format", "json"])
    }

    private func refreshDocker(_ runtime: ContainerRuntime) async {
        if machine != nil { machine = nil }
        let info = await ShellRunner.run(runtime.path, ["info", "--format", "{{.ServerVersion}}"], timeout: 15)
        guard info.succeeded, !info.stdout.isBlank else {
            set(status: .daemonUnavailable)
            set(containers: [])
            return
        }
        set(status: .running("Docker \(info.stdout.trimmingCharacters(in: .whitespacesAndNewlines))"))
        await refreshContainers(runtime, ["ps", "-a", "--format", "{{json .}}"])
    }

    private func refreshContainers(_ runtime: ContainerRuntime, _ arguments: [String]) async {
        let result = await ShellRunner.run(runtime.path, arguments, timeout: 20)
        guard result.succeeded else {
            lastError = "\((runtime.path as NSString).lastPathComponent) ps: \(result.errorSummary)"
            return
        }
        set(containers: ContainerInfo.parseList(result.stdout))
    }

    private func set(status newStatus: MachineStatus) {
        if status != newStatus { status = newStatus }
    }

    private func set(containers newContainers: [ContainerInfo]) {
        if containers != newContainers { containers = newContainers }
    }
}
