import AppKit
import SwiftUI

// MARK: - Swipe and ⌘ + scroll over the dock

/// Turns scroll events over the dock into one workspace step per gesture: a
/// horizontal two-finger swipe, or ⌘ + scroll on any axis. Pure, so it's
/// tested without events.
struct WorkspaceSwipeTracker {
    enum Phase {
        /// A mouse wheel: no gesture phases.
        case none
        case began
        case changed
        case ended
        /// Inertia after the fingers lift.
        case momentum
    }

    struct Event {
        /// In the device's direction, whatever natural scrolling says:
        /// positive is fingers (or the wheel) going left, or up for `deltaY`.
        var deltaX: CGFloat
        var deltaY: CGFloat
        var phase: Phase
        var withCommand: Bool
        /// Seconds, as `NSEvent.timestamp`.
        var time: TimeInterval
    }

    /// Distance a trackpad gesture travels before it switches.
    static let threshold: CGFloat = 24
    /// Wheel events closer together than this are one gesture.
    static let wheelPause: TimeInterval = 0.35

    private var distanceX: CGFloat = 0
    private var distanceY: CGFloat = 0
    private var stepped = false
    private var engaged = false
    private var lastWheel: TimeInterval = -.infinity

    /// Whether `event` belongs to a workspace gesture (so it shouldn't scroll
    /// anything else), and the step it completes: 1 next, -1 previous.
    mutating func handle(_ event: Event) -> (consumed: Bool, step: Int?) {
        switch event.phase {
        case .momentum:
            return (engaged, nil)
        case .ended:
            defer { reset() }
            return (engaged, nil)
        case .began, .changed:
            if event.phase == .began { reset() }
            distanceX += event.deltaX
            distanceY += event.deltaY
            guard let step = Self.step(x: distanceX, y: distanceY, withCommand: event.withCommand, minimum: Self.threshold) else {
                return (engaged, nil)
            }
            engaged = true
            guard !stepped else { return (true, nil) }
            stepped = true
            return (true, step)
        case .none:
            guard let step = Self.step(x: event.deltaX, y: event.deltaY, withCommand: event.withCommand, minimum: 0.01) else {
                return (false, nil)
            }
            defer { lastWheel = event.time }
            return (true, event.time - lastWheel > Self.wheelPause ? step : nil)
        }
    }

    private mutating func reset() {
        distanceX = 0
        distanceY = 0
        stepped = false
        engaged = false
    }

    /// Fingers or wheel going left, or down with ⌘, go to the next workspace,
    /// as swiping left does with Spaces.
    private static func step(x: CGFloat, y: CGFloat, withCommand: Bool, minimum: CGFloat) -> Int? {
        if abs(x) >= abs(y) {
            guard abs(x) >= minimum else { return nil }
            return x > 0 ? 1 : -1
        }
        guard withCommand, abs(y) >= minimum else { return nil }
        return y < 0 ? 1 : -1
    }
}

/// Watches scroll events over the dock panel and switches workspaces.
@MainActor
final class WorkspaceSwipeMonitor {
    private weak var panel: NSWindow?
    private weak var model: AppModel?
    private var tracker = WorkspaceSwipeTracker()
    private var monitor: Any?
    /// Scroll that belongs to something else on the bar (a widget stack).
    var yields: (NSEvent) -> Bool = { _ in false }

    init(panel: NSWindow, model: AppModel) {
        self.panel = panel
        self.model = model
        // A local monitor: the dock's own events, no permission needed.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.consumes(event) ?? false }
            return consumed ? nil : event
        }
    }

    /// Handles `event` when it's for the dock; true keeps it from the dock.
    private func consumes(_ event: NSEvent) -> Bool {
        guard let panel, event.window === panel, let model, model.canSwitchWorkspaces, !yields(event) else { return false }
        let withCommand = event.modifierFlags.contains(.command)
        // A bar too wide for the screen scrolls; only ⌘ + scroll switches then.
        if !withCommand, Self.containsScrollView(panel.contentView) { return false }
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? -1 : 1
        let phase: WorkspaceSwipeTracker.Phase
        if !event.momentumPhase.isEmpty {
            phase = .momentum
        } else if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            phase = .began
        } else if event.phase.contains(.changed) {
            phase = .changed
        } else if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            phase = .ended
        } else {
            phase = .none
        }
        let result = tracker.handle(.init(
            deltaX: event.scrollingDeltaX * sign, deltaY: event.scrollingDeltaY * sign,
            phase: phase, withCommand: withCommand, time: event.timestamp
        ))
        if let step = result.step { model.activateWorkspace(step: step) }
        return result.consumed
    }

    /// Only the scrolling bar puts an `NSScrollView` in the dock.
    private static func containsScrollView(_ view: NSView?) -> Bool {
        guard let view, !view.isHidden else { return false }
        if view is NSScrollView, !view.frame.isEmpty { return true }
        return view.subviews.contains { containsScrollView($0) }
    }
}

// MARK: - Menu

/// The workspaces in the Kosmodock menu, with a check on the active one.
@MainActor
enum WorkspaceMenu {
    static func items(model: AppModel) -> [NSMenuItem] {
        let config = model.config
        guard model.canSwitchWorkspaces else { return [] }
        let activeID = config.activeWorkspace?.id
        var items: [NSMenuItem] = [.sectionHeader(title: L10n.tr("Workspaces"))]
        for (index, workspace) in config.workspaces.enumerated() {
            let id = workspace.id
            let item = ActionMenuItem(title: workspace.displayName) { [weak model] in model?.activateWorkspace(id: id) }
            item.state = id == activeID ? .on : .off
            item.image = dot(Color(hex: workspace.colorHex) ?? model.accent)
            if index < Workspace.shortcutCount {
                // Shown for reference; the global hotkey does the work.
                item.keyEquivalent = "\(index + 1)"
                item.keyEquivalentModifierMask = [.control, .option]
            }
            items.append(item)
        }
        items.append(.separator())
        return items
    }

    private static func dot(_ color: Color) -> NSImage {
        let fill = NSColor(color)
        return NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            fill.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }
}

/// A menu item that runs a closure. It's its own target; the menu keeps it.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func fire() { handler() }
}
