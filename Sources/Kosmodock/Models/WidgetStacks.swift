import Foundation
import Observation

// MARK: - Model
//
// A widget stack is several tiles in one place on the bar. Its first tile
// leads: the lead's `tile:<id>` is the stack's bar item (in `order` and in
// every workspace), and `DockTile.stack` on the lead lists the tiles after it.
// The other tiles have no bar place of their own, so `barOrder` leaves them
// out. Configs without `stack` keys have no stacks and keep their bar.

extension DockConfig {
    /// Every stack's tile ids in order, keyed by its lead. Read leniently from
    /// `DockTile.stack`: unknown ids, the lead itself, repeats, a tile another
    /// stack already holds and a lead of its own stack (no nesting) are skipped,
    /// and a list left empty is no stack.
    var tileStacks: [String: [String]] {
        let known = Set(tiles.map(\.id))
        var members = Set<String>()
        var leads = Set<String>()
        var stacks: [String: [String]] = [:]
        for tile in tiles where !members.contains(tile.id) {
            var list = [tile.id]
            for id in tile.stack ?? [] where known.contains(id) && !list.contains(id) && !members.contains(id) && !leads.contains(id) {
                list.append(id)
            }
            guard list.count > 1 else { continue }
            leads.insert(tile.id)
            members.formUnion(list.dropFirst())
            stacks[tile.id] = list
        }
        return stacks
    }

    /// Tiles inside a stack after its lead: they have no bar place of their own.
    var stackedTileIDs: Set<String> {
        Set(tileStacks.values.flatMap { $0.dropFirst() })
    }

    /// Tiles that take a place on the bar: single tiles and stack leads.
    var barTiles: [DockTile] {
        let stacked = stackedTileIDs
        return tiles.filter { !stacked.contains($0.id) }
    }

    /// The stack holding `tileID`, lead first; `nil` for a tile on its own.
    func stack(containing tileID: String) -> [String]? {
        tileStacks.values.first { $0.contains(tileID) }
    }

    /// Bar tiles that `tileID` can stack with: single tiles and stacks on the
    /// active bar, as wide as its own stack (or itself), outside its stack.
    func stackCandidates(for tileID: String) -> [String] {
        let own = stack(containing: tileID) ?? [tileID]
        guard let width = tileWithID(own[0])?.width else { return [] }
        let ownIDs = Set(own)
        let onBar = Set(barOrder)
        return barTiles
            .filter { onBar.contains(Self.itemID(for: $0)) && !ownIDs.contains($0.id) && $0.width == width }
            .map(\.id)
    }

    // MARK: Editing

    /// Puts `tileID`'s bar item at the end of `targetID`'s stack (forming one
    /// when the target is on its own). A stack lead brings its whole stack; a
    /// tile inside a stack leaves it. The moved tiles lose their bar place and
    /// take the target's width.
    mutating func stackTile(_ tileID: String, onto targetID: String) {
        normalizeStacks()
        guard tileID != targetID, tileWithID(tileID) != nil, let targetWidth = tileWithID(targetID)?.width else { return }
        let target = stack(containing: targetID) ?? [targetID]
        guard !target.contains(tileID) else { return }
        var moving = [tileID]
        if let source = stack(containing: tileID) {
            if source.first == tileID {
                moving = source
                removeFromBar(Self.itemID(forTile: tileID))
            } else {
                setStack(source.filter { $0 != tileID })
            }
        } else {
            removeFromBar(Self.itemID(forTile: tileID))
        }
        setStack(target + moving)
        for id in moving { updateTile(id) { $0.width = targetWidth } }
    }

    /// Adds a new tile at the end of `tileID`'s stack; it takes the stack's
    /// width and no bar place. Returns the new tile's id.
    @discardableResult
    mutating func addTile(_ tile: DockTile, toStackOf tileID: String) -> String? {
        normalizeStacks()
        guard let width = tileWithID(tileID)?.width else { return nil }
        var tile = tile
        tile.width = width
        tile.stack = nil
        tiles = Self.normalizedTileIDs(tiles + [tile])
        guard let id = tiles.last?.id else { return nil }
        setStack((stack(containing: tileID) ?? [tileID]) + [id])
        return id
    }

