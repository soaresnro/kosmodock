import AppKit
import Observation
import OSLog
import SwiftUI

enum SettingsSection: Hashable {
    case group(String)
    case appearance
    case behavior
    case telemetry
    case permissions
    case config
    case tiles
    case dock
}

/// One item on the bar.
enum BarItem: Identifiable {
    case group(DockGroup)
    case app(DockApp)
    case tile(DockTile)

    var id: String {
        switch self {
        case .group(let group): group.id
        case .app(let app): DockConfig.itemID(forPinned: app)
        case .tile(let tile): DockConfig.itemID(for: tile)
        }
    }
}

/// Composition root and UI-facing facade over the services.
@MainActor
@Observable
final class AppModel {
    let configService: ConfigService
    let workspace: WorkspaceService
    let telemetry: TelemetryService
    let containers: ContainerMonitorService
    // App widget tiles' data, each running only while its tile is on the bar.
    let claude = ClaudeUsageService()
    let nowPlaying = NowPlayingService()
    let calendar = CalendarService()
    let github = GitHubService()
    let windows: WindowManagerService
    let systemDock: SystemDockManager
    let axHub: AXObserverHub
    let enforcer: BottomMarginEnforcer
    let minimizedWindows: MinimizedWindowTracker
    let dockBadges: DockBadgeService

    /// Group expanded inline in accordion mode.
    var expandedGroupID: String?
    /// Group (or tile, by `itemID(for:)`) whose popover is open.
    var popoverItemID: String?
    var settingsSelection: SettingsSection? = .appearance
    /// Widest the dock bar may be on its screen; set by the window layer.
    var dockMaxWidth: CGFloat = max(400, (NSScreen.screens.first?.visibleFrame.width ?? 1280) - 24)
    /// Incremented to make a capsule pulse (a window just landed in it).
    var pulseTokens: [String: Int] = [:]

    // Wired by the window layer.
    @ObservationIgnored var presentPopover: ((String) -> Void)?
    @ObservationIgnored var dismissPopover: (() -> Void)?
    @ObservationIgnored var openSettingsHandler: ((SettingsSection?) -> Void)?
    @ObservationIgnored var safeWorkAreaProvider: (() -> SafeWorkArea?)?
    @ObservationIgnored var popUpMainMenu: (() -> Void)?

    init(configService: ConfigService) {
        self.configService = configService
        let workspace = WorkspaceService()
        self.workspace = workspace
        telemetry = TelemetryService(configService: configService, workspace: workspace)
        containers = ContainerMonitorService(configService: configService)
        let windows = WindowManagerService()
        self.windows = windows
        systemDock = SystemDockManager()
        let hub = AXObserverHub()
        axHub = hub
        enforcer = BottomMarginEnforcer(windows: windows)
        minimizedWindows = MinimizedWindowTracker(hub: hub, windowService: windows)
        dockBadges = DockBadgeService(windows: windows)
        if let first = configService.config.groups.first { settingsSelection = .group(first.id) }
        L10n.setLanguage(configService.config.behavior.language)
        configService.addObserver { [weak self] old, new in self?.configDidChange(from: old, to: new) }
        wireWindowServices()
    }

    func start() {
        telemetry.start()
        containers.setEnabled(Self.needsContainerMonitor(config))
        updateAppWidgetServices()
        windows.startMonitoringTrust()
        systemDock.reconcile(wantsSuppressed: config.behavior.suppressNativeDock)
        applyWindowBehavior()
        accessibilityDidChange(trusted: windows.isTrusted)
        // Reserved space and group minimize both need Accessibility: ask once
        // at launch so Kosmodock appears in the list with its current identity.
        if !windows.isTrusted, config.behavior.reserveScreenSpace || config.behavior.minimizeToGroups {
            windows.requestAccess()
        }
    }

    func stop() {
        telemetry.stop()
        containers.setEnabled(false)
        for service in [claude.setEnabled, nowPlaying.setEnabled, calendar.setEnabled, github.setEnabled] as [(Bool) -> Void] {
            service(false)
        }
        axHub.stop()
        dockBadges.setActive(false)
        configService.backUp()
    }

