import AppKit
import OSLog
import SwiftUI

/// Workspace state that isn't config: what switches did to apps, and the
/// hotkeys. Kept in memory, so a relaunch forgets which apps Kosmodock hid.
@MainActor
final class WorkspaceSwitcher {
    /// Apps Kosmodock hid on a switch, unhidden when a workspace that has
    /// them comes back (`WorkspaceSwitch.Plan.hiddenByKosmodock`).
    var hiddenApps: Set<String> = []
    let hotKeys = HotKeyCenter()
    /// Workspaces the hotkeys are registered for.
    var hotKeyCount = 0
}

extension Logger {
    static let workspaces = Logger(subsystem: "dev.kosmodock.Kosmodock", category: "workspaces")
}

extension AppModel {
    var activeWorkspace: Workspace? { config.activeWorkspace }

    /// Dots, hotkeys, swipes and the menu need a second workspace to go to.
    var canSwitchWorkspaces: Bool { config.workspaces.count >= 2 }

    // MARK: Switching

    /// Shows the workspace's bar. The new workspace's `otherApps` applies to
    /// running apps of the old one it doesn't have; its own apps that
    /// Kosmodock hid come back. Kosmodock itself is never touched.
    func activateWorkspace(id: String) {
        let config = config
        guard let old = config.activeWorkspace, old.id != id,
              let new = config.workspaces.first(where: { $0.id == id }) else { return }
        let states = workspace.states
        let plan = WorkspaceSwitch.plan(
            leaving: bundleIDs(ofItems: config.shownItemIDs(inWorkspace: old.id)),
            entering: bundleIDs(ofItems: config.shownItemIDs(inWorkspace: new.id)),
            policy: new.otherApps,
            running: Set(states.keys),
            hidden: Set(states.filter(\.value.isHidden).keys),
            hiddenByKosmodock: workspaceSwitcher.hiddenApps,
            ownBundleID: Bundle.main.bundleIdentifier
        )
        Logger.workspaces.notice("Workspace \(new.id, privacy: .public): hide \(plan.hide.count, privacy: .public), quit \(plan.quit.count, privacy: .public), unhide \(plan.unhide.count, privacy: .public)")
        workspaceSwitcher.hiddenApps = plan.hiddenByKosmodock
        dismissPopover?()
        withAnimation(spring) {
            configService.update { $0.activeWorkspaceID = id }
        }
        perform(plan)
    }

    /// The next (`1`) or previous (`-1`) workspace, wrapping around.
    func activateWorkspace(step: Int) {
        guard canSwitchWorkspaces, let id = config.workspaceID(steppingBy: step) else { return }
        activateWorkspace(id: id)
    }

    /// The workspace at `number` (from 1), as ⌃⌥`number` does.
    func activateWorkspace(number: Int) {
        let workspaces = config.workspaces
        guard workspaces.indices.contains(number - 1) else { return }
        activateWorkspace(id: workspaces[number - 1].id)
    }

    /// Apps of the groups and pinned apps among `itemIDs`.
    func bundleIDs(ofItems itemIDs: [String]) -> Set<String> {
        var ids = Set<String>()
        for itemID in itemIDs {
            if let group = group(id: itemID) {
                ids.formUnion(group.apps.compactMap(workspace.bundleID(for:)))
            } else if let app = pinnedApp(itemID: itemID), let id = workspace.bundleID(for: app) {
                ids.insert(id)
            }
        }
        return ids
    }

    private func perform(_ plan: WorkspaceSwitch.Plan) {
        let me = NSRunningApplication.current.processIdentifier
        func running(_ ids: Set<String>) -> [NSRunningApplication] {
            ids.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
                .filter { $0.processIdentifier != me && !$0.isTerminated }
        }
        running(plan.unhide).forEach { $0.unhide() }
        running(plan.hide).forEach { $0.hide() }
        // Like ⌘Q: an app can still ask to save its documents, or refuse.
        running(plan.quit).forEach { $0.terminate() }
    }

    // MARK: Editing

    /// A new workspace, as a copy of the current bar. The first is active.
    @discardableResult
    func addWorkspace() -> String {
        var id = ""
        editBar { config in
            id = config.addWorkspace(name: config.workspaces.isEmpty ? L10n.mainWorkspace : L10n.newWorkspace)
        }
        return id
    }

