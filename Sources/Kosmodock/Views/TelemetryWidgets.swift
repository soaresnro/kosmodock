import SwiftUI

/// Bottom half of the Bento popover: system metrics plus the group's widget.
struct TelemetrySection: View {
    @Environment(AppModel.self) private var model
    let group: DockGroup

    var body: some View {
        let widget = group.widget
        VStack(spacing: 10) {
            SystemCardsRow(group: group)
            if widget.type == .podman {
                PodmanCard()
            }
            if widget.type == .portProbe, !widget.ports.isEmpty {
                PortsCard(ports: widget.ports)
            }
            if widget.type == .customCommand {
                CommandCard(group: group)
            }
            if !widget.probes.isEmpty {
                ProbesCard(group: group)
            }
        }
    }
}

// MARK: - CPU & memory

private struct SystemCardsRow: View {
    @Environment(AppModel.self) private var model
    let group: DockGroup

    var body: some View {
        let system = model.telemetry.system
        let usage = model.usage(for: group)
        let tint = model.tint(for: group)
        HStack(alignment: .top, spacing: 10) {
            BentoCard(title: L10n.tr("CPU"), symbol: "cpu") {
                HStack(spacing: 12) {
                    ZStack {
                        RingGauge(value: system.cpuPercent / 100, color: tint)
                        Text(Format.percent(system.cpuPercent))
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                    .frame(width: 46, height: 46)
                    VStack(alignment: .leading, spacing: 3) {
                        StatLine(label: L10n.tr("Group"), value: Format.percent(usage.cpuPercent))
                        StatLine(label: L10n.tr("Load"), value: String(format: "%.2f", locale: L10n.locale, system.loadAverage))
                        StatLine(label: L10n.tr("Cores"), value: "\(system.coreCount)")
                    }
                }
            }
            BentoCard(title: L10n.tr("Memory"), symbol: "memorychip") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(Format.bytes(system.memoryUsed))
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text(L10n.tr("of %@", Format.bytes(system.memoryTotal)))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    UsageBar(fraction: system.memoryFraction, color: system.pressure.level.color)
                    StatLine(label: L10n.tr("Group"), value: Format.bytes(usage.memoryBytes))
                    StatLine(label: L10n.tr("Pressure"), value: system.pressure.title)
                }
            }
        }
    }
}

// MARK: - Podman

private struct PodmanCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let monitor = model.containers
        BentoCard(title: runtimeTitle, symbol: "shippingbox.fill") {
            VStack(alignment: .leading, spacing: 8) {
                MachineRow()
                switch monitor.status {
                case .running:
                    ContainerList()
                case .stopped:
                    MachinePrompt(
                        message: "The Podman VM is stopped. Start it to manage containers.",
                        actionTitle: L10n.tr("Start Podman Machine"), symbol: "play.fill"
                    ) {
                        Task { await monitor.startMachine() }
                    }
                case .noMachine:
                    MachinePrompt(
                        message: "No Podman machine exists yet. Initialising downloads the VM image and boots it.",
                        actionTitle: L10n.tr("Initialize & Start Machine"), symbol: "sparkles"
                    ) {
                        Task { await monitor.initializeMachine() }
                    }
                case .notInstalled:
                    HintText("Podman wasn't found in /opt/homebrew/bin, /usr/local/bin or /opt/podman/bin. Install it with `brew install podman`, or set a path in Settings → Telemetry.")
                case .daemonUnavailable:
                    HintText("The Docker daemon isn't responding. Start Docker Desktop or your runtime.")
                case .starting, .unknown:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(monitor.status.title).foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11))
                }
                if let error = monitor.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(HealthLevel.critical.color)
                        .lineLimit(2)
                }
            }
        } accessory: {
            Button {
                Task { await monitor.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh")
        }
    }

    private var runtimeTitle: String {
        model.containers.runtime?.kind == .docker ? "Docker" : "Podman"
    }
}

private struct MachineRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let monitor = model.containers
        HStack(spacing: 8) {
            Text(monitor.runtime?.kind == .docker ? "🐳" : "🦭")
                .font(.system(size: 18))
            VStack(alignment: .leading, spacing: 1) {
                Text(monitor.machine?.name ?? machineName(monitor.status))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(detail(monitor))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            HStack(spacing: 5) {
                if monitor.machineOperation != nil {
                    ProgressView().controlSize(.mini)
                } else {
                    StatusDot(level: monitor.status.level, size: 6)
                }
                Text(monitor.machineOperation?.progressTitle ?? monitor.status.title)
            }
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            if monitor.status.isRunning, monitor.runtime?.kind == .podman, monitor.machineOperation == nil {
                IconButton(symbol: "stop.fill", help: L10n.tr("Stop Podman Machine"), size: 22) {
                    Task { await monitor.stopMachine() }
                }
            }
        }
    }

    private func machineName(_ status: MachineStatus) -> String {
        switch status {
        case .running(let name), .stopped(let name), .starting(let name): name
        default: L10n.tr("Container runtime")
        }
    }

    private func detail(_ monitor: ContainerMonitorService) -> String {
        var parts: [String] = []
        if let machine = monitor.machine {
            if machine.cpus > 0 { parts.append("\(machine.cpus) CPU") }
            if machine.memoryBytes > 0 { parts.append(Format.bytes(machine.memoryBytes)) }
            if !machine.vmType.isEmpty { parts.append(machine.vmType) }
        }
        if monitor.status.isRunning {
            parts.append(L10n.tr("%lld/%lld up", monitor.runningCount, monitor.containers.count))
            if let vm = model.telemetry.vmUsage {
                parts.append("VM \(Format.percent(vm.cpuPercent)) · \(Format.bytes(vm.memoryBytes))")
            }
        }
        return parts.isEmpty ? (monitor.runtime?.path ?? "—") : parts.joined(separator: " · ")
    }
}

