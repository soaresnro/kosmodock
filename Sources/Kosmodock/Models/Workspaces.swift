import Foundation

// MARK: - Model

/// What happens, on a switch, to the running apps of the workspace you leave
/// that the new one doesn't have. The workspace you switch to decides.
enum OtherWorkspaceApps: String, Codable, CaseIterable, Identifiable, Sendable {
    case keep
    case hide
    case quit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keep: L10n.tr("Leave open")
        case .hide: L10n.tr("Hide")
        case .quit: L10n.tr("Quit")
        }
    }
}

/// A bar of its own: which groups, pinned apps and tiles it shows, in order.
/// Groups, apps and tiles live once in `DockConfig`; workspaces list their ids.
struct Workspace: Codable, Identifiable, Equatable, Sendable {
    var id: String
    /// Saved as typed, or as a config text (`L10n.mainWorkspace`, `L10n.newWorkspace`).
    var name: String
    var colorHex: String = Workspace.colors[0]
    /// Item ids (a group's id, `app:<id>`, `tile:<id>`) in bar order.
    var items: [String] = []
    var otherApps: OtherWorkspaceApps = .hide

    /// The name in the interface language when Kosmodock wrote it.
    var displayName: String { L10n.configText(name) }

    /// Preset colors, also given to new workspaces in turn.
    static let colors = ["#8B7CFF", "#4C8DFF", "#2EC27E", "#FF9F0A", "#FF375F", "#64D2FF", "#FFD60A", "#AC8E68"]

    /// Shortcuts go up to ⌃⌥9.
    static let shortcutCount = 9

    /// "⌃⌥3" for the third workspace; `nil` past the ninth.
    static func shortcut(index: Int) -> String? {
        (0..<shortcutCount).contains(index) ? "⌃⌥\(index + 1)" : nil
    }
}

extension Workspace {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(.id, or: "")
        name = try c.decode(.name, or: L10n.newWorkspace)
        colorHex = try c.decode(.colorHex, or: Workspace.colors[0])
        items = try c.decode(.items, or: [])
        otherApps = try c.decode(.otherApps, or: .hide)
    }
}

// MARK: - Bar order per workspace

extension DockConfig {
    /// The active workspace's index. With workspaces one is always active: an
    /// unknown `activeWorkspaceID` means the first.
    var activeWorkspaceIndex: Int? {
        guard !workspaces.isEmpty else { return nil }
        return workspaces.firstIndex { $0.id == activeWorkspaceID } ?? 0
    }

    var activeWorkspace: Workspace? {
        activeWorkspaceIndex.map { workspaces[$0] }
    }

    /// The list `barOrder` reads and bar edits write: the active workspace's
    /// items, or `order` without workspaces.
    var activeOrder: [String] {
        get { activeWorkspace?.items ?? order }
        set {
            if let index = activeWorkspaceIndex {
                workspaces[index].items = newValue
            } else {
                order = newValue
            }
        }
    }

    /// Every group, pinned app and tile, in the order a single bar has them.
    var allItemIDs: [String] {
        var single = self
        single.workspaces = []
        return single.barOrder
    }

    /// Groups as the sidebar lists them: in bar order, then the ones the
    /// active workspace doesn't show, in config order.
    var sidebarGroupIDs: [String] {
        let groupIDs = Set(groups.map(\.id))
        let shown = barOrder.filter(groupIDs.contains)
        let shownSet = Set(shown)
        return shown + groups.map(\.id).filter { !shownSet.contains($0) }
    }

    /// Runs `add`, which adds groups, pinned apps or tiles. They land at the
    /// end of the bar; with workspaces, at the end of the active one only.
    mutating func addToBar(_ add: (inout DockConfig) -> Void) {
        settleOrder()
        let before = Set(allItemIDs)
        add(&self)
        guard let index = activeWorkspaceIndex else { return }
        for id in allItemIDs where !before.contains(id) && !workspaces[index].items.contains(id) {
            workspaces[index].items.append(id)
        }
    }

    /// Forgets a deleted item's place: in `order` and in every workspace.
    mutating func removeFromBar(_ itemID: String) {
        order.removeAll { $0 == itemID }
        for index in workspaces.indices {
            workspaces[index].items.removeAll { $0 == itemID }
        }
    }

