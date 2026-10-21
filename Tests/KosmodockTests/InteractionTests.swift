import Carbon.HIToolbox
import Foundation
import XCTest
@testable import Kosmodock

/// Window previews, widget stacks and keyboard focus on the dock.
final class InteractionTests: XCTestCase {
    // MARK: Window matching

    private typealias Window = WindowMatching.Window

    private let frame = CGRect(x: 100, y: 80, width: 1200, height: 800)

    func testWindowsMatchByProcessAndFrame() {
        let other = CGRect(x: 0, y: 25, width: 640, height: 480)
        let ax = [Window(pid: 1, frame: frame, title: "Notes"), Window(pid: 2, frame: other)]
        let sc = [Window(pid: 2, frame: other), Window(pid: 1, frame: frame, title: "Notes"), Window(pid: 1, frame: other)]
        XCTAssertEqual(WindowMatching.match(ax: ax, sc: sc), [1, 0])
    }

    func testOtherProcessesAndDistantFramesDontMatch() {
        XCTAssertEqual(WindowMatching.match(ax: [Window(pid: 1, frame: frame)], sc: [Window(pid: 2, frame: frame)]), [nil])
        let moved = frame.offsetBy(dx: 20, dy: 0)
        XCTAssertEqual(WindowMatching.match(ax: [Window(pid: 1, frame: frame)], sc: [Window(pid: 1, frame: moved)]), [nil])
        XCTAssertEqual(WindowMatching.match(ax: [], sc: [Window(pid: 1, frame: frame)]), [])
    }

    func testSmallFrameDifferencesStillMatch() {
        let close = CGRect(x: frame.minX + 3, y: frame.minY - 2, width: frame.width + 1, height: frame.height)
        XCTAssertEqual(WindowMatching.match(ax: [Window(pid: 1, frame: frame)], sc: [Window(pid: 1, frame: close)]), [0])
        XCTAssertEqual(WindowMatching.distance(frame, close), 3)
    }

    func testWindowsWithTheSameFrameAreToldApartByTitle() {
        let ax = [Window(pid: 1, frame: frame, title: "Inbox"), Window(pid: 1, frame: frame, title: "Drafts")]
        let sc = [Window(pid: 1, frame: frame, title: "Drafts"), Window(pid: 1, frame: frame, title: "Inbox")]
        XCTAssertEqual(WindowMatching.match(ax: ax, sc: sc), [1, 0])
    }

    func testEachCaptureWindowIsUsedOnceAndTheClosestWins() {
        XCTAssertEqual(WindowMatching.match(ax: [Window(pid: 1, frame: frame), Window(pid: 1, frame: frame)], sc: [Window(pid: 1, frame: frame)]), [0, nil])
        let ax = [Window(pid: 1, frame: frame.offsetBy(dx: 4, dy: 0)), Window(pid: 1, frame: frame)]
        XCTAssertEqual(WindowMatching.match(ax: ax, sc: [Window(pid: 1, frame: frame)]), [nil, 0])
    }

    // MARK: Preview rules

    func testPreviewDelayIsClampedAndShortWhileCardsShow() {
        XCTAssertEqual(WindowPreviewRules.delay(configured: 0.4, cardsAreShowing: false), 0.4)
        XCTAssertEqual(WindowPreviewRules.delay(configured: 5, cardsAreShowing: false), 2)
        XCTAssertEqual(WindowPreviewRules.delay(configured: -1, cardsAreShowing: false), 0)
        XCTAssertEqual(WindowPreviewRules.delay(configured: .nan, cardsAreShowing: false), 0.4, "the default")
        XCTAssertEqual(WindowPreviewRules.delay(configured: 1.5, cardsAreShowing: true), WindowPreviewRules.switchDelay)
    }

    func testCardsShowForWindowsWhenEnabled() {
        XCTAssertFalse(WindowPreviewRules.showsCards(enabled: false, windowCount: 3, needsTwoWindows: false))
        XCTAssertFalse(WindowPreviewRules.showsCards(enabled: true, windowCount: 0, needsTwoWindows: false))
        XCTAssertTrue(WindowPreviewRules.showsCards(enabled: true, windowCount: 1, needsTwoWindows: false))
        XCTAssertFalse(WindowPreviewRules.showsCards(enabled: true, windowCount: 1, needsTwoWindows: true))
        XCTAssertTrue(WindowPreviewRules.showsCards(enabled: true, windowCount: 2, needsTwoWindows: true))
    }

