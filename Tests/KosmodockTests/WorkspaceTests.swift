import Carbon.HIToolbox
import Foundation
import XCTest
@testable import Kosmodock

/// Workspaces: one bar each, over the same groups, pinned apps and tiles.
final class WorkspaceTests: XCTestCase {
    private let finder = "app:com.apple.finder"

    private func config(order: [String] = []) -> DockConfig {
        var config = DockConfig()
        config.groups = [DockGroup(id: "code", name: "Code"), DockGroup(id: "web", name: "Web"), DockGroup(id: "ai", name: "AI")]
        config.pinnedApps = [DockApp(name: "Finder", bundleId: "com.apple.finder")]
        config.tiles = [DockTile(id: "clock", kind: .clock)]
        config.order = order
        return config
    }

    /// "work" shows code and the clock; "home" shows web and Finder.
    private func withWorkspaces() -> DockConfig {
        var config = config()
        config.workspaces = [
            Workspace(id: "work", name: "Work", items: ["code", "tile:clock"]),
            Workspace(id: "home", name: "Home", colorHex: "#2EC27E", items: [finder, "web"], otherApps: .keep),
        ]
        config.activeWorkspaceID = "work"
        return config
    }

    // MARK: Config

    func testOldConfigDecodesWithoutWorkspacesAndKeepsItsBar() throws {
        let json = #"""
        { "groups": [ { "id": "code", "name": "Code" }, { "id": "web", "name": "Web" } ],
          "pinnedApps": [ { "bundleId": "com.apple.finder" } ],
          "tiles": [ { "kind": "clock" } ],
          "order": ["web", "tile:clock"] }
        """#
        let decoded = try JSONDecoder().decode(DockConfig.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.workspaces, [])
        XCTAssertNil(decoded.activeWorkspaceID)
        XCTAssertNil(decoded.activeWorkspace)
        XCTAssertEqual(decoded.barOrder, ["web", "tile:clock", finder, "code"], "the order, then the rest as before")
        let again = try JSONDecoder().decode(DockConfig.self, from: JSONEncoder().encode(decoded))
        XCTAssertEqual(again, decoded)
    }

    func testWorkspacesDecodeLeniently() throws {
        let json = #"""
        { "workspaces": [ { "name": "Deep Work", "items": ["code"] }, { "id": "deep-work" }, { "id": "x", "name": "X", "otherApps": "quit" } ],
          "activeWorkspaceID": "x" }
        """#
        let decoded = try JSONDecoder().decode(DockConfig.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.workspaces.map(\.id), ["deep-work", "deep-work-2", "x"], "ids are unique, from the name when missing")
        XCTAssertEqual(decoded.workspaces[0].otherApps, .hide)
        XCTAssertEqual(decoded.workspaces[0].colorHex, Workspace.colors[0])
        XCTAssertEqual(decoded.workspaces[1].name, L10n.newWorkspace)
        XCTAssertEqual(decoded.workspaces[1].items, [])
        XCTAssertEqual(decoded.activeWorkspace?.id, "x")
        XCTAssertThrowsError(try JSONDecoder().decode(DockConfig.self, from: Data(#"{ "workspaces": [ { "otherApps": "explode" } ] }"#.utf8)))

        let roundTrip = try JSONDecoder().decode(DockConfig.self, from: JSONEncoder().encode(decoded))
        XCTAssertEqual(roundTrip, decoded)
    }

    func testAnUnknownActiveWorkspaceMeansTheFirst() {
        var config = withWorkspaces()
        config.activeWorkspaceID = "gone"
        XCTAssertEqual(config.activeWorkspace?.id, "work")
        config.activeWorkspaceID = nil
        XCTAssertEqual(config.barOrder, ["code", "tile:clock"])
    }

    func testTheFirstWorkspaceCopiesTheBar() {
        var config = config(order: ["tile:clock", "web"])
        let bar = config.barOrder
        let id = config.addWorkspace(name: L10n.mainWorkspace)
        XCTAssertEqual(config.activeWorkspaceID, id, "the first workspace is active")
        XCTAssertEqual(config.workspaces.first?.items, bar)
        XCTAssertEqual(config.barOrder, bar, "nothing changes on the bar")

        config.setItem("web", included: false, inWorkspace: id)
        let second = config.addWorkspace(name: L10n.newWorkspace)
        XCTAssertEqual(config.activeWorkspaceID, id, "adding another doesn't switch")
        XCTAssertEqual(config.workspaces.last?.items, config.barOrder, "a new one copies the current bar")
        XCTAssertNotEqual(config.workspaces.last?.colorHex, config.workspaces.first?.colorHex)
        XCTAssertNotEqual(second, id)
    }

    // MARK: Bar order

    func testEachWorkspaceShowsOnlyItsItemsInItsOrder() {
        var config = withWorkspaces()
        XCTAssertEqual(config.barOrder, ["code", "tile:clock"])
        config.workspaces[0].items = ["tile:clock", "gone", "code", "tile:clock"]
        XCTAssertEqual(config.barOrder, ["tile:clock", "code"], "unknown and repeated ids are dropped")
        config.activeWorkspaceID = "home"
        XCTAssertEqual(config.barOrder, [finder, "web"])
        XCTAssertEqual(config.allItemIDs, [finder, "code", "web", "ai", "tile:clock"], "every item, as a single bar")
    }

    func testAddingWhileAWorkspaceIsActiveAddsToItOnly() {
        var config = withWorkspaces()
        config.addToBar { $0.groups.append(DockGroup(id: "new", name: "New")) }
        XCTAssertEqual(config.barOrder, ["code", "tile:clock", "new"])
        XCTAssertFalse(config.workspaces[1].items.contains("new"))
        config.addToBar { $0.tiles.append(DockTile(id: "battery", kind: .battery)) }
        XCTAssertEqual(config.barOrder.last, "tile:battery")

        var single = self.config()
        single.addToBar { $0.groups.append(DockGroup(id: "new", name: "New")) }
        XCTAssertEqual(single.barOrder.last, "new", "without workspaces it goes to the end, as before")
        XCTAssertEqual(single.workspaces, [])
    }

    func testAPinnedAppAlreadyOnAnotherWorkspaceJoinsTheActiveOne() {
        var config = withWorkspaces()
        config.showInActiveWorkspace(finder)
        XCTAssertEqual(config.barOrder, ["code", "tile:clock", finder])
        config.showInActiveWorkspace(finder)
        XCTAssertEqual(config.barOrder.filter { $0 == finder }.count, 1)
    }

    func testDeletingAnItemRemovesItFromEveryWorkspace() {
        var config = withWorkspaces()
        config.workspaces[1].items.append("code")
        config.order = ["code", "web"]
        config.groups.removeAll { $0.id == "code" }
        config.removeFromBar("code")
        XCTAssertEqual(config.order, ["web"])
        XCTAssertEqual(config.workspaces.map(\.items), [["tile:clock"], [finder, "web"]])
    }

    func testMovesStayInsideTheActiveWorkspace() {
        var config = withWorkspaces()
        config.workspaces[0].items = ["code", "tile:clock", "ai"]
        config.moveBarItems(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(config.barOrder, ["ai", "code", "tile:clock"])
        config.moveBarItem("code", by: 1)
        XCTAssertEqual(config.barOrder, ["ai", "tile:clock", "code"])
        XCTAssertEqual(config.workspaces[1].items, [finder, "web"], "the other workspace keeps its order")
        XCTAssertEqual(config.order, [], "and so does the single bar")
        config.settleOrder()
        XCTAssertEqual(config.order, [])
    }

    func testTheSidebarMovesGroupsAmongTheWorkspacesPlaces() {
        var config = withWorkspaces()
        config.workspaces[0].items = ["code", "tile:clock", "ai"]
        // The sidebar: code and ai on this bar, then web, which it hides.
        XCTAssertEqual(config.sidebarGroupIDs, ["code", "ai", "web"])
        config.moveGroups(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        XCTAssertEqual(config.barOrder, ["ai", "tile:clock", "code"], "the tile keeps its place")
        XCTAssertEqual(config.groups.map(\.id), ["ai", "code", "web"])
        // Moving a hidden group only reorders the list; it stays hidden.
        config.moveGroups(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(config.barOrder, ["ai", "tile:clock", "code"])
        XCTAssertEqual(config.groups.map(\.id), ["web", "ai", "code"])
    }

    func testEditingAWorkspaceThatIsNotActive() {
        var config = withWorkspaces()
        config.setItem("ai", included: true, inWorkspace: "home")
        config.setItem(finder, included: false, inWorkspace: "home")
        config.setItem("nope", included: true, inWorkspace: "home")
        XCTAssertEqual(config.shownItemIDs(inWorkspace: "home"), ["web", "ai"])
        config.moveItem("ai", by: -1, inWorkspace: "home")
        XCTAssertEqual(config.shownItemIDs(inWorkspace: "home"), ["ai", "web"])
        XCTAssertEqual(config.barOrder, ["code", "tile:clock"], "the active bar is untouched")
    }

    // MARK: Workspaces

    func testNextAndPreviousWrapAround() {
        var config = withWorkspaces()
        config.workspaces.append(Workspace(id: "play", name: "Play"))
        XCTAssertEqual(config.workspaceID(steppingBy: 1), "home")
        XCTAssertEqual(config.workspaceID(steppingBy: -1), "play", "previous of the first is the last")
        config.activeWorkspaceID = "play"
        XCTAssertEqual(config.workspaceID(steppingBy: 1), "work", "next of the last is the first")
        XCTAssertEqual(config.workspaceID(steppingBy: -4), "home")
        XCTAssertNil(self.config().workspaceID(steppingBy: 1), "nothing to step through without workspaces")
    }

    func testTheLastWorkspaceCantBeDeleted() {
        var config = withWorkspaces()
        config.deleteWorkspace(id: "work")
        XCTAssertEqual(config.workspaces.map(\.id), ["home"])
        XCTAssertEqual(config.activeWorkspace?.id, "home", "deleting the active one activates its neighbor")
        config.deleteWorkspace(id: "home")
        XCTAssertEqual(config.workspaces.map(\.id), ["home"])
    }

    func testASingleDockShowsEverythingAgain() {
        var config = withWorkspaces()
        config.activeWorkspaceID = "home"
        config.useSingleDock()
        XCTAssertEqual(config.workspaces, [])
        XCTAssertNil(config.activeWorkspaceID)
        XCTAssertEqual(config.barOrder, [finder, "web", "code", "ai", "tile:clock"], "the workspace's order first")
    }

    func testMovingWorkspaces() {
        var config = withWorkspaces()
        config.moveWorkspaces(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        XCTAssertEqual(config.workspaces.map(\.id), ["home", "work"])
        XCTAssertEqual(config.activeWorkspace?.id, "work", "the active one stays active")
    }

    @MainActor
    func testShortcutsGoUpToNine() {
        XCTAssertEqual(Workspace.shortcut(index: 0), "⌃⌥1")
        XCTAssertEqual(Workspace.shortcut(index: 8), "⌃⌥9")
        XCTAssertNil(Workspace.shortcut(index: 9))
        XCTAssertEqual(HotKeyCenter.controlOption(digit: 1), HotKeyCenter.Shortcut(keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(controlKey | optionKey)))
        XCTAssertEqual(HotKeyCenter.controlOption(digit: 9)?.keyCode, UInt32(kVK_ANSI_9))
        XCTAssertNil(HotKeyCenter.controlOption(digit: 10))
    }

    // MARK: Switching apps

    private let own = "dev.kosmodock.Kosmodock"

    func testSwitchingHidesTheAppsLeftBehindAndBringsThemBack() {
        // Work has Xcode, Terminal and Notes; Home has Terminal and Music.
        let work: Set = ["xcode", "terminal", "notes", own]
        let home: Set = ["terminal", "music"]
        let running: Set = ["xcode", "terminal", "notes", "music", "slack", own]
        let toHome = WorkspaceSwitch.plan(
            leaving: work, entering: home, policy: .hide,
            running: running, hidden: ["notes"], hiddenByKosmodock: [], ownBundleID: own
        )
        XCTAssertEqual(toHome.hide, ["xcode"], "Terminal is in both, Notes was already hidden, Kosmodock is never touched")
        XCTAssertEqual(toHome.quit, [])
        XCTAssertEqual(toHome.unhide, [])
        XCTAssertEqual(toHome.hiddenByKosmodock, ["xcode"])

        let backToWork = WorkspaceSwitch.plan(
            leaving: home, entering: work, policy: .hide,
            running: running, hidden: ["notes", "xcode"], hiddenByKosmodock: toHome.hiddenByKosmodock, ownBundleID: own
        )
        XCTAssertEqual(backToWork.unhide, ["xcode"], "only what Kosmodock hid; Notes stays hidden")
        XCTAssertEqual(backToWork.hide, ["music"])
        XCTAssertEqual(backToWork.hiddenByKosmodock, ["music"])
    }

    func testAppsHiddenForAnotherWorkspaceStayHidden() {
        // Xcode was hidden leaving Work; going from Home to Play keeps it hidden.
        let plan = WorkspaceSwitch.plan(
            leaving: ["music"], entering: ["safari"], policy: .keep,
            running: ["xcode", "music", "safari"], hidden: ["xcode"], hiddenByKosmodock: ["xcode"], ownBundleID: own
        )
        XCTAssertEqual(plan, WorkspaceSwitch.Plan(hiddenByKosmodock: ["xcode"]), "keep leaves Music open")
    }

    func testAppsYouUnhidOrQuitAreForgotten() {
        let plan = WorkspaceSwitch.plan(
            leaving: [], entering: ["xcode", "mail"], policy: .hide,
            running: ["xcode"], hidden: [], hiddenByKosmodock: ["xcode", "mail", "notes"], ownBundleID: own
        )
        XCTAssertEqual(plan.unhide, [], "Xcode is visible again and Mail quit")
        XCTAssertEqual(plan.hiddenByKosmodock, [])
    }

    func testQuitAsksTheAppsLeftBehindButNeverTheFinderOrKosmodock() {
        let plan = WorkspaceSwitch.plan(
            leaving: ["xcode", "notes", "com.apple.finder", own, "closed"], entering: ["notes"], policy: .quit,
            running: ["xcode", "notes", "com.apple.finder", own], hidden: ["xcode"], hiddenByKosmodock: ["xcode"], ownBundleID: own
        )
        XCTAssertEqual(plan.quit, ["xcode"], "hidden apps quit too; closed ones aren't running")
        XCTAssertEqual(plan.hide, [])
        XCTAssertEqual(plan.hiddenByKosmodock, [], "a quit app isn't remembered")
    }
}

/// One swipe or ⌘ + scroll over the dock moves one workspace.
final class WorkspaceSwipeTests: XCTestCase {
    private typealias Event = WorkspaceSwipeTracker.Event

    private func swipe(_ deltas: [CGFloat], vertical: Bool = false, command: Bool = false, tracker: inout WorkspaceSwipeTracker) -> [Int] {
        var steps: [Int] = []
        for (index, delta) in deltas.enumerated() {
            let phase: WorkspaceSwipeTracker.Phase = index == 0 ? .began : .changed
            let event = Event(deltaX: vertical ? 0 : delta, deltaY: vertical ? delta : 0, phase: phase, withCommand: command, time: Double(index) * 0.01)
            if let step = tracker.handle(event).step { steps.append(step) }
        }
        _ = tracker.handle(Event(deltaX: 0, deltaY: 0, phase: .ended, withCommand: command, time: 1))
        for _ in 0..<5 {
            if let step = tracker.handle(Event(deltaX: 30, deltaY: 0, phase: .momentum, withCommand: command, time: 1)).step { steps.append(step) }
        }
        return steps
    }

    func testOneSwipeIsOneStep() {
        var tracker = WorkspaceSwipeTracker()
        XCTAssertEqual(swipe([4, 10, 20, 40, 60, 80], tracker: &tracker), [1], "fingers left: next, once")
        XCTAssertEqual(swipe([-10, -30, -50], tracker: &tracker), [-1], "fingers right: previous")
        XCTAssertEqual(swipe([3, 5, 4], tracker: &tracker), [], "too short")
    }

    func testVerticalScrollNeedsCommand() {
        var tracker = WorkspaceSwipeTracker()
        XCTAssertEqual(swipe([-10, -30, -50], vertical: true, tracker: &tracker), [])
        XCTAssertFalse(tracker.handle(Event(deltaX: 0, deltaY: -40, phase: .began, withCommand: false, time: 0)).consumed, "plain vertical scrolling passes through")
        _ = tracker.handle(Event(deltaX: 0, deltaY: 0, phase: .ended, withCommand: false, time: 0))
        XCTAssertEqual(swipe([-10, -30, -50], vertical: true, command: true, tracker: &tracker), [1], "⌘ + scroll down: next")
        XCTAssertEqual(swipe([10, 30], vertical: true, command: true, tracker: &tracker), [-1])
    }

    func testAWheelSpinIsOneStep() {
        var tracker = WorkspaceSwipeTracker()
        func wheel(_ deltaY: CGFloat, at time: TimeInterval, command: Bool = true) -> Int? {
            tracker.handle(Event(deltaX: 0, deltaY: deltaY, phase: .none, withCommand: command, time: time)).step
        }
        XCTAssertEqual(wheel(-1, at: 10), 1)
        XCTAssertNil(wheel(-1, at: 10.1))
        XCTAssertNil(wheel(-1, at: 10.3), "still the same spin")
        XCTAssertEqual(wheel(1, at: 11), -1, "after a pause, a new step")
        XCTAssertNil(wheel(-1, at: 12, command: false), "a plain wheel scrolls")
    }
}