    /// Shows or hides an item in a workspace. A shown item goes to the end.
    mutating func setItem(_ itemID: String, included: Bool, inWorkspace workspaceID: String) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        let known = Set(allItemIDs)
        var items = workspaces[index].items.filter { known.contains($0) && $0 != itemID }
        if included, known.contains(itemID) { items.append(itemID) }
        workspaces[index].items = items
    }

    /// Puts an existing item on the active workspace's bar when it isn't there.
    mutating func showInActiveWorkspace(_ itemID: String) {
        guard let workspace = activeWorkspace, !barOrder.contains(itemID) else { return }
        setItem(itemID, included: true, inWorkspace: workspace.id)
    }

    /// The workspace's items that still exist, in its order.
    func shownItemIDs(inWorkspace workspaceID: String) -> [String] {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return [] }
        var config = self
        config.activeWorkspaceID = workspace.id
        return config.barOrder
    }

    mutating func moveItem(_ itemID: String, by offset: Int, inWorkspace workspaceID: String) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        var ids = shownItemIDs(inWorkspace: workspaceID)
        guard let position = ids.firstIndex(of: itemID) else { return }
        let target = min(max(0, position + offset), ids.count - 1)
        guard target != position else { return }
        ids.swapAt(position, target)
        workspaces[index].items = ids
    }

    // MARK: Workspaces

    /// Adds a workspace that starts as a copy of the current bar. The first
    /// one becomes active, so the bar looks the same until you change it.
    @discardableResult
    mutating func addWorkspace(name: String) -> String {
        let used = Set(workspaces.map(\.colorHex))
        let color = Workspace.colors.first { !used.contains($0) } ?? Workspace.colors[workspaces.count % Workspace.colors.count]
        let workspace = Workspace(id: DockConfig.uniqueWorkspaceID(DockConfig.slug(name), among: workspaces), name: name, colorHex: color, items: barOrder)
        if workspaces.isEmpty { activeWorkspaceID = workspace.id }
        workspaces.append(workspace)
        return workspace.id
    }

    /// Removes a workspace, never the last one: with no workspaces there's a
    /// single bar again, which is `useSingleDock()`.
    mutating func deleteWorkspace(id: String) {
        guard workspaces.count > 1, let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        let wasActive = activeWorkspaceIndex == index
        workspaces.remove(at: index)
        if wasActive { activeWorkspaceID = workspaces[min(index, workspaces.count - 1)].id }
    }

    /// Back to one bar: the active workspace's order first, then everything
    /// the other workspaces had.
    mutating func useSingleDock() {
        order = barOrder
        workspaces = []
        activeWorkspaceID = nil
    }

    mutating func moveWorkspaces(fromOffsets source: IndexSet, toOffset destination: Int) {
        workspaces = workspaces.moved(fromOffsets: source, toOffset: destination)
    }

    /// The workspace `step` places after the active one, wrapping around.
    func workspaceID(steppingBy step: Int) -> String? {
        guard let index = activeWorkspaceIndex else { return nil }
        let count = workspaces.count
        return workspaces[((index + step) % count + count) % count].id
    }

    static func uniqueWorkspaceID(_ base: String, among workspaces: [Workspace]) -> String {
        let taken = Set(workspaces.map(\.id))
        var candidate = base
        var suffix = 2
        while taken.contains(candidate) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        return candidate
    }

    /// Unique workspace ids, derived from the name when missing.
    static func normalizedWorkspaceIDs(_ workspaces: [Workspace]) -> [Workspace] {
        var result: [Workspace] = []
        for var workspace in workspaces {
            var base = workspace.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if base.isEmpty { base = slug(workspace.name) }
            workspace.id = uniqueWorkspaceID(base, among: result)
            result.append(workspace)
        }
        return result
    }
}

// MARK: - Switching

/// What a switch does to running apps, decided from bundle ids only.
enum WorkspaceSwitch {
    struct Plan: Equatable {
        var hide: Set<String> = []
        var quit: Set<String> = []
        var unhide: Set<String> = []
        /// Apps Kosmodock has hidden after the switch, to unhide later.
        var hiddenByKosmodock: Set<String> = []
    }

    /// Apps that never quit on a switch: the Finder has no Quit.
    static let neverQuit: Set<String> = ["com.apple.finder"]

    /// - Parameters:
    ///   - leaving: apps of the old workspace's groups and pinned apps.
    ///   - entering: the same for the new workspace.
    ///   - policy: the new workspace's `otherApps`.
    ///   - running: bundle ids of running apps; `hidden` the hidden ones among them.
    ///   - hiddenByKosmodock: apps earlier switches hid.
    ///   - ownBundleID: Kosmodock's own, which is never touched.
    static func plan(
        leaving: Set<String>, entering: Set<String>, policy: OtherWorkspaceApps,
        running: Set<String>, hidden: Set<String>, hiddenByKosmodock: Set<String>,
        ownBundleID: String?
    ) -> Plan {
        var others = leaving.subtracting(entering).intersection(running)
        if let ownBundleID { others.remove(ownBundleID) }
        var plan = Plan()
        // The new workspace's apps Kosmodock hid come back; the ones you
        // unhid yourself, or quit, are forgotten.
        let stillHidden = hiddenByKosmodock.intersection(hidden)
        plan.unhide = stillHidden.intersection(entering)
        switch policy {
        case .keep: break
        case .hide: plan.hide = others.subtracting(hidden)
        case .quit: plan.quit = others.subtracting(neverQuit)
        }
        plan.hiddenByKosmodock = stillHidden.subtracting(entering).subtracting(plan.quit).union(plan.hide)
        return plan
    }
}