    func testKosmodocksOwnWindowsAreNeverPreviewed() {
        let own = "dev.kosmodock.Kosmodock"
        XCTAssertFalse(WindowPreviewRules.isPreviewable(pid: 42, bundleID: "com.apple.Safari", ownPID: 42, ownBundleID: own))
        XCTAssertFalse(WindowPreviewRules.isPreviewable(pid: 7, bundleID: own, ownPID: 42, ownBundleID: own), "another instance")
        XCTAssertTrue(WindowPreviewRules.isPreviewable(pid: 7, bundleID: "com.apple.Safari", ownPID: 42, ownBundleID: own))
        XCTAssertTrue(WindowPreviewRules.isPreviewable(pid: 7, bundleID: nil, ownPID: 42, ownBundleID: own))
    }

    func testCaptureSizeKeepsTheAspectRatioAndNeverUpscales() {
        let box = WindowPreviewMetrics.thumbnail
        XCTAssertEqual(WindowPreviewRules.captureSize(for: CGSize(width: 1600, height: 1000), fitting: box, scale: 2), CGSize(width: 384, height: 240))
        XCTAssertEqual(WindowPreviewRules.captureSize(for: CGSize(width: 100, height: 50), fitting: box, scale: 2), CGSize(width: 200, height: 100))
        XCTAssertEqual(WindowPreviewRules.captureSize(for: .zero, fitting: box, scale: 2), .zero)
    }

    func testCardsFillRowsThatFitTheScreen() {
        let card = WindowPreviewMetrics.cardSize
        let spacing = WindowPreviewMetrics.spacing
        let padding = WindowPreviewMetrics.padding
        XCTAssertEqual(WindowPreviewMetrics.columns(count: 3, availableWidth: 1000), 3)
        XCTAssertEqual(WindowPreviewMetrics.columns(count: 10, availableWidth: padding * 2 + card.width * 2 + spacing), 2)
        XCTAssertEqual(WindowPreviewMetrics.columns(count: 5, availableWidth: 100), 1, "at least one")

        let size = WindowPreviewMetrics.contentSize(count: 5, columns: 2)
        XCTAssertEqual(size.width, card.width * 2 + spacing + padding * 2)
        XCTAssertEqual(size.height, WindowPreviewMetrics.headerHeight + spacing + card.height * 3 + spacing * 2 + padding * 2, "three rows")
        XCTAssertEqual(WindowPreviewMetrics.contentSize(count: 1, columns: 1), CGSize(width: 234, height: 200))
    }

    func testCardsSitAboveTheIconWithoutCoveringIt() {
        let visible = CGRect(x: 0, y: 80, width: 1440, height: 800)
        let content = WindowPreviewMetrics.contentSize(count: 2, columns: 2)
        let icon = CGRect(x: 700, y: 90, width: 40, height: 40)
        let frame = WindowPreviewMetrics.panelFrame(content: content, above: icon, within: visible)
        XCTAssertGreaterThanOrEqual(frame.minY, icon.maxY, "the panel, margins included, starts above the icon")
        XCTAssertEqual(frame.midX, icon.midX, accuracy: 1)
        XCTAssertEqual(frame.height, content.height + DockMetrics.shadowInset + WindowPreviewMetrics.bottomInset)
        // Near the screen's edge, the cards stay on it.
        let corner = WindowPreviewMetrics.panelFrame(content: content, above: CGRect(x: 1430, y: 90, width: 40, height: 40), within: visible)
        XCTAssertLessThanOrEqual(corner.maxX - DockMetrics.shadowInset, visible.maxX)
        let high = WindowPreviewMetrics.panelFrame(content: content, above: CGRect(x: 700, y: 860, width: 40, height: 40), within: visible)
        XCTAssertLessThanOrEqual(high.maxY - DockMetrics.shadowInset, visible.maxY)
    }

    func testThumbnailsAreReusedBriefly() {
        var cache = ExpiringCache<String, Int>(lifetime: 3)
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        cache.insert(1, for: "window", now: start)
        XCTAssertEqual(cache.value(for: "window", now: start.addingTimeInterval(2.9)), 1)
        XCTAssertNil(cache.value(for: "window", now: start.addingTimeInterval(3.1)))
        XCTAssertNil(cache.value(for: "other", now: start))
    }