private struct MachinePrompt: View {
    @Environment(AppModel.self) private var model
    let message: String
    let actionTitle: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        let busy = model.containers.machineOperation != nil
        VStack(alignment: .leading, spacing: 8) {
            HintText(message)
            Button(action: action) {
                HStack(spacing: 6) {
                    if busy {
                        ProgressView().controlSize(.mini).tint(.white)
                    } else {
                        Image(systemName: symbol)
                    }
                    Text(busy ? (model.containers.machineOperation?.progressTitle ?? L10n.tr("Working…")) : actionTitle)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(GlassPillButtonStyle(tint: Color(red: 0.36, green: 0.42, blue: 0.95), prominent: true))
            .disabled(busy)
        }
    }
}

private struct ContainerList: View {
    @Environment(AppModel.self) private var model
    private let rowHeight: CGFloat = 50

    var body: some View {
        let containers = model.containers.containers
        if containers.isEmpty {
            HintText("No containers yet. Try `podman run -d -p 5432:5432 -e POSTGRES_PASSWORD=dev postgres`.")
        } else {
            ScrollView(.vertical) {
                LazyVStack(spacing: 6) {
                    ForEach(containers) { container in
                        ContainerRow(container: container)
                    }
                }
            }
            .scrollIndicators(containers.count > 5 ? .automatic : .never)
            .frame(height: min(CGFloat(containers.count) * rowHeight - 6, rowHeight * 5))
        }
    }
}

private struct ContainerRow: View {
    @Environment(AppModel.self) private var model
    let container: ContainerInfo
    @ViewState private var isHovering = false

    var body: some View {
        let monitor = model.containers
        let busy = monitor.busyIDs.contains(container.id)
        HStack(spacing: 10) {
            StatusDot(level: container.level, size: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(container.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(container.shortImage)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    ForEach(container.ports.prefix(3), id: \.self) { port in
                        Text(port.label)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                }
                .font(.system(size: 10))
            }
            Spacer(minLength: 6)
            Text(container.displayStatus)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: 96, alignment: .trailing)
            if busy {
                ProgressView().controlSize(.small).frame(width: 50)
            } else {
                HStack(spacing: 4) {
                    if container.isRunning {
                        IconButton(symbol: "stop.fill", help: L10n.tr("Stop %@", container.name), size: 22) {
                            Task { await monitor.perform(.stop, on: container) }
                        }
                    } else {
                        IconButton(symbol: "play.fill", help: L10n.tr("Start %@", container.name), size: 22) {
                            Task { await monitor.perform(.start, on: container) }
                        }
                    }
                    IconButton(symbol: "arrow.clockwise", help: L10n.tr("Restart %@", container.name), size: 22) {
                        Task { await monitor.perform(.restart, on: container) }
                    }
                }
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 44)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(isHovering ? 0.09 : 0.045))
        }
        .onHover { isHovering = $0 }
    }
}

// MARK: - Ports, commands, probes

private struct PortsCard: View {
    @Environment(AppModel.self) private var model
    let ports: [Int]

    var body: some View {
        let telemetry = model.telemetry
        BentoCard(title: L10n.tr("Ports"), symbol: "network") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(ports, id: \.self) { port in
                    let owner = telemetry.listeningPorts[port]
                    HStack(spacing: 6) {
                        StatusDot(level: owner != nil ? .ok : .critical, size: 6)
                        Text(verbatim: ":\(port)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        Text(owner.map { $0.isEmpty ? L10n.tr("listening") : $0 } ?? L10n.tr("closed"))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
                }
            }
        } accessory: {
            Text(L10n.tr("%lld/%lld up", ports.filter(telemetry.isListening).count, ports.count))
                .monospacedDigit()
        }
    }
}

private struct CommandCard: View {
    @Environment(AppModel.self) private var model
    let group: DockGroup

    var body: some View {
        let result = model.telemetry.commandResults[TelemetryService.commandKey(group: group)]
        BentoCard(title: group.widget.label?.isBlank == false ? L10n.configText(group.widget.label!) : L10n.tr("Command"), symbol: "terminal") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    StatusDot(level: result?.level ?? .unknown, size: 7)
                    Text(result.map { L10n.configText($0.summary) } ?? L10n.tr("Waiting for first run…"))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if let result {
                        Text(result.updatedAt, style: .relative)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
                Text(group.widget.command ?? L10n.tr("No command configured"))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail = result?.detail, !detail.isEmpty, detail != result?.summary {
                    Text(detail)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
            }
        } accessory: {
            Button {
                model.telemetry.runCommandsNow(for: group)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Run now")
        }
    }
}

private struct ProbesCard: View {
    @Environment(AppModel.self) private var model
    let group: DockGroup

    var body: some View {
        BentoCard(title: L10n.tr("Health Checks"), symbol: "stethoscope") {
            VStack(spacing: 5) {
                ForEach(group.widget.probes) { probe in
                    let level = model.level(for: probe, in: group)
                    HStack(spacing: 8) {
                        StatusDot(level: level, size: 6)
                        Text(probe.name)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(summary(for: probe))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        } accessory: {
            Button {
                model.telemetry.runCommandsNow(for: group)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Run checks now")
        }
    }

    private func summary(for probe: HealthProbe) -> String {
        if let port = probe.port {
            let owner = model.telemetry.listeningPorts[port]
            return ":\(port) " + (owner.map { $0.isEmpty ? L10n.tr("listening") : $0 } ?? L10n.tr("closed"))
        }
        let key = TelemetryService.commandKey(group: group, probe: probe)
        return model.telemetry.commandResults[key]?.summary ?? L10n.tr("pending")
    }
}

private struct HintText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(LocalizedStringKey(text))
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
