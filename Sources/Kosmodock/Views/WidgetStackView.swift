import AppKit
import SwiftUI

// MARK: - Bar tile

/// A tile's place on the bar: the tile on its own, or the stack it leads.
struct BarTileView: View {
    @Environment(AppModel.self) private var model
    let tile: DockTile
    var isSquare = false

    var body: some View {
        if let tiles = model.stackTiles(leadID: tile.id), tiles.count > 1 {
            WidgetStackView(lead: tile, tiles: tiles, isSquare: isSquare)
        } else {
            TileView(tile: tile, isSquare: isSquare)
        }
    }
}

/// Several tiles in one place; scrolling over it (`WidgetStackScrollMonitor`)
/// shows the next one, and dots under it tell which. Every tile is drawn with
/// the lead's width, so turning the stack never resizes the dock.
struct WidgetStackView: View {
    @Environment(AppModel.self) private var model
    let lead: DockTile
    let tiles: [DockTile]
    var isSquare = false

    var body: some View {
        let ids = tiles.map(\.id)
        let shownID = model.widgetStacks.shownID(in: ids) ?? lead.id
        let index = ids.firstIndex(of: shownID) ?? 0
        let forward = model.widgetStacks.lastStep > 0
        let shown = Self.tile(tiles[index], width: lead.width)
        ZStack {
            TileView(tile: shown, isSquare: isSquare)
                .id(shown.id)
                .transition(.asymmetric(
                    insertion: .offset(y: forward ? 10 : -10).combined(with: .opacity),
                    removal: .offset(y: forward ? -10 : 10).combined(with: .opacity)
                ))
        }
        .overlay(alignment: .bottom) {
            // In the bar's padding below the tile, like the running indicator.
            StackDots(count: tiles.count, index: index)
                .offset(y: 5)
                .allowsHitTesting(false)
        }
        // Every tile of the stack opens its popover from here.
        .background {
            GeometryReader { proxy in
                let frame = proxy.frame(in: .named(DockSpace.name))
                Color.clear.preference(
                    key: CapsuleFramesKey.self,
                    value: Dictionary(uniqueKeysWithValues: tiles.map { (DockConfig.itemID(for: $0), frame) })
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("Widget stack, %lld of %lld", index + 1, tiles.count))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: model.stepStack(leadID: lead.id, by: 1)
            case .decrement: model.stepStack(leadID: lead.id, by: -1)
            @unknown default: break
            }
        }
    }

    private static func tile(_ tile: DockTile, width: TileWidth) -> DockTile {
        var tile = tile
        tile.width = width
        return tile
    }
}

/// Which tile of a stack is on show.
struct StackDots: View {
    let count: Int
    let index: Int

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<count, id: \.self) { position in
                Circle()
                    .fill(Color.primary.opacity(position == index ? 0.85 : 0.28))
                    .frame(width: 3, height: 3)
            }
        }
        .animation(.easeOut(duration: 0.15), value: index)
        .accessibilityHidden(true)
    }
}

// MARK: - Menu

/// A tile's right-click menu, with the stack actions.
struct TileContextMenu: View {
    @Environment(AppModel.self) private var model
    let tile: DockTile

    var body: some View {
        let config = model.config
        if tile.kind == .pet {
            Button("Put Out Food") { model.pets.feed(tileID: tile.id) }
        }
        Button("Show Details") { model.tap(tile) }
        Button("Edit Widgets…") { model.openSettings(.tiles) }
        Divider()
        if let stack = config.stack(containing: tile.id) {
            let candidates = config.stackCandidates(for: tile.id)
            Menu("Add to Stack") {
                ForEach(candidates, id: \.self) { id in
                    Button(title(forBarTile: id, in: config)) { model.stackTile(id, onto: tile.id) }
                }
                if !candidates.isEmpty { Divider() }
                Menu("New Widget") {
                    ForEach(TileKind.allCases) { kind in
                        Button {
                            model.addTile(kind, toStackOf: tile.id)
                        } label: {
                            Label(kind.title, systemImage: kind.symbol)
                        }
                    }
                }
            }
            Button("Move Up in Stack") { model.moveTileInStack(tile.id, by: -1) }
                .disabled(stack.first == tile.id)
            Button("Move Down in Stack") { model.moveTileInStack(tile.id, by: 1) }
                .disabled(stack.last == tile.id)
            Button("Take Out of Stack") { model.takeTileOutOfStack(tile.id) }
            Button("Ungroup Stack") { model.ungroupStack(containing: tile.id) }
        } else {
            let candidates = config.stackCandidates(for: tile.id)
            Menu("Stack With") {
                ForEach(candidates, id: \.self) { id in
                    Button(title(forBarTile: id, in: config)) { model.stackTile(tile.id, onto: id) }
                }
            }
            .disabled(candidates.isEmpty)
        }
        Divider()
        Button("Remove from Dock") { model.deleteTile(id: tile.id) }
    }

    /// A single tile's title, or a stack's as its lead's plus a count.
    private func title(forBarTile id: String, in config: DockConfig) -> String {
        let name = model.tile(id: id)?.title ?? id
        guard let stack = config.tileStacks[id] else { return name }
        return L10n.tr("%@ and %lld more", name, stack.count - 1)
    }
}

// MARK: - Scrolling