    /// Deleting the active workspace first switches to its neighbor, so that
    /// one's apps come back. The last workspace stays (see `useSingleDock`).
    func deleteWorkspace(id: String) {
        let ids = config.workspaces.map(\.id)
        guard ids.count > 1, let index = ids.firstIndex(of: id) else { return }
        if config.activeWorkspace?.id == id {
            activateWorkspace(id: index + 1 < ids.count ? ids[index + 1] : ids[index - 1])
        }
        editBar { $0.deleteWorkspace(id: id) }
    }

    /// Back to one bar with everything on it; apps Kosmodock hid come back.
    func useSingleDock() {
        perform(WorkspaceSwitch.Plan(unhide: workspaceSwitcher.hiddenApps))
        workspaceSwitcher.hiddenApps = []
        editBar { $0.useSingleDock() }
    }

    func moveWorkspaces(fromOffsets source: IndexSet, toOffset destination: Int) {
        configService.update { $0.moveWorkspaces(fromOffsets: source, toOffset: destination) }
    }

    func moveWorkspace(id: String, by offset: Int) {
        guard let index = config.workspaces.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(0, index + offset), config.workspaces.count - 1)
        guard target != index else { return }
        moveWorkspaces(fromOffsets: IndexSet(integer: index), toOffset: target > index ? target + 1 : target)
    }

    /// Binding to a workspace looked up by id, like `groupBinding(id:)`.
    func workspaceBinding(id: String) -> Binding<Workspace> {
        Binding(
            get: {
                MainActor.assumeIsolated { self.config.workspaces.first { $0.id == id } ?? Workspace(id: id, name: "") }
            },
            set: { newValue in
                MainActor.assumeIsolated {
                    self.configService.update { config in
                        guard let index = config.workspaces.firstIndex(where: { $0.id == id }) else { return }
                        config.workspaces[index] = newValue
                    }
                }
            }
        )
    }

    func setItem(_ itemID: String, included: Bool, inWorkspace workspaceID: String) {
        editBar { $0.setItem(itemID, included: included, inWorkspace: workspaceID) }
    }

    func moveItem(_ itemID: String, by offset: Int, inWorkspace workspaceID: String) {
        editBar { $0.moveItem(itemID, by: offset, inWorkspace: workspaceID) }
    }

    // MARK: Bar items

    /// The items for `ids`, skipping unknown ones.
    func barItems(for ids: [String]) -> [BarItem] {
        let config = config
        var items: [String: BarItem] = [:]
        for group in config.groups { items[group.id] = .group(group) }
        for app in config.pinnedApps { items[DockConfig.itemID(forPinned: app)] = .app(app) }
        for tile in config.tiles { items[DockConfig.itemID(for: tile)] = .tile(tile) }
        items.merge(extraBarItems(in: config)) { $1 }
        return ids.compactMap { items[$0] }
    }

    /// Items the active workspace doesn't show, in single-bar order.
    var itemsOutsideActiveWorkspace: [BarItem] {
        guard config.activeWorkspace != nil else { return [] }
        let shown = Set(config.barOrder)
        return barItems(for: config.allItemIDs.filter { !shown.contains($0) })
    }

    // MARK: Lifecycle

    func startWorkspaces() {
        updateWorkspaceHotKeys()
        configService.addObserver { [weak self] old, new in self?.workspacesDidChange(from: old, to: new) }
    }

    private func workspacesDidChange(from old: DockConfig, to new: DockConfig) {
        updateWorkspaceHotKeys()
        let shown = Set(new.barOrder)
        guard Set(old.barOrder) != shown else { return }
        // Minimized windows move to an item the bar now shows.
        minimizedWindows.regroup()
        if let id = expandedGroupID, !shown.contains(id) { expandedGroupID = nil }
        if let id = popoverItemID, !shown.contains(id) { dismissPopover?() }
    }

    /// ⌃⌥1 … ⌃⌥9, registered only while there are workspaces to switch to.
    private func updateWorkspaceHotKeys() {
        let count = canSwitchWorkspaces ? min(Workspace.shortcutCount, config.workspaces.count) : 0
        guard count != workspaceSwitcher.hotKeyCount else { return }
        workspaceSwitcher.hotKeyCount = count
        workspaceSwitcher.hotKeys.register((0..<count).compactMap { index in
            HotKeyCenter.controlOption(digit: index + 1).map { shortcut in
                (shortcut, { [weak self] in self?.activateWorkspace(number: index + 1) })
            }
        })
    }
}