    private func wireWindowServices() {
        enforcer.workAreaProvider = { [weak self] in self?.safeWorkAreaProvider?() }
        enforcer.allPIDsProvider = { [weak self] in self?.axHub.observedPIDs ?? [] }
        minimizedWindows.groupResolver = { [weak self] bundleID in self?.groupID(forBundleID: bundleID) }
        axHub.addListener { [weak self] event in
            self?.enforcer.handle(event)
            self?.minimizedWindows.handle(event)
        }
        windows.onTrustChange = { [weak self] trusted in self?.accessibilityDidChange(trusted: trusted) }
    }

    /// Starts the AX observers (and everything built on them) as soon as
    /// Accessibility is granted — no relaunch needed.
    private func accessibilityDidChange(trusted: Bool) {
        Logger.windows.notice("Window services \(trusted ? "starting" : "stopping", privacy: .public); reserve=\(self.config.behavior.reserveScreenSpace, privacy: .public) minimize=\(self.config.behavior.minimizeToGroups, privacy: .public)")
        if trusted {
            axHub.start()
            minimizedWindows.accessibilityDidChange(trusted: true)
            applyWindowBehavior()
            enforcer.enforceAll()
        } else {
            axHub.stop()
            minimizedWindows.accessibilityDidChange(trusted: false)
            enforcer.isEnabled = false
            applyNotificationBadges()
        }
    }

    private func applyWindowBehavior() {
        let behavior = config.behavior
        enforcer.isEnabled = behavior.reserveScreenSpace && windows.isTrusted
        enforcer.exclusions = Set(behavior.screenSpaceExclusions)
        minimizedWindows.setEnabled(behavior.minimizeToGroups)
        applyNotificationBadges()
    }

    private static let reservedLineKey = "Kosmodock.lastReservedLine"

    /// The dock moved/resized or the reserve mode changed: re-check windows.
    /// The last line is persisted so windows fitted by a previous launch can
    /// follow a new, lower line too.
    func workAreaDidChange(from old: SafeWorkArea?, to new: SafeWorkArea) {
        let defaults = UserDefaults.standard
        let newLine = new.accessibilityWorkFrame.maxY
        let previous = old.map { $0.accessibilityWorkFrame.maxY }
            ?? (defaults.object(forKey: Self.reservedLineKey) as? Double).map { CGFloat($0) }
        if new.reservesSpace { defaults.set(Double(newLine), forKey: Self.reservedLineKey) }
        enforcer.workAreaDidChange(previousLine: new.reservesSpace ? previous : nil)
    }

    func pulse(_ groupID: String) {
        pulseTokens[groupID, default: 0] += 1
    }

    /// Group (or pinned app) that owns `bundleID`, falling back to the general group.
    func groupID(forBundleID bundleID: String) -> String? {
        let groups = config.groups.map { group in
            (id: group.id, name: group.name, bundleIDs: Set(group.apps.compactMap(workspace.bundleID(for:))))
        }
        var pinned: [String: String] = [:]
        for app in config.pinnedApps {
            if let id = workspace.bundleID(for: app) { pinned[id] = DockConfig.itemID(forPinned: app) }
        }
        return GroupResolver.groupID(for: bundleID, groups: groups, pinned: pinned)
    }

    // MARK: Derived state

    var config: DockConfig { configService.config }
    var theme: ThemeConfig { config.theme }
    var accent: Color { Color(hex: theme.accentHex) ?? .accentColor }
    /// Drives SwiftUI's string lookup (`\.locale`) and number formatting.
    var locale: Locale { config.behavior.language.locale }
    var language: AppLanguage { config.behavior.language }
    var spring: Animation { .spring(response: max(0.05, theme.springResponse), dampingFraction: theme.springDamping) }

    func group(id: String) -> DockGroup? {
        config.groups.first { $0.id == id }
    }

    func tile(id: String) -> DockTile? {
        config.tiles.first { $0.id == id }
    }

    func tile(itemID: String) -> DockTile? {
        config.tiles.first { DockConfig.itemID(for: $0) == itemID }
    }

    func pinnedApp(itemID: String) -> DockApp? {
        config.pinnedApps.first { DockConfig.itemID(forPinned: $0) == itemID }
    }

    /// Everything on the bar, in order.
    var barItems: [BarItem] {
        let config = config
        var items: [String: BarItem] = [:]
        for group in config.groups { items[group.id] = .group(group) }
        for app in config.pinnedApps { items[DockConfig.itemID(forPinned: app)] = .app(app) }
        for tile in config.tiles { items[DockConfig.itemID(for: tile)] = .tile(tile) }
        return config.barOrder.compactMap { items[$0] }
    }