    func testInteractionSettingsDecodeLeniently() throws {
        let defaults = try JSONDecoder().decode(BehaviorConfig.self, from: Data("{}".utf8))
        XCTAssertTrue(defaults.showsWindowPreviews)
        XCTAssertEqual(defaults.windowPreviewDelay, 0.4)
        XCTAssertFalse(defaults.windowPreviewsNeedTwoWindows)
        XCTAssertTrue(defaults.dockFocusHotKey)
        let json = #"{ "showsWindowPreviews": false, "windowPreviewDelay": 1.2, "windowPreviewsNeedTwoWindows": true, "dockFocusHotKey": false }"#
        let decoded = try JSONDecoder().decode(BehaviorConfig.self, from: Data(json.utf8))
        XCTAssertFalse(decoded.showsWindowPreviews)
        XCTAssertEqual(decoded.windowPreviewDelay, 1.2)
        XCTAssertTrue(decoded.windowPreviewsNeedTwoWindows)
        XCTAssertFalse(decoded.dockFocusHotKey)
        XCTAssertThrowsError(try JSONDecoder().decode(BehaviorConfig.self, from: Data(#"{ "windowPreviewDelay": "soon" }"#.utf8)))
    }

    // MARK: Stacks

    private let finder = "app:com.apple.finder"

    /// Finder, the "code" group, three wide tiles and a square one.
    private func stackConfig() -> DockConfig {
        var config = DockConfig()
        config.groups = [DockGroup(id: "code", name: "Code")]
        config.pinnedApps = [DockApp(name: "Finder", bundleId: "com.apple.finder")]
        config.tiles = [
            DockTile(id: "clock", kind: .clock),
            DockTile(id: "battery", kind: .battery),
            DockTile(id: "network", kind: .network),
            DockTile(id: "activity", kind: .activity, width: .square),
        ]
        return config
    }

    /// Clock leading battery and network.
    private func stacked() -> DockConfig {
        var config = stackConfig()
        config.stackTile("battery", onto: "clock")
        config.stackTile("network", onto: "clock")
        return config
    }

    func testOldConfigsWithoutStacksKeepTheirBar() throws {
        let json = #"""
        { "groups": [ { "id": "code", "name": "Code" } ],
          "tiles": [ { "kind": "clock" }, { "kind": "battery" } ],
          "order": ["tile:battery"] }
        """#
        let decoded = try JSONDecoder().decode(DockConfig.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.tiles.map(\.stack), [nil, nil])
        XCTAssertEqual(decoded.tileStacks, [:])
        XCTAssertEqual(decoded.barOrder, ["tile:battery", "code", "tile:clock"])
        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(decoded), encoding: .utf8))
        XCTAssertFalse(encoded.contains(#""stack":"#), "no stack key is written for single tiles")
    }

    func testStacksDecodeAndAreReadLeniently() throws {
        let json = #"""
        { "tiles": [ { "id": "a", "kind": "clock", "stack": ["a", "missing", "b", "b"] },
                     { "id": "b", "kind": "battery", "stack": ["c"] },
                     { "id": "c", "kind": "network", "stack": ["a"] } ] }
        """#
        var config = try JSONDecoder().decode(DockConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.tileStacks, ["a": ["a", "b"]], "no unknown ids, repeats or nesting; c can't take a lead")
        XCTAssertEqual(config.barOrder, ["tile:a", "tile:c"])
        config.normalizeStacks()
        XCTAssertEqual(config.tiles.map(\.stack), [["b"], nil, nil])
        XCTAssertThrowsError(try JSONDecoder().decode(DockConfig.self, from: Data(#"{ "tiles": [ { "kind": "clock", "stack": "b" } ] }"#.utf8)))
    }

    func testStackingTakesTheTileOffTheBarAndEveryWorkspace() {
        var config = stackConfig()
        config.workspaces = [
            Workspace(id: "work", name: "Work", items: ["code", "tile:clock", "tile:battery"]),
            Workspace(id: "home", name: "Home", items: ["tile:battery", "tile:network"]),
        ]
        config.activeWorkspaceID = "work"
        config.stackTile("battery", onto: "clock")
        XCTAssertEqual(config.tileStacks, ["clock": ["clock", "battery"]])
        XCTAssertEqual(config.barOrder, ["code", "tile:clock"])
        XCTAssertEqual(config.workspaces[1].items, ["tile:network"])
        XCTAssertFalse(config.allItemIDs.contains("tile:battery"))
        // A stacked tile can't be put on a workspace on its own.
        config.setItem("tile:battery", included: true, inWorkspace: "home")
        XCTAssertEqual(config.workspaces[1].items, ["tile:network"])
    }

    func testStackingAStackBringsAllOfItsTiles() {
        var config = stackConfig()
        config.stackTile("battery", onto: "clock")
        config.stackTile("clock", onto: "network")
        XCTAssertEqual(config.tileStacks, ["network": ["network", "clock", "battery"]])
        XCTAssertEqual(config.barOrder, [finder, "code", "tile:network", "tile:activity"])
        // A tile inside a stack leaves it for another one.
        config.stackTile("battery", onto: "activity")
        XCTAssertEqual(config.tileStacks, ["network": ["network", "clock"], "activity": ["activity", "battery"]])
        XCTAssertEqual(config.tiles.first { $0.id == "battery" }?.width, .square, "it takes the stack's width")
    }

    func testOnlyBarTilesOfTheSameWidthCanStack() {
        var config = stackConfig()
        XCTAssertEqual(config.stackCandidates(for: "clock"), ["battery", "network"], "the square tile is left out")
        XCTAssertEqual(config.stackCandidates(for: "activity"), [])
        config.stackTile("battery", onto: "clock")
        XCTAssertEqual(config.stackCandidates(for: "clock"), ["network"])
        XCTAssertEqual(config.stackCandidates(for: "battery"), ["network"], "from inside a stack, the same")
        XCTAssertEqual(config.stackCandidates(for: "network"), ["clock"], "the stack, by its lead")
        config.workspaces = [Workspace(id: "work", name: "Work", items: ["tile:clock"])]
        XCTAssertEqual(config.stackCandidates(for: "clock"), [], "only what the active bar shows")
    }

    func testMovingTheFirstTileDownHandsTheStacksPlaceToTheNext() {
        var config = stacked()
        config.moveTileInStack("clock", by: 1)
        XCTAssertEqual(config.tileStacks, ["battery": ["battery", "clock", "network"]])
        XCTAssertEqual(config.barOrder, [finder, "code", "tile:battery", "tile:activity"], "in the same place")

        var ordered = stacked()
        ordered.order = ["tile:activity", "tile:clock", "code", finder]
        ordered.workspaces = [Workspace(id: "work", name: "Work", items: ["tile:clock", "code"])]
        ordered.moveTileInStack("battery", by: -1)
        XCTAssertEqual(ordered.order, ["tile:activity", "tile:battery", "code", finder])
        XCTAssertEqual(ordered.workspaces[0].items, ["tile:battery", "code"])
        XCTAssertEqual(ordered.stack(containing: "clock"), ["battery", "clock", "network"])

        var unchanged = stacked()
        unchanged.moveTileInStack("network", by: 1)
        XCTAssertEqual(unchanged.tileStacks, stacked().tileStacks, "the last tile stays last")
    }

    func testTakingATileOutPutsItRightAfterTheStack() {
        var config = stacked()
        config.takeTileOutOfStack("battery")
        XCTAssertEqual(config.tileStacks, ["clock": ["clock", "network"]])
        XCTAssertEqual(config.barOrder, [finder, "code", "tile:clock", "tile:battery", "tile:activity"])

        var lead = stacked()
        lead.takeTileOutOfStack("clock")
        XCTAssertEqual(lead.tileStacks, ["battery": ["battery", "network"]])
        XCTAssertEqual(lead.barOrder, [finder, "code", "tile:battery", "tile:clock", "tile:activity"])

        var workspaces = stacked()
        workspaces.workspaces = [
            Workspace(id: "work", name: "Work", items: ["code", "tile:clock"]),
            Workspace(id: "home", name: "Home", items: ["tile:activity"]),
        ]
        workspaces.takeTileOutOfStack("network")
        XCTAssertEqual(workspaces.workspaces[0].items, ["code", "tile:clock", "tile:network"])
        XCTAssertEqual(workspaces.workspaces[1].items, ["tile:activity"], "a workspace without the stack doesn't get it")

        var last = stackConfig()
        last.stackTile("battery", onto: "clock")
        last.takeTileOutOfStack("battery")
        XCTAssertEqual(last.tileStacks, [:])
        XCTAssertEqual(last.tiles.map(\.stack), [nil, nil, nil, nil], "a stack of one is no stack")
    }

    func testUngroupingPutsEveryTileBackInItsPlace() {
        var config = stacked()
        config.ungroupStack(containing: "network")
        XCTAssertEqual(config.tileStacks, [:])
        XCTAssertEqual(config.barOrder, [finder, "code", "tile:clock", "tile:battery", "tile:network", "tile:activity"])
    }

    func testDeletingTheFirstTileKeepsTheStackInPlace() {
        var config = stacked()
        config.removeTileFromStack("clock")
        config.removeFromBar("tile:clock")
        config.tiles.removeAll { $0.id == "clock" }
        XCTAssertEqual(config.tileStacks, ["battery": ["battery", "network"]])
        XCTAssertEqual(config.barOrder, [finder, "code", "tile:battery", "tile:activity"])

        var member = stacked()
        member.removeTileFromStack("network")
        XCTAssertEqual(member.tileStacks, ["clock": ["clock", "battery"]])
    }

    func testAStacksTilesShareOneWidth() {
        var config = stacked()
        if let index = config.tiles.firstIndex(where: { $0.id == "battery" }) { config.tiles[index].width = .square }
        config.matchStackWidths(to: "battery")
        XCTAssertEqual(config.tiles.filter { $0.id != "activity" }.map(\.width), [.square, .square, .square])
    }

    func testNewWidgetsJoinTheStackOffTheBar() {
        var config = stacked()
        let id = config.addTile(DockTile(id: "clock", kind: .clock, width: .square), toStackOf: "battery")
        XCTAssertEqual(id, "clock-2")
        XCTAssertEqual(config.stack(containing: "clock"), ["clock", "battery", "network", "clock-2"])
        XCTAssertEqual(config.tiles.last?.width, .wide, "the stack's width")
        XCTAssertEqual(config.barOrder, [finder, "code", "tile:clock", "tile:activity"])
    }

    @MainActor
    func testAStackTurnsAndWraps() {
        let selection = WidgetStackSelection()
        let stack = ["clock", "battery", "network"]
        XCTAssertEqual(selection.shownID(in: stack), "clock")
        selection.step(stack, by: -1)
        XCTAssertEqual(selection.shownID(in: stack), "network")
        XCTAssertEqual(selection.lastStep, -1)
        selection.step(stack, by: 1)
        XCTAssertEqual(selection.shownID(in: stack), "clock")
        selection.step(stack, by: 1)
        XCTAssertEqual(selection.shownID(in: ["battery", "clock", "network"]), "battery", "the tile on show survives a reorder")
        XCTAssertEqual(WidgetStackMath.index(after: 0, step: -4, count: 3), 2)
    }

    // MARK: Scrolling over a stack

    private func scroll(_ x: CGFloat, _ y: CGFloat, _ phase: WorkspaceSwipeTracker.Phase, at time: TimeInterval = 0) -> WorkspaceSwipeTracker.Event {
        .init(deltaX: x, deltaY: y, phase: phase, withCommand: false, time: time)
    }

    func testATrackpadSwipeTurnsTheStackOncePerGesture() {
        var tracker = WidgetStackScrollTracker()
        XCTAssertNil(tracker.handle(scroll(0, 0, .began)))
        XCTAssertNil(tracker.handle(scroll(0, 10, .changed)))
        XCTAssertEqual(tracker.handle(scroll(0, 10, .changed)), 1, "fingers up: the next tile")
        XCTAssertNil(tracker.handle(scroll(0, 40, .changed)))
        XCTAssertNil(tracker.handle(scroll(0, 0, .ended)))
        XCTAssertNil(tracker.handle(scroll(0, 30, .momentum)))
        XCTAssertNil(tracker.handle(scroll(0, 0, .began)))
        XCTAssertEqual(tracker.handle(scroll(0, -25, .changed)), -1)
        XCTAssertNil(tracker.handle(scroll(0, 0, .ended)))
        XCTAssertNil(tracker.handle(scroll(0, 0, .began)))
        XCTAssertEqual(tracker.handle(scroll(25, 3, .changed)), 1, "fingers left: the next tile, as with workspaces")
    }

    func testWheelNotchesTurnTheStackAtAMeasuredPace() {
        var tracker = WidgetStackScrollTracker()
        XCTAssertEqual(tracker.handle(scroll(0, 1, .none, at: 10)), 1)
        XCTAssertNil(tracker.handle(scroll(0, 1, .none, at: 10.05)), "a fast spin doesn't race through")
        XCTAssertEqual(tracker.handle(scroll(0, -1, .none, at: 10.3)), -1)
        XCTAssertNil(tracker.handle(scroll(0, 0, .none, at: 11)))
    }

    func testTheScrollingBarKeepsItsHorizontalScroll() {
        var tracker = WidgetStackScrollTracker()
        XCTAssertNil(tracker.handle(scroll(0, 0, .began), horizontal: false))
        XCTAssertNil(tracker.handle(scroll(40, 2, .changed), horizontal: false))
        XCTAssertEqual(tracker.handle(scroll(40, 17, .changed), horizontal: false), 1)
        XCTAssertNil(tracker.handle(scroll(5, 0, .none, at: 20), horizontal: false))
    }

    // MARK: Keyboard focus

    func testFocusStartsWhereItLeftOrAtTheFirstItem() {
        let ids = [finder, "code", "tile:clock"]
        XCTAssertEqual(DockKeyboardNavigation.initial(in: ids, previous: "code"), "code")
        XCTAssertEqual(DockKeyboardNavigation.initial(in: ids, previous: "gone"), finder)
        XCTAssertEqual(DockKeyboardNavigation.initial(in: ids, previous: nil), finder)
        XCTAssertNil(DockKeyboardNavigation.initial(in: [], previous: nil))
    }

    func testFocusMovesOverBarItemsAndWraps() {
        let ids = [finder, "code", "tile:clock"]
        XCTAssertEqual(DockKeyboardNavigation.move(from: finder, by: 1, in: ids), "code")
        XCTAssertEqual(DockKeyboardNavigation.move(from: "tile:clock", by: 1, in: ids), finder)
        XCTAssertEqual(DockKeyboardNavigation.move(from: finder, by: -1, in: ids), "tile:clock")
        XCTAssertEqual(DockKeyboardNavigation.move(from: "gone", by: 1, in: ids), finder, "an item that left the bar")
        XCTAssertEqual(DockKeyboardNavigation.move(from: nil, by: -1, in: ids), "tile:clock")
        XCTAssertNil(DockKeyboardNavigation.move(from: "code", by: 1, in: []))
    }

    func testFocusFollowsTheStacksPlaceOnTheBar() {
        var config = stacked()
        let ids = config.barOrder
        XCTAssertEqual(DockKeyboardNavigation.move(from: "code", by: 1, in: ids), "tile:clock", "a stack is one item")
        XCTAssertEqual(DockKeyboardNavigation.move(from: "tile:clock", by: 1, in: ids), "tile:activity")
        config.moveTileInStack("clock", by: 1)
        XCTAssertEqual(DockKeyboardNavigation.initial(in: config.barOrder, previous: "tile:clock"), finder)
    }

    func testKeysMapToFocusCommands() {
        XCTAssertEqual(DockKeyboardCommand(keyCode: UInt16(kVK_LeftArrow)), .move(-1))
        XCTAssertEqual(DockKeyboardCommand(keyCode: UInt16(kVK_RightArrow)), .move(1))
        XCTAssertEqual(DockKeyboardCommand(keyCode: UInt16(kVK_Tab)), .move(1))
        XCTAssertEqual(DockKeyboardCommand(keyCode: UInt16(kVK_Tab), shift: true), .move(-1))
        XCTAssertEqual(DockKeyboardCommand(keyCode: UInt16(kVK_DownArrow)), .turnStack(1))
        XCTAssertEqual(DockKeyboardCommand(keyCode: UInt16(kVK_UpArrow)), .turnStack(-1))
        XCTAssertEqual(DockKeyboardCommand(keyCode: UInt16(kVK_Return)), .open)
        XCTAssertEqual(DockKeyboardCommand(keyCode: UInt16(kVK_Space)), .open)
        XCTAssertEqual(DockKeyboardCommand(keyCode: UInt16(kVK_ANSI_KeypadEnter)), .open)
        XCTAssertEqual(DockKeyboardCommand(keyCode: UInt16(kVK_Escape)), .leave)
        XCTAssertEqual(DockKeyboardCommand(keyCode: UInt16(kVK_ANSI_Q)), .other)
    }

    @MainActor
    func testTheFocusShortcutIsControlOptionD() {
        XCTAssertEqual(DockKeyboardFocusController.shortcut, HotKeyCenter.Shortcut(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey | optionKey)))
        XCTAssertNotEqual(DockKeyboardFocusController.shortcut, HotKeyCenter.controlOption(digit: 4), "apart from the workspace shortcuts")
    }
}
