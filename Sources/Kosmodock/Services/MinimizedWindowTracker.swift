import AppKit
import Observation

struct MinimizedWindow: Identifiable, Equatable, Sendable {
    let ref: AXElementRef
    let pid: pid_t
    let bundleID: String
    var groupID: String
    var title: String
    /// Frame before minimizing, in AX coordinates.
    var frame: CGRect
    var minimizedAt: Date

    var id: String { "\(pid):\(ref.hashValue)" }

    static func == (lhs: MinimizedWindow, rhs: MinimizedWindow) -> Bool {
        lhs.ref == rhs.ref && lhs.groupID == rhs.groupID && lhs.title == rhs.title && lhs.frame == rhs.frame
    }
}

struct MinimizeAnimationRequest: Sendable {
    enum Direction: Sendable {
        case intoGroup
        case outOfGroup
    }

    var direction: Direction
    /// Window frame in AX coordinates.
    var windowFrame: CGRect
    var groupID: String
    var bundleID: String
    var title: String
}

/// Tracks minimized windows per dock group and drives the "minimize into the
/// group" animation.
///
/// macOS offers no public hook to redirect the WindowServer's own minimize
/// animation, and `kAXWindowMiniaturizedNotification` only arrives once the
/// window is already gone. To animate *with* the user's action, minimizes are
/// detected up front — the yellow button (mouse down/up over it), ⌘M, and
/// Kosmodock's own clicks — with the AX notification as the fallback.
@MainActor
@Observable
final class MinimizedWindowTracker {
    private(set) var windows: [MinimizedWindow] = []

    @ObservationIgnored var animationHandler: ((MinimizeAnimationRequest) -> Void)?
    /// Bundle id → group id (falls back to a general group).
    @ObservationIgnored var groupResolver: (String) -> String? = { _ in nil }

    @ObservationIgnored private let hub: AXObserverHub
    @ObservationIgnored private let windowService: WindowManagerService
    @ObservationIgnored private var recentlyAnimated: [AXElementRef: Date] = [:]
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var pendingPress: PendingPress?
    @ObservationIgnored private(set) var isEnabled = false

    private struct PendingPress {
        var id = UUID()
        var hit: MinimizeButtonHit?
        var released = false
        var releasePoint: CGPoint?
    }

    init(hub: AXObserverHub, windowService: WindowManagerService) {
        self.hub = hub
        self.windowService = windowService
    }

    #if DEBUG
    /// Snapshot rendering only: show sample entries without Accessibility.
    func injectPreviewEntries(_ entries: [MinimizedWindow]) {
        windows = entries
    }
    #endif

    // MARK: Queries

    func windows(in groupID: String) -> [MinimizedWindow] {
        windows.filter { $0.groupID == groupID }.sorted { $0.minimizedAt > $1.minimizedAt }
    }

    func count(in groupID: String) -> Int {
        windows.lazy.filter { $0.groupID == groupID }.count
    }

    func windows(forBundleID bundleID: String) -> [MinimizedWindow] {
        windows.filter { $0.bundleID == bundleID }.sorted { $0.minimizedAt > $1.minimizedAt }
    }