    /// Moves a tile earlier (`-1`) or later (`1`) in its stack. A new first
    /// tile takes the stack's place on the bar.
    mutating func moveTileInStack(_ tileID: String, by offset: Int) {
        normalizeStacks()
        guard var list = stack(containing: tileID), let index = list.firstIndex(of: tileID) else { return }
        let target = min(max(0, index + offset), list.count - 1)
        guard target != index else { return }
        let lead = list[0]
        list.swapAt(index, target)
        if list[0] != lead { promote(list[0], over: lead) }
        setStack(list)
    }

    /// Takes a tile out of its stack and puts it on the bar right after the
    /// stack, wherever the stack is (the bar and each workspace that has it).
    mutating func takeTileOutOfStack(_ tileID: String) {
        normalizeStacks()
        guard let list = stack(containing: tileID) else { return }
        settleOrderIfSingleBar()
        let rest = detach(tileID, from: list)
        insertItemIDs([Self.itemID(forTile: tileID)], after: Self.itemID(forTile: rest[0]))
    }

    /// Splits a stack: its tiles go back on the bar in stack order, in its place.
    mutating func ungroupStack(containing tileID: String) {
        normalizeStacks()
        guard let list = stack(containing: tileID) else { return }
        settleOrderIfSingleBar()
        for id in list { updateTile(id) { $0.stack = nil } }
        insertItemIDs(list.dropFirst().map(Self.itemID(forTile:)), after: Self.itemID(forTile: list[0]))
    }

    /// Before a tile is deleted: it leaves its stack, and when it leads, the
    /// next tile takes the stack's place on the bar.
    mutating func removeTileFromStack(_ tileID: String) {
        normalizeStacks()
        guard let list = stack(containing: tileID) else { return }
        detach(tileID, from: list)
    }

    /// Gives every tile of `tileID`'s stack its width, so the stack never
    /// changes size while it turns.
    mutating func matchStackWidths(to tileID: String) {
        guard let width = tileWithID(tileID)?.width, let list = stack(containing: tileID) else { return }
        for id in list where tileWithID(id)?.width != width { updateTile(id) { $0.width = width } }
    }

    /// Rewrites every `stack` list as `tileStacks` reads it.
    mutating func normalizeStacks() {
        let stacks = tileStacks
        for index in tiles.indices {
            let list = stacks[tiles[index].id].map { Array($0.dropFirst()) }
            if tiles[index].stack != list { tiles[index].stack = list }
        }
    }

    // MARK: Helpers

    /// A tile's bar item id from its id alone, as `itemID(for:)` gives it.
    static func itemID(forTile id: String) -> String { "tile:\(id)" }

    private func tileWithID(_ id: String) -> DockTile? {
        tiles.first { $0.id == id }
    }

    private mutating func updateTile(_ id: String, _ change: (inout DockTile) -> Void) {
        guard let index = tiles.firstIndex(where: { $0.id == id }) else { return }
        change(&tiles[index])
    }

    /// Writes `list` as one stack: the first tile leads, the others follow.
    private mutating func setStack(_ list: [String]) {
        guard let lead = list.first else { return }
        for id in list.dropFirst() { updateTile(id) { $0.stack = nil } }
        updateTile(lead) { $0.stack = list.count > 1 ? Array(list.dropFirst()) : nil }
    }

    /// Takes `tileID` out of `list` (its stack) and returns the rest, whose
    /// first tile now leads in the old lead's place.
    @discardableResult
    private mutating func detach(_ tileID: String, from list: [String]) -> [String] {
        let rest = list.filter { $0 != tileID }
        if list.first == tileID, let next = rest.first { promote(next, over: tileID) }
        updateTile(tileID) { $0.stack = nil }
        setStack(rest)
        return rest
    }

    /// `newLead` takes `oldLead`'s bar place: its item id in `order` and every
    /// workspace, and its index in `tiles`, which places tiles when `order`
    /// leaves them out.
    private mutating func promote(_ newLead: String, over oldLead: String) {
        let old = Self.itemID(forTile: oldLead), new = Self.itemID(forTile: newLead)
        order = order.map { $0 == old ? new : $0 }
        for index in workspaces.indices {
            workspaces[index].items = workspaces[index].items.map { $0 == old ? new : $0 }
        }
        if let a = tiles.firstIndex(where: { $0.id == oldLead }), let b = tiles.firstIndex(where: { $0.id == newLead }) {
            tiles.swapAt(a, b)
        }
    }