    func tint(for group: DockGroup) -> Color {
        Color(hex: group.tintHex) ?? accent
    }

    func expansionMode(for group: DockGroup) -> ExpansionMode {
        group.expansionMode ?? config.behavior.expansionMode
    }

    // MARK: Interaction

    func tap(_ group: DockGroup) {
        switch expansionMode(for: group) {
        case .bento:
            presentPopover?(group.id)
        case .accordion:
            dismissPopover?()
            withAnimation(spring) {
                expandedGroupID = expandedGroupID == group.id ? nil : group.id
            }
        }
    }

    func tap(_ tile: DockTile) {
        presentPopover?(DockConfig.itemID(for: tile))
    }

    /// Opens the Bento details for a group regardless of its expansion mode.
    func showDetails(_ group: DockGroup) {
        presentPopover?(group.id)
    }

    /// Dock-style click: launch; restore the latest minimized window when the
    /// app has none visible; minimize into the group when it's already in
    /// front; otherwise focus.
    func open(_ app: DockApp) {
        dismissPopover?()
        guard workspace.isRunning(app) else {
            Task { await workspace.launch(app, activate: true) }
            return
        }
        let behavior = config.behavior
        guard windows.isTrusted, behavior.minimizeToGroups, let pid = workspace.primaryPID(for: app) else {
            workspace.focus(app)
            return
        }
        let isFrontmost = workspace.state(for: app)?.isActive == true
        let latestMinimized = workspace.bundleID(for: app).flatMap { minimizedWindows.windows(forBundleID: $0).first }
        Task {
            let hasVisibleWindow = await windows.hasVisibleWindows(pid: pid)
            if !hasVisibleWindow, let latestMinimized {
                await minimizedWindows.restore(latestMinimized)
            } else if isFrontmost, hasVisibleWindow, behavior.clickActiveAppToMinimize {
                await minimizedWindows.minimizeFocusedWindow(pid: pid)
            } else {
                workspace.focus(app)
            }
        }
    }

    /// Minimizes the app's focused window into its group (context menu).
    func minimizeToGroup(_ app: DockApp) {
        guard let pid = workspace.primaryPID(for: app) else { return }
        dismissPopover?()
        Task { await minimizedWindows.minimizeFocusedWindow(pid: pid) }
    }

    func restore(_ window: MinimizedWindow) {
        dismissPopover?()
        Task { await minimizedWindows.restore(window) }
    }

    func restoreAll(in group: DockGroup) {
        dismissPopover?()
        Task { await minimizedWindows.restoreAll(in: group.id) }
    }

    func launchAll(_ group: DockGroup) {
        dismissPopover?()
        Task {
            for app in group.apps where !workspace.isRunning(app) {
                await workspace.launch(app, activate: false)
            }
            workspace.unhide(group.apps)
            if let first = group.apps.first { workspace.focus(first) }
        }
    }

    /// Launches closed apps, unhides the group (optionally hiding everything
    /// else), then applies the group's tiling layout.
    func launchAndTile(_ group: DockGroup) {
        dismissPopover?()
        let focusMode = config.behavior.focusMode
        let gap = CGFloat(theme.tileGap)
        Task {
            var pids: [pid_t] = []
            var launchedAny = false
            for app in group.apps {
                if let pid = workspace.primaryPID(for: app) {
                    pids.append(pid)
                } else if let launched = await workspace.launch(app, activate: false) {
                    pids.append(launched.processIdentifier)
                    launchedAny = true
                }
            }
            workspace.unhide(group.apps)
            if focusMode {
                workspace.hideApplications(excluding: Set(group.apps.compactMap(workspace.bundleID(for:))))
            }
            guard !pids.isEmpty else { return }

            if windows.refreshTrust() {
                await windows.waitForWindows(pids: pids, timeout: launchedAny ? 12 : 1.5)
                await windows.tile(pids: pids, layout: group.layout, frame: tilingFrame(), gap: gap)
            } else {
                windows.requestAccess()
                if let first = group.apps.first { workspace.focus(first) }
            }
        }
    }

