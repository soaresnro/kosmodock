import AppKit

/// Smart auto-hide, used when screen space isn't reserved: the dock slides
/// below the screen edge while a window overlaps it, and comes back when the
/// pointer touches the bottom edge or the overlap goes away.
@MainActor
final class IntellihideController {
    private(set) var isEnabled = false
    private(set) var isHidden = false

    /// The dock bar as shown, in Cocoa screen coordinates.
    var dockFrameProvider: () -> CGRect? = { nil }
    var screenProvider: () -> NSScreen? = { NSScreen.screens.first }
    /// Keeps the dock visible (popover open, menu tracking…).
    var isPinned: () -> Bool = { false }
    var applyHidden: (Bool) -> Void = { _ in }

    private var overlapping = false
    private var peekUntil: Date?
    private var monitors: [Any] = []
    private var timer: Timer?
    private var hideTask: Task<Void, Never>?
    private var overlapTask: Task<Void, Never>?

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        teardown()
        if enabled {
            install()
            refreshOverlap()
        } else {
            setHidden(false)
        }
    }

    func handle(_ event: WindowEvent) {
        guard isEnabled else { return }
        scheduleOverlapCheck()
    }

    /// Shows the dock briefly, e.g. so a minimize animation has a target.
    func peek(for duration: TimeInterval) {
        guard isEnabled else { return }
        peekUntil = Date().addingTimeInterval(duration)
        evaluate()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration + 0.05))
            self?.evaluate()
        }
    }

    /// Re-evaluates after something pinned/unpinned the dock.
    func evaluate() {
        guard isEnabled, let dock = dockFrameProvider(), let screen = screenProvider() else {
            setHidden(false)
            return
        }
        let mouse = NSEvent.mouseLocation
        let peeking = peekUntil.map { $0 > Date() } ?? false
        let hovering = !isHidden && dock.insetBy(dx: -14, dy: -14).contains(mouse)
        let atEdge = mouse.y <= screen.frame.minY + 2
            && mouse.x >= dock.minX - 60 && mouse.x <= dock.maxX + 60

        if isPinned() || peeking || atEdge || !overlapping {
            hideTask?.cancel()
            hideTask = nil
            setHidden(false)
        } else if !hovering, !isHidden, hideTask == nil {
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard let self, !Task.isCancelled else { return }
                self.hideTask = nil
                let stillHovering = self.dockFrameProvider()?.insetBy(dx: -14, dy: -14).contains(NSEvent.mouseLocation) ?? false
                if self.overlapping, !stillHovering, !self.isPinned() { self.setHidden(true) }
            }
        } else if hovering {
            hideTask?.cancel()
            hideTask = nil
        }
    }

    // MARK: Overlap

    /// True when any normal window's bounds (Quartz coordinates) intersect the
    /// dock's rect.
    nonisolated static func overlaps(windowBounds: [CGRect], dockRect: CGRect) -> Bool {
        let zone = dockRect.insetBy(dx: 2, dy: 2)
        return windowBounds.contains { $0.intersects(zone) }
    }

    private func scheduleOverlapCheck() {
        overlapTask?.cancel()
        overlapTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            self?.refreshOverlap()
        }
    }

    private func refreshOverlap() {
        guard isEnabled, let dock = dockFrameProvider() else { return }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let dockQuartz = TilingEngine.accessibilityRect(fromCocoa: dock, primaryScreenHeight: primaryHeight)
        overlapping = Self.overlaps(windowBounds: Self.normalWindowBounds(), dockRect: dockQuartz)
        evaluate()
    }

    /// On-screen, layer-0 windows of other apps. Bounds need no Screen
    /// Recording permission.
    private static func normalWindowBounds() -> [CGRect] {
        let me = getpid()
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return info.compactMap { window in
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  (window[kCGWindowOwnerPID as String] as? pid_t) != me,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let dictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary),
                  bounds.width > 1, bounds.height > 1 else { return nil }
            return bounds
        }
    }

    // MARK: Plumbing

    private func setHidden(_ hidden: Bool) {
        guard hidden != isHidden else { return }
        isHidden = hidden
        applyHidden(hidden)
    }

    private func install() {
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.evaluate() }
            return event
        }) {
            monitors.append(monitor)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshOverlap() }
        }
    }

    private func teardown() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        timer?.invalidate()
        timer = nil
        hideTask?.cancel()
        hideTask = nil
        overlapTask?.cancel()
        overlapTask = nil
        overlapping = false
    }
}