    // MARK: Lifecycle

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        removeMonitors()
        guard enabled else { return }
        if windowService.isTrusted {
            installMonitors()
            rescan()
        }
    }

    /// Called when Accessibility trust changes.
    func accessibilityDidChange(trusted: Bool) {
        removeMonitors()
        guard isEnabled, trusted else { return }
        installMonitors()
        rescan()
    }

    /// Picks up windows that were already minimized (e.g. before launch).
    func rescan() {
        guard isEnabled, windowService.isTrusted else { return }
        let pids = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
            .map(\.processIdentifier)
        Task {
            let found = await windowService.performAX {
                pids.flatMap { AXWindowOps.minimizedWindows(pid: $0) }
            }
            for snapshot in found { insert(snapshot, at: .distantPast) }
        }
    }

    /// Re-assigns groups after the config changed.
    func regroup() {
        var changed = false
        var next = windows
        for index in next.indices {
            guard let group = groupResolver(next[index].bundleID) else { continue }
            if next[index].groupID != group {
                next[index].groupID = group
                changed = true
            }
        }
        if changed { windows = next }
    }

    func handle(_ event: WindowEvent) {
        switch event {
        case .miniaturized(let pid, let ref):
            guard isEnabled else { return }
            Task { await windowDidMiniaturize(pid: pid, ref: ref) }
        case .deminiaturized(_, let ref), .destroyed(_, let ref):
            windows.removeAll { $0.ref == ref }
        case .appTerminated(let pid):
            windows.removeAll { $0.pid == pid }
        case .windowsChanged, .appActivated, .appLaunched, .spaceChanged:
            break
        }
    }

    // MARK: Actions

    /// Minimizes the focused window of `pid` into its group (Kosmodock click).
    func minimizeFocusedWindow(pid: pid_t) async {
        guard let snapshot = await windowService.performAX({ AXWindowOps.focusedMinimizableWindow(pid: pid) }) else { return }
        animateIntoGroup(snapshot)
        await windowService.performAX { AXWindowOps.minimize(snapshot.ref.element) }
    }

    /// Restores a window with the reverse animation (capsule → window frame).
    func restore(_ window: MinimizedWindow) async {
        animationHandler?(MinimizeAnimationRequest(
            direction: .outOfGroup, windowFrame: window.frame,
            groupID: window.groupID, bundleID: window.bundleID, title: window.title
        ))
        windows.removeAll { $0.ref == window.ref }
        let pid = window.pid
        await windowService.performAX { AXWindowOps.restore(window.ref.element, pid: pid) }
        NSRunningApplication(processIdentifier: pid)?.activate(options: [])
    }

    func restoreAll(in groupID: String) async {
        for window in windows(in: groupID).reversed() {
            await restore(window)
            try? await Task.sleep(for: .milliseconds(90))
        }
    }

    // MARK: Detection

    private func windowDidMiniaturize(pid: pid_t, ref: AXElementRef) async {
        let element = ref
        guard let snapshot = await windowService.performAX({ AXWindowOps.snapshot(of: element.element, pid: pid) }) else { return }
        let alreadyAnimated = recentlyAnimated[ref].map { Date().timeIntervalSince($0) < 3 } ?? false
        insert(snapshot, at: Date())
        if !alreadyAnimated { animateIntoGroup(snapshot) }
    }

    private func insert(_ snapshot: AXWindowSnapshot, at date: Date) {
        guard let bundleID = NSRunningApplication(processIdentifier: snapshot.pid)?.bundleIdentifier,
              let groupID = groupResolver(bundleID) else { return }
        let entry = MinimizedWindow(
            ref: snapshot.ref, pid: snapshot.pid, bundleID: bundleID, groupID: groupID,
            title: snapshot.title, frame: snapshot.frame, minimizedAt: date
        )
        if let index = windows.firstIndex(where: { $0.ref == snapshot.ref }) {
            windows[index] = entry
        } else {
            windows.append(entry)
            hub.watchDestruction(of: snapshot.ref, pid: snapshot.pid)
        }
    }

    private func animateIntoGroup(_ snapshot: AXWindowSnapshot) {
        let now = Date()
        recentlyAnimated = recentlyAnimated.filter { now.timeIntervalSince($0.value) < 10 }
        if let last = recentlyAnimated[snapshot.ref], now.timeIntervalSince(last) < 3 { return }
        guard let bundleID = NSRunningApplication(processIdentifier: snapshot.pid)?.bundleIdentifier,
              let groupID = groupResolver(bundleID) else { return }
        recentlyAnimated[snapshot.ref] = now
        animationHandler?(MinimizeAnimationRequest(
            direction: .intoGroup, windowFrame: snapshot.frame,
            groupID: groupID, bundleID: bundleID, title: snapshot.title
        ))
    }

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            let point = Self.accessibilityMouseLocation()
            MainActor.assumeIsolated { self?.mouseDown(at: point) }
        }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] _ in
            let point = Self.accessibilityMouseLocation()
            MainActor.assumeIsolated { self?.mouseUp(at: point) }
        }) {
            monitors.append(monitor)
        }
        // ⌘M (keyCode 46). Global key monitoring requires Accessibility trust.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 46,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  !event.isARepeat else { return }
            MainActor.assumeIsolated { self?.commandMPressed() }
        }) {
            monitors.append(monitor)
        }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        pendingPress = nil
    }

    private func mouseDown(at point: CGPoint) {
        let press = PendingPress()
        pendingPress = press
        Task {
            let hit = await windowService.performAX { AXWindowOps.minimizeButtonHit(at: point) }
            guard var current = pendingPress, current.id == press.id else { return }
            guard hit != nil else {
                pendingPress = nil
                return
            }
            current.hit = hit
            pendingPress = current
            if current.released { resolvePress() }
        }
    }

    private func mouseUp(at point: CGPoint) {
        guard pendingPress != nil else { return }
        pendingPress?.released = true
        pendingPress?.releasePoint = point
        // If the hit-test is still in flight it resolves the press itself.
        if pendingPress?.hit != nil { resolvePress() }
    }

    /// The minimize button acts on mouse-up inside the button.
    private func resolvePress() {
        guard let press = pendingPress else { return }
        pendingPress = nil
        guard let hit = press.hit, let release = press.releasePoint,
              hit.buttonFrame.insetBy(dx: -2, dy: -2).contains(release) else { return }
        animateIntoGroup(hit.window)
    }

    private func commandMPressed() {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier, pid != getpid() else { return }
        Task {
            guard let snapshot = await windowService.performAX({ AXWindowOps.focusedMinimizableWindow(pid: pid) }) else { return }
            animateIntoGroup(snapshot)
        }
    }

    private nonisolated static func accessibilityMouseLocation() -> CGPoint {
        let location = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: location.x, y: primaryHeight - location.y)
    }
}

/// Maps bundle identifiers to dock groups.
enum GroupResolver {
    /// First group listing the bundle id; otherwise the general group: one
    /// with id/name "system", else the last group.
    static func groupID(for bundleID: String, groups: [(id: String, name: String, bundleIDs: Set<String>)]) -> String? {
        if let match = groups.first(where: { $0.bundleIDs.contains(bundleID) }) { return match.id }
        if let general = groups.first(where: { $0.id.lowercased() == "system" || $0.name.lowercased() == "system" }) {
            return general.id
        }
        return groups.last?.id
    }
}