    func selectLayout(_ layout: TilingLayout, for group: DockGroup) {
        configService.update { config in
            guard let index = config.groups.firstIndex(where: { $0.id == group.id }) else { return }
            config.groups[index].layout = layout
        }
        var updated = group
        updated.layout = layout
        applyLayout(updated)
    }

    /// Re-tiles the group's running apps without launching anything.
    func applyLayout(_ group: DockGroup) {
        let pids = group.apps.compactMap(workspace.primaryPID(for:))
        guard !pids.isEmpty else { return }
        let gap = CGFloat(theme.tileGap)
        Task { await windows.tile(pids: pids, layout: group.layout, frame: tilingFrame(), gap: gap) }
    }

    func tile(_ app: DockApp, region: TileRegion) {
        guard let pid = workspace.primaryPID(for: app) else { return }
        let gap = CGFloat(theme.tileGap)
        Task { await windows.tile(pid: pid, region: region, frame: tilingFrame(), gap: gap) }
    }

    func remove(_ app: DockApp, from group: DockGroup) {
        configService.update { config in
            guard let index = config.groups.firstIndex(where: { $0.id == group.id }) else { return }
            config.groups[index].apps.removeAll { $0.id == app.id }
        }
    }

    func openSettings(_ section: SettingsSection?) {
        dismissPopover?()
        openSettingsHandler?(section)
    }

    func refreshTelemetry(for itemID: String) {
        telemetry.refreshNow()
        if let tile = tile(itemID: itemID) {
            switch tile.kind {
            case .command: telemetry.runCommandNow(for: tile)
            case .claudeCode: Task { await claude.refresh() }
            case .nowPlaying: Task { await nowPlaying.refresh() }
            case .github: Task { await github.refresh() }
            default: break
            }
            return
        }
        guard let group = group(id: itemID) else { return }
        if group.widget.type == .podman { Task { await containers.refresh() } }
        telemetry.runCommandsNow(for: group)
    }

    /// Tiling target: the visible frame minus `reservedBottomHeight`.
    private func tilingFrame() -> CGRect {
        safeWorkAreaProvider?()?.workFrame ?? NSScreen.main?.visibleFrame ?? .zero
    }

    // MARK: Telemetry projections

    func usage(for app: DockApp) -> ResourceUsage? {
        workspace.bundleID(for: app).flatMap { telemetry.appUsage[$0] }
    }

    func usage(for group: DockGroup) -> ResourceUsage {
        var seen = Set<String>()
        var total = ResourceUsage.zero
        for app in group.apps {
            guard let id = workspace.bundleID(for: app), seen.insert(id).inserted,
                  let usage = telemetry.appUsage[id] else { continue }
            total = total + usage
        }
        return total
    }

    func level(for probe: HealthProbe, in group: DockGroup) -> HealthLevel {
        if let port = probe.port { return telemetry.isListening(port) ? .ok : .critical }
        return telemetry.commandResults[TelemetryService.commandKey(group: group, probe: probe)]?.level ?? .unknown
    }

    func portLevel(_ ports: [Int]) -> HealthLevel {
        guard !ports.isEmpty else { return .unknown }
        let up = ports.filter(telemetry.isListening).count
        if up == ports.count { return .ok }
        return up == 0 ? .critical : .warning
    }