    /// Without workspaces, fixes the bar order first, so tiles inserted next
    /// to a stack stay there instead of going to their default place.
    private mutating func settleOrderIfSingleBar() {
        if workspaces.isEmpty { settleOrder() }
    }

    /// Puts `ids` right after `anchor` in `order` and in every workspace that
    /// has `anchor`.
    private mutating func insertItemIDs(_ ids: [String], after anchor: String) {
        func inserting(into list: [String]) -> [String] {
            guard list.contains(anchor) else { return list }
            var list = list.filter { !ids.contains($0) }
            if let index = list.firstIndex(of: anchor) { list.insert(contentsOf: ids, at: index + 1) }
            return list
        }
        order = inserting(into: order)
        for index in workspaces.indices {
            workspaces[index].items = inserting(into: workspaces[index].items)
        }
    }
}

// MARK: - Turning a stack

enum WidgetStackMath {
    /// The index `step` places after `index` among `count`, wrapping around.
    static func index(after index: Int, step: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index + step) % count + count) % count
    }
}

/// Which tile each stack shows. In memory only: a relaunch shows each stack's
/// first tile. Kept by tile id, so reordering or merging stacks keeps the
/// tile on show.
@MainActor
@Observable
final class WidgetStackSelection {
    private(set) var shown: Set<String> = []
    /// The last turn's direction, for the transition: 1 next, -1 previous.
    private(set) var lastStep = 1

    /// The tile `stack` (ids, lead first) shows.
    func shownID(in stack: [String]) -> String? {
        stack.first(where: shown.contains) ?? stack.first
    }

    func show(_ tileID: String, in stack: [String]) {
        shown.subtract(stack)
        shown.insert(tileID)
    }

    /// Shows the next (`1`) or previous (`-1`) tile, wrapping around.
    func step(_ stack: [String], by step: Int) {
        guard stack.count > 1, let current = shownID(in: stack), let index = stack.firstIndex(of: current) else { return }
        lastStep = step < 0 ? -1 : 1
        show(stack[WidgetStackMath.index(after: index, step: step, count: stack.count)], in: stack)
    }
}

/// Turns scroll events over a stack into one step per gesture: a trackpad
/// swipe on either axis, or a mouse wheel notch (rate-limited, so a fast spin
/// doesn't race through the stack). Pure, so it's tested without events.
struct WidgetStackScrollTracker {
    /// Distance a trackpad gesture travels before it turns the stack.
    static let threshold: CGFloat = 18
    /// Least time between two wheel steps.
    static let wheelInterval: TimeInterval = 0.18

    private var distanceX: CGFloat = 0
    private var distanceY: CGFloat = 0
    private var stepped = false
    private var lastWheelStep: TimeInterval = -.infinity

    /// The step `event` completes: 1 next (fingers or wheel going up or left),
    /// -1 previous. `horizontal: false` counts only vertical movement, for the
    /// scrolling bar, whose horizontal scroll moves the bar.
    mutating func handle(_ event: WorkspaceSwipeTracker.Event, horizontal: Bool = true) -> Int? {
        switch event.phase {
        case .momentum:
            return nil
        case .ended:
            reset()
            return nil
        case .began, .changed:
            if event.phase == .began { reset() }
            distanceX += horizontal ? event.deltaX : 0
            distanceY += event.deltaY
            guard !stepped, let step = Self.step(x: distanceX, y: distanceY, minimum: Self.threshold) else { return nil }
            stepped = true
            return step
        case .none:
            let x = horizontal ? event.deltaX : 0
            guard let step = Self.step(x: x, y: event.deltaY, minimum: 0.01),
                  event.time - lastWheelStep >= Self.wheelInterval else { return nil }
            lastWheelStep = event.time
            return step
        }
    }

    private mutating func reset() {
        distanceX = 0
        distanceY = 0
        stepped = false
    }

    private static func step(x: CGFloat, y: CGFloat, minimum: CGFloat) -> Int? {
        let value = abs(x) > abs(y) ? x : y
        guard abs(value) >= minimum else { return nil }
        return value > 0 ? 1 : -1
    }
}