/// Turns a stack when the pointer scrolls over it, through a local monitor
/// on the dock panel (the dock's own events, no permission). The workspace
/// swipe yields to it (`claims(_:)`), except for ⌘ + scroll, which always
/// switches workspaces. On the scrolling bar, horizontal scroll stays the bar's.
@MainActor
final class WidgetStackScrollMonitor {
    private weak var panel: NSWindow?
    private weak var model: AppModel?
    /// Item frames in the dock's coordinate space (`DockSpace`).
    private let frames: () -> [String: CGRect]
    private var tracker = WidgetStackScrollTracker()
    /// The stack a trackpad gesture began over; it keeps the gesture.
    private var gestureStack: String?
    private var monitor: Any?

    init(panel: NSWindow, model: AppModel, frames: @escaping () -> [String: CGRect]) {
        self.panel = panel
        self.model = model
        self.frames = frames
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.consumes(event) ?? false }
            return consumed ? nil : event
        }
    }

    /// Whether `event` belongs to a stack. Asked by the workspace swipe too,
    /// so it gives the same answer for the same event.
    func claims(_ event: NSEvent) -> Bool {
        stack(for: event) != nil
    }

    private func stack(for event: NSEvent) -> String? {
        guard let panel, event.window === panel, !event.modifierFlags.contains(.command) else { return nil }
        let phase = Self.phase(of: event)
        switch phase {
        case .began:
            gestureStack = stackLead(at: event)
        case .changed, .ended, .momentum:
            break
        case .none:
            return stackLead(at: event)
        }
        guard let gestureStack else { return nil }
        // On the scrolling bar a mostly horizontal gesture scrolls the bar.
        if scrollsBar, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) { return nil }
        return gestureStack
    }

    private func consumes(_ event: NSEvent) -> Bool {
        guard let lead = stack(for: event), let model else { return false }
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? -1 : 1
        let step = tracker.handle(.init(
            deltaX: event.scrollingDeltaX * sign, deltaY: event.scrollingDeltaY * sign,
            phase: Self.phase(of: event), withCommand: false, time: event.timestamp
        ), horizontal: !scrollsBar)
        if let step { model.stepStack(leadID: lead, by: step) }
        return true
    }

    /// The lead of the stack under the pointer.
    private func stackLead(at event: NSEvent) -> String? {
        guard let model, let content = panel?.contentView else { return nil }
        let location = event.locationInWindow
        // `DockSpace` is the hosting view's space: top-left origin.
        let point = CGPoint(x: location.x, y: content.bounds.height - location.y)
        let frames = frames()
        return model.config.tileStacks.keys.first { lead in
            frames[DockConfig.itemID(forTile: lead)]?.contains(point) ?? false
        }
    }

    private var scrollsBar: Bool {
        Self.containsScrollView(panel?.contentView)
    }

    private static func phase(of event: NSEvent) -> WorkspaceSwipeTracker.Phase {
        if !event.momentumPhase.isEmpty { return .momentum }
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) { return .began }
        if event.phase.contains(.changed) { return .changed }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) { return .ended }
        return .none
    }

    /// Only the scrolling bar puts an `NSScrollView` in the dock.
    private static func containsScrollView(_ view: NSView?) -> Bool {
        guard let view, !view.isHidden else { return false }
        if view is NSScrollView, !view.frame.isEmpty { return true }
        return view.subviews.contains { containsScrollView($0) }
    }
}

// MARK: - App model

extension AppModel {
    /// The tiles of the stack `leadID` leads, in order; nil for a tile on its own.
    func stackTiles(leadID: String) -> [DockTile]? {
        guard let ids = config.tileStacks[leadID] else { return nil }
        return ids.compactMap(tile(id:))
    }

    /// Puts `tileID` (with its stack, when it leads one) into `targetID`'s stack.
    func stackTile(_ tileID: String, onto targetID: String) {
        withAnimation(spring) {
            editBar { $0.stackTile(tileID, onto: targetID) }
        }
        if let stack = config.stack(containing: tileID) { widgetStacks.show(tileID, in: stack) }
    }

    /// A new widget of `kind` at the end of `tileID`'s stack, shown at once.
    func addTile(_ kind: TileKind, toStackOf tileID: String) {
        let tile = Self.newTile(kind)
        var newID: String?
        editBar { newID = $0.addTile(tile, toStackOf: tileID) }
        if let newID, let stack = config.stack(containing: newID) {
            withAnimation(spring) { widgetStacks.show(newID, in: stack) }
        }
    }

    func moveTileInStack(_ tileID: String, by offset: Int) {
        editBar { $0.moveTileInStack(tileID, by: offset) }
    }

    func takeTileOutOfStack(_ tileID: String) {
        withAnimation(spring) {
            editBar { $0.takeTileOutOfStack(tileID) }
        }
    }

    func ungroupStack(containing tileID: String) {
        withAnimation(spring) {
            editBar { $0.ungroupStack(containing: tileID) }
        }
    }

    /// Shows the next (`1`) or previous (`-1`) tile of the stack `leadID` leads.
    func stepStack(leadID: String, by step: Int) {
        guard let ids = config.tileStacks[leadID] else { return }
        // The details of the tile turned away close with it.
        if let open = popoverItemID, ids.map(DockConfig.itemID(forTile:)).contains(open) { dismissPopover?() }
        withAnimation(spring) { widgetStacks.step(ids, by: step) }
    }

    /// The tile a stack shows, or the tile itself when it's on its own.
    func shownTile(onBar tile: DockTile) -> DockTile {
        guard let ids = config.tileStacks[tile.id], let shown = widgetStacks.shownID(in: ids) else { return tile }
        return self.tile(id: shown) ?? tile
    }
}