    /// Text + status dot for the collapsed capsule, e.g. "🦭 3 UP • 12% CPU".
    func badge(for group: DockGroup) -> WidgetBadge? {
        let widget = group.widget
        let usage = usage(for: group)
        var level: HealthLevel?
        // Numeric texts come with their widest variants (`WidgetBadge.reserve`),
        // so a new reading never resizes the dock.
        var badge: WidgetBadge

        switch widget.type {
        case .none:
            if widget.probes.isEmpty {
                // No widget: still show a second line (apps open) so every
                // capsule has the same shape.
                guard !group.apps.isEmpty else { return WidgetBadge(level: nil, text: L10n.tr("No apps")) }
                let open = group.apps.filter { workspace.isRunning($0) }.count
                return .fraction(open, of: group.apps.count) { L10n.tr("%lld/%lld open", $0, $1) }
            }
            let levels = widget.probes.map { self.level(for: $0, in: group) }
            badge = .fraction(levels.filter { $0 == .ok }.count, of: levels.count) { L10n.tr("%lld/%lld checks", $0, $1) }

        case .cpuRam:
            if usage.processCount > 0 {
                badge = .usage(cpu: usage.cpuPercent, memory: usage.memoryBytes)
            } else {
                badge = .systemUsage(cpu: telemetry.system.cpuPercent, memory: telemetry.system.memoryUsed)
            }

        case .podman:
            if let operation = containers.machineOperation {
                level = .warning
                badge = WidgetBadge(text: "🦭 \(operation.progressTitle)")
                break
            }
            level = containers.status.level
            switch containers.status {
            case .running:
                let cpu = telemetry.vmUsage?.cpuPercent ?? telemetry.system.cpuPercent
                badge = .podmanRunning(containers: containers.runningCount, cpu: cpu)
            case .stopped: badge = WidgetBadge(text: L10n.tr("🦭 VM Stopped"))
            case .starting: badge = WidgetBadge(text: L10n.tr("🦭 Starting…"))
            case .noMachine: badge = WidgetBadge(text: L10n.tr("🦭 No VM"))
            case .notInstalled: badge = WidgetBadge(text: L10n.tr("🦭 Not installed"))
            case .daemonUnavailable: badge = WidgetBadge(text: L10n.tr("🐳 Daemon down"))
            case .unknown: badge = WidgetBadge(text: "🦭 …")
            }

        case .portProbe:
            let ports = widget.ports
            level = ports.isEmpty ? nil : portLevel(ports)
            if ports.isEmpty {
                badge = WidgetBadge(text: L10n.tr("No ports"))
            } else if ports.count == 1 {
                badge = WidgetBadge(text: ":\(ports[0])")
            } else {
                badge = .fraction(ports.filter(telemetry.isListening).count, of: ports.count) { L10n.tr("%lld/%lld ports", $0, $1) }
            }
            if usage.processCount > 0 { badge = badge.addingMemory(usage.memoryBytes) }

        case .customCommand:
            // Free text: its width can't be predicted, so it has no reserve.
            var text: String
            if let result = telemetry.commandResults[TelemetryService.commandKey(group: group)] {
                level = result.level
                text = L10n.configText(result.summary)
            } else {
                level = .unknown
                text = (widget.command?.isBlank ?? true) ? L10n.tr("No command") : L10n.tr("Running…")
            }
            if let label = widget.label.map(L10n.configText), !label.isBlank, widget.type == .customCommand,
               !text.hasPrefix(label) {
                text = "\(label) \(text)"
            }
            badge = WidgetBadge(text: text)
        }

        if widget.type != .none, !widget.probes.isEmpty {
            let worst = widget.probes.map { self.level(for: $0, in: group) }.max()
            level = [level, worst].compactMap { $0 }.max()
        } else if widget.type == .none {
            level = widget.probes.map { self.level(for: $0, in: group) }.max()
        }
        badge.level = level
        return badge
    }

    // MARK: Config bindings

    /// Binding into the live config that persists edits automatically.
    func binding<Value: Sendable>(_ keyPath: WritableKeyPath<DockConfig, Value>) -> Binding<Value> {
        Binding(
            get: { MainActor.assumeIsolated { self.configService.config[keyPath: keyPath] } },
            set: { newValue in MainActor.assumeIsolated { self.configService.update { $0[keyPath: keyPath] = newValue } } }
        )
    }

    /// Binding to a group looked up by id, so it stays valid while groups are
    /// added, removed or reordered.
    func groupBinding(id: String) -> Binding<DockGroup> {
        Binding(
            get: {
                MainActor.assumeIsolated { self.group(id: id) ?? DockGroup(id: id, name: "") }
            },
            set: { newValue in
                MainActor.assumeIsolated {
                    self.configService.update { config in
                        guard let index = config.groups.firstIndex(where: { $0.id == id }) else { return }
                        config.groups[index] = newValue
                    }
                }
            }
        )
    }

    @discardableResult
    func addGroup() -> String {
        let id = "group-\(UUID().uuidString.prefix(6).lowercased())"
        configService.update { config in
            config.settleOrder()
            config.groups.append(DockGroup(id: id, name: L10n.tr("New Group"), symbol: "square.stack.3d.up.fill", widget: WidgetConfig(type: .cpuRam)))
        }
        return id
    }

    func deleteGroup(id: String) {
        configService.update { config in
            config.groups.removeAll { $0.id == id }
            config.order.removeAll { $0 == id }
        }
        if case .group(id) = settingsSelection {
            settingsSelection = config.groups.first.map { .group($0.id) } ?? .appearance
        }
    }

    /// Offsets are among the groups in bar order (the sidebar's list).
    func moveGroups(fromOffsets source: IndexSet, toOffset destination: Int) {
        configService.update { $0.moveGroups(fromOffsets: source, toOffset: destination) }
    }

    /// Groups in bar order.
    var orderedGroups: [DockGroup] {
        barItems.compactMap { if case .group(let group) = $0 { group } else { nil } }
    }

    func moveBarItems(fromOffsets source: IndexSet, toOffset destination: Int) {
        configService.update { $0.moveBarItems(fromOffsets: source, toOffset: destination) }
    }

    func moveBarItem(id: String, by offset: Int) {
        configService.update { $0.moveBarItem(id, by: offset) }
    }

    /// Adds an app to the bar as a plain icon, at the end; an app already
    /// pinned stays where it is.
    func pinApp(_ app: DockApp) {
        configService.update { config in
            guard !config.pinnedApps.contains(where: { $0.id == app.id }) else { return }
            config.settleOrder()
            config.pinnedApps.append(app)
        }
    }

    func unpinApp(itemID: String) {
        configService.update { config in
            config.pinnedApps.removeAll { DockConfig.itemID(forPinned: $0) == itemID }
            config.order.removeAll { $0 == itemID }
        }
    }

    func tileBinding(id: String) -> Binding<DockTile> {
        Binding(
            get: {
                MainActor.assumeIsolated { self.tile(id: id) ?? DockTile(id: id, kind: .clock) }
            },
            set: { newValue in
                MainActor.assumeIsolated {
                    self.configService.update { config in
                        guard let index = config.tiles.firstIndex(where: { $0.id == id }) else { return }
                        config.tiles[index] = newValue
                    }
                }
            }
        )
    }

    @discardableResult
    func addTile(_ kind: TileKind) -> String {
        var tile = DockTile(id: kind.rawValue, kind: kind)
        if kind == .command {
            tile.label = L10n.uptime
            tile.command = "uptime | sed 's/.*up \\([^,]*\\),.*/\\1/'"
            tile.interval = 60
        }
        configService.update { config in
            config.settleOrder()
            config.tiles = DockConfig.normalizedTileIDs(config.tiles + [tile])
        }
        return config.tiles.last?.id ?? tile.id
    }

    func deleteTile(id: String) {
        configService.update { config in
            config.order.removeAll { $0 == "tile:\(id)" }
            config.tiles.removeAll { $0.id == id }
        }
    }

    // MARK: Config reactions

    private static func needsContainerMonitor(_ config: DockConfig) -> Bool {
        config.groups.contains { $0.widget.type == .podman }
    }

    /// Starts the services of the app widgets on the bar and stops the rest.
    func updateAppWidgetServices() {
        let kinds = Set(config.tiles.map(\.kind))
        claude.setEnabled(kinds.contains(.claudeCode))
        nowPlaying.setEnabled(kinds.contains(.nowPlaying))
        calendar.setEnabled(kinds.contains(.calendar))
        github.setEnabled(kinds.contains(.github))
    }

    private func configDidChange(from old: DockConfig, to new: DockConfig) {
        if old.behavior.language != new.behavior.language { L10n.setLanguage(new.behavior.language) }
        containers.setEnabled(Self.needsContainerMonitor(new))
        if old.tiles != new.tiles { updateAppWidgetServices() }
        if old.behavior.suppressNativeDock != new.behavior.suppressNativeDock {
            systemDock.reconcile(wantsSuppressed: new.behavior.suppressNativeDock)
        }
        if old.telemetry != new.telemetry {
            telemetry.start()
            Task { await containers.refresh() }
        }
        if old.behavior != new.behavior {
            applyWindowBehavior()
            if new.behavior.reserveScreenSpace, !old.behavior.reserveScreenSpace { enforcer.enforceAll() }
        }
        if old.groups != new.groups { minimizedWindows.regroup() }
        if let id = expandedGroupID, !new.groups.contains(where: { $0.id == id }) {
            expandedGroupID = nil
        }
        if let id = popoverItemID, !new.groups.contains(where: { $0.id == id }),
           !new.tiles.contains(where: { DockConfig.itemID(for: $0) == id }) {
            dismissPopover?()
        }
    }
}
