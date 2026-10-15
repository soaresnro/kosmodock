import AppKit
import ApplicationServices
import Observation
import OSLog
import Security

extension Logger {
    /// `log show --info --predicate 'subsystem == "dev.kosmodock.Kosmodock"'`
    static let windows = Logger(subsystem: "dev.kosmodock.Kosmodock", category: "windows")
}

enum TileRegion: Sendable {
    case left
    case right
    case maximize
}

/// Window orchestration through the Accessibility API. AX calls are blocking
/// IPC into other apps, so they run on a private serial queue to keep the
/// dock's animations smooth even when a target app is slow to respond.
@MainActor
@Observable
final class WindowManagerService {
    private(set) var isTrusted = AXIsProcessTrusted()

    @ObservationIgnored private var trustTimer: Timer?
    @ObservationIgnored private let queue = DispatchQueue(label: "dev.kosmodock.accessibility", qos: .userInitiated)
    /// Called when Accessibility trust is granted or revoked.
    @ObservationIgnored var onTrustChange: ((Bool) -> Void)?
    @ObservationIgnored private var hasPromptedThisSession = false

    /// Polls trust so the UI updates as soon as permission is granted in
    /// System Settings (macOS sends no notification for it).
    func startMonitoringTrust() {
        Logger.windows.notice("Accessibility \(self.isTrusted ? "granted" : "not granted", privacy: .public) at launch; signature \(Self.isAdHocSigned ? "ad-hoc" : "stable", privacy: .public)")
        trustTimer?.invalidate()
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.refreshTrust() }
        }
    }

    @discardableResult
    func refreshTrust() -> Bool {
        let trusted = AXIsProcessTrusted()
        updateTrust(trusted)
        return trusted
    }

    private func updateTrust(_ trusted: Bool) {
        guard trusted != isTrusted else { return }
        isTrusted = trusted
        Logger.windows.notice("Accessibility \(trusted ? "granted" : "revoked", privacy: .public)")
        onTrustChange?(trusted)
    }

    /// Shows the system prompt once per session (it registers Kosmodock in
    /// the Accessibility list); later requests just open the settings pane.
    func requestAccess() {
        let prompt = !hasPromptedThisSession
        hasPromptedThisSession = true
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        updateTrust(trusted)
        if !trusted, !prompt { openAccessibilitySettings() }
    }

    /// Ad-hoc signatures change with every build, and macOS ties the
    /// Accessibility grant to the signature — so the grant doesn't survive.
    static let isAdHocSigned: Bool = {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let details = info as? [String: Any] else { return true }
        let flags = (details[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        return flags & 0x2 != 0 // kSecCodeSignatureAdhoc
    }()

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Tiling

    /// Tiles the windows of `pids` (in group order) into `frame`, given in
    /// AppKit screen coordinates. Returns the number of windows placed.
    @discardableResult
    func tile(pids: [pid_t], layout: TilingLayout, frame: CGRect, gap: CGFloat) async -> Int {
        guard refreshTrust() else {
            requestAccess()
            return 0
        }
        let bounds = Self.accessibilityRect(fromCocoa: frame)
        return await onQueue {
            AXWindowOps.tile(pids: pids, layout: layout, bounds: bounds, gap: gap)
        }
    }

    func tile(pid: pid_t, region: TileRegion, frame: CGRect, gap: CGFloat) async {
        guard refreshTrust() else {
            requestAccess()
            return
        }
        let bounds = Self.accessibilityRect(fromCocoa: frame)
        let target: CGRect? = switch region {
        case .left: TilingEngine.frames(for: .splitHorizontal50_50, count: 2, in: bounds, gap: gap).first
        case .right: TilingEngine.frames(for: .splitHorizontal50_50, count: 2, in: bounds, gap: gap).last
        case .maximize: TilingEngine.frames(for: .maximizeAll, count: 1, in: bounds, gap: gap).first
        }
        guard let target else { return }
        await onQueue {
            AXWindowOps.place(pid: pid, frame: target)
        }
    }

    /// Waits until every pid exposes at least one tileable window, or times out.
    func waitForWindows(pids: [pid_t], timeout: TimeInterval) async {
        guard isTrusted else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let ready = await onQueue {
                pids.allSatisfy { !AXWindowOps.tileableWindows(pid: $0).isEmpty }
            }
            if ready { return }
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    /// True when the app has at least one standard, non-minimized window.
    func hasVisibleWindows(pid: pid_t) async -> Bool {
        guard isTrusted else { return true }
        return await onQueue { !AXWindowOps.tileableWindows(pid: pid).isEmpty }
    }

    /// Runs blocking Accessibility work on the private AX queue.
    func performAX<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await onQueue(work)
    }

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    static var primaryScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    private static func accessibilityRect(fromCocoa rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? rect.maxY
        return TilingEngine.accessibilityRect(fromCocoa: rect, primaryScreenHeight: primaryHeight)
    }
}

// MARK: - Safe work area

/// The part of the dock's screen windows may occupy, plus the dock itself.
/// Cocoa rects use AppKit coordinates (origin bottom-left of the primary
/// display); the `accessibility…` accessors flip them to the AX/Quartz space
/// (origin top-left), where `y + height` is a window's bottom edge.
struct SafeWorkArea: Equatable, Sendable {
    var screenFrame: CGRect
    var workFrame: CGRect
    var dockFrame: CGRect
    var reservesSpace: Bool
    var primaryScreenHeight: CGFloat

    /// Height of the band, measured from the bottom of the screen, that
    /// windows must stay out of.
    var reservedBottomHeight: CGFloat { workFrame.minY - screenFrame.minY }

    var accessibilityWorkFrame: CGRect { flip(workFrame) }
    var accessibilityScreenFrame: CGRect { flip(screenFrame) }
    var accessibilityDockFrame: CGRect { flip(dockFrame) }

    private func flip(_ rect: CGRect) -> CGRect {
        TilingEngine.accessibilityRect(fromCocoa: rect, primaryScreenHeight: primaryScreenHeight)
    }
}

enum ScreenSpaceMath {
    /// The frame a window must take so its bottom edge stays above the
    /// reserved band, or `nil` when it already complies or isn't on the dock's
    /// screen. All rects are in AX coordinates (origin top-left).
    ///
    /// Windows that fit the work area's height are moved up; taller ones are
    /// pinned to the top of the work area and shrunk to end at the reserved
    /// line. Fixed-size windows are only moved.
    static func adjustedFrame(for window: CGRect, workArea: CGRect, screen: CGRect, canResize: Bool) -> CGRect? {
        // The title bar decides which display a window belongs to.
        let titleBar = CGPoint(x: window.midX, y: window.minY + min(window.height, 30) / 2)
        guard screen.contains(titleBar) else { return nil }
        let limit = workArea.maxY
        guard window.maxY > limit + 0.5 else { return nil }

        var frame = window
        let available = limit - workArea.minY
        if window.height <= available {
            frame.origin.y = max(workArea.minY, limit - window.height)
        } else if canResize {
            frame.origin.y = workArea.minY
            frame.size.height = available
        } else {
            frame.origin.y = workArea.minY
        }
        return frame.integral == window.integral ? nil : frame
    }

    /// When the reserved line moves down (more room), a window that ended
    /// exactly on the previous line grows to the new one — the way windows
    /// fitted to the native Dock follow it when it shrinks.
    static func grownFrame(for window: CGRect, previousLimit: CGFloat, workArea: CGRect, screen: CGRect, canResize: Bool) -> CGRect? {
        let limit = workArea.maxY
        guard canResize, previousLimit < limit - 0.5, abs(window.maxY - previousLimit) <= 1.5 else { return nil }
        let titleBar = CGPoint(x: window.midX, y: window.minY + min(window.height, 30) / 2)
        guard screen.contains(titleBar) else { return nil }
        var frame = window
        frame.size.height += limit - window.maxY
        return frame
    }
}

/// Keeps every window's bottom edge above the dock — the "reserved space"
/// macOS only grants the native Dock, enforced here through Accessibility.
@MainActor
final class BottomMarginEnforcer {
    private let windows: WindowManagerService
    private let memory = EnforcementMemory()
    private var dirtyPIDs = Set<pid_t>()
    private var flushTask: Task<Void, Never>?
    private var safetyNet: Timer?
    /// Previous reserved line (AX y) whose windows should follow the new one.
    private var pendingGrowLine: CGFloat?

    var isEnabled = false {
        didSet { updateSafetyNet() }
    }
    var exclusions: Set<String> = []
    var workAreaProvider: () -> SafeWorkArea? = { nil }
    var allPIDsProvider: () -> [pid_t] = { [] }

    init(windows: WindowManagerService) {
        self.windows = windows
    }

    func handle(_ event: WindowEvent) {
        switch event {
        case .windowsChanged(let pid), .appActivated(let pid), .appLaunched(let pid), .deminiaturized(let pid, _):
            markDirty([pid])
        case .appTerminated, .miniaturized, .destroyed, .spaceChanged:
            break
        }
    }

    /// Some apps don't deliver moved/resized notifications for observers
    /// registered on the application element; re-checking the frontmost app
    /// periodically guarantees it is corrected within a moment anyway.
    private func updateSafetyNet() {
        if isEnabled, safetyNet == nil {
            safetyNet = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
                    self?.markDirty([pid])
                }
            }
        } else if !isEnabled {
            safetyNet?.invalidate()
            safetyNet = nil
        }
    }

    /// The reserved band moved: re-check every window, and let windows that
    /// were fitted to `previousLine` follow it if it moved down.
    func workAreaDidChange(previousLine: CGFloat?) {
        if let previousLine { pendingGrowLine = previousLine }
        enforceAll()
    }

    /// Re-checks every observed app (after the work area changed).
    func enforceAll() {
        memory.reset()
        markDirty(allPIDsProvider())
    }

    private func markDirty(_ pids: [pid_t]) {
        guard isEnabled, !pids.isEmpty else { return }
        dirtyPIDs.formUnion(pids)
        scheduleFlush(after: .milliseconds(120))
    }

    private func scheduleFlush(after delay: Duration) {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self else { return }
            self.flushTask = nil
            await self.flush()
        }
    }

    private func flush() async {
        guard isEnabled, let area = workAreaProvider(), area.reservesSpace else {
            dirtyPIDs.removeAll()
            return
        }
        // Never fight a drag or live resize: wait for the mouse to come up.
        if NSEvent.pressedMouseButtons != 0 {
            scheduleFlush(after: .milliseconds(150))
            return
        }
        let me = getpid()
        let pids = dirtyPIDs.filter { pid in
            guard pid != me, let app = NSRunningApplication(processIdentifier: pid) else { return false }
            return !exclusions.contains(app.bundleIdentifier ?? "")
        }
        dirtyPIDs.removeAll()
        guard !pids.isEmpty else { return }

        let workArea = area.accessibilityWorkFrame
        let screen = area.accessibilityScreenFrame
        let memory = self.memory
        let growLine = pendingGrowLine
        pendingGrowLine = nil
        Logger.windows.info("Enforcing \(pids.count, privacy: .public) app(s); reserved line y=\(Int(workArea.maxY), privacy: .public) (reserved \(Int(area.reservedBottomHeight), privacy: .public) pt)")
        await windows.performAX {
            for pid in pids {
                AXWindowOps.enforce(pid: pid, workArea: workArea, screen: screen, growFrom: growLine, memory: memory)
            }
        }
    }
}

/// Remembers windows whose app refused our last adjustment (minimum sizes,
/// fixed frames) so the enforcer doesn't loop on its own resize notifications.
final class EnforcementMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var refused: [AXElementRef: CGRect] = [:]

    func wasRefused(_ ref: AXElementRef, at frame: CGRect) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return refused[ref] == frame
    }

    func record(_ ref: AXElementRef, refusedAt frame: CGRect?) {
        lock.lock()
        defer { lock.unlock() }
        if refused.count > 512 { refused.removeAll() }
        refused[ref] = frame
    }

    func reset() {
        lock.lock()
        refused.removeAll()
        lock.unlock()
    }
}

/// A window captured on the AX queue (frame in AX coordinates).
struct AXWindowSnapshot: Sendable {
    let ref: AXElementRef
    let pid: pid_t
    let title: String
    let frame: CGRect
}

struct MinimizeButtonHit: Sendable {
    let window: AXWindowSnapshot
    let buttonFrame: CGRect
}

/// Thin, synchronous wrappers over AXUIElement. Call only off the main thread.
enum AXWindowOps {
    static func tile(pids: [pid_t], layout: TilingLayout, bounds: CGRect, gap: CGFloat) -> Int {
        let perApp = pids.map { (pid: $0, windows: tileableWindows(pid: $0)) }

        var selected: [(pid: pid_t, window: AXUIElement)] = []
        if layout == .maximizeAll {
            for app in perApp {
                selected += app.windows.map { (pid: app.pid, window: $0) }
            }
        } else {
            for app in perApp {
                if let main = app.windows.first { selected.append((app.pid, main)) }
            }
            // Fewer apps than slots: pull in additional windows round-robin.
            if let capacity = layout.capacity, selected.count < capacity {
                var depth = 1
                fill: while selected.count < capacity {
                    var added = false
                    for app in perApp where app.windows.count > depth {
                        selected.append((app.pid, app.windows[depth]))
                        added = true
                        if selected.count == capacity { break fill }
                    }
                    if !added { break }
                    depth += 1
                }
            }
        }
        guard !selected.isEmpty else { return 0 }

        let frames = TilingEngine.frames(for: layout, count: selected.count, in: bounds, gap: gap)
        let uniquePIDs = selected.map(\.pid).reduce(into: [pid_t]()) { if !$0.contains($1) { $0.append($1) } }

        withEnhancedUIDisabled(uniquePIDs) {
            for (entry, frame) in zip(selected, frames) {
                setBool(entry.window, kAXMinimizedAttribute, false)
                setFrame(entry.window, frame)
            }
        }

        // Raise back-to-front so the group's first app ends up on top.
        for entry in selected.reversed() {
            AXUIElementPerformAction(entry.window, kAXRaiseAction as CFString)
        }
        for pid in uniquePIDs.reversed() {
            setBool(AXUIElementCreateApplication(pid), kAXFrontmostAttribute, true)
            usleep(25_000)
        }
        return selected.count
    }

    static func place(pid: pid_t, frame: CGRect) {
        guard let window = tileableWindows(pid: pid).first else { return }
        withEnhancedUIDisabled([pid]) {
            setBool(window, kAXMinimizedAttribute, false)
            setFrame(window, frame)
        }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        setBool(AXUIElementCreateApplication(pid), kAXFrontmostAttribute, true)
    }

    /// Standard, non-fullscreen windows with the main window first.
    static func tileableWindows(pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.5)
        guard let windows = copy(app, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        var tileable = windows.filter { window in
            guard (copy(window, kAXSubroleAttribute) as? String) == (kAXStandardWindowSubrole as String) else { return false }
            return (copy(window, "AXFullScreen") as? Bool) != true
        }
        if let main = element(app, kAXMainWindowAttribute),
           let index = tileable.firstIndex(where: { CFEqual($0, main) }), index > 0 {
            tileable.insert(tileable.remove(at: index), at: 0)
        }
        return tileable
    }

    static func setFrame(_ window: AXUIElement, _ frame: CGRect) {
        var origin = frame.origin
        var size = frame.size
        guard let position = AXValueCreate(.cgPoint, &origin),
              let dimensions = AXValueCreate(.cgSize, &size) else { return }
        // Size → position → size: apps clamp size to the screen they're on, so
        // resizing again after the move lands the exact frame across displays.
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, dimensions)
        let moved = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        let resized = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, dimensions)
        if moved != .success || resized != .success {
            Logger.windows.error("AX set frame failed: position \(moved.rawValue, privacy: .public), size \(resized.rawValue, privacy: .public)")
        }
    }

    /// Chromium/Electron apps animate AX-driven resizes while
    /// AXEnhancedUserInterface is on; disable it for the duration of a tile.
    private static func withEnhancedUIDisabled(_ pids: [pid_t], _ body: () -> Void) {
        var restored: [AXUIElement] = []
        for pid in pids {
            let app = AXUIElementCreateApplication(pid)
            if (copy(app, "AXEnhancedUserInterface") as? Bool) == true {
                setBool(app, "AXEnhancedUserInterface", false)
                restored.append(app)
            }
        }
        body()
        for app in restored { setBool(app, "AXEnhancedUserInterface", true) }
    }

    // MARK: Screen-space enforcement

    /// Moves/shrinks every standard window of `pid` that reaches into the
    /// reserved band. Called on the AX queue.
    static func enforce(pid: pid_t, workArea: CGRect, screen: CGRect, growFrom previousLimit: CGFloat? = nil, memory: EnforcementMemory) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        guard let windows = copy(app, kAXWindowsAttribute) as? [AXUIElement] else { return }
        for window in windows where isStandard(window) {
            guard (copy(window, kAXMinimizedAttribute) as? Bool) != true,
                  (copy(window, "AXFullScreen") as? Bool) != true,
                  let current = frame(of: window) else { continue }
            let ref = AXElementRef(window)
            if memory.wasRefused(ref, at: current) { continue }
            let canResize = isSettable(window, kAXSizeAttribute)
            let shrunk = ScreenSpaceMath.adjustedFrame(for: current, workArea: workArea, screen: screen, canResize: canResize)
            let grown = previousLimit.flatMap {
                ScreenSpaceMath.grownFrame(for: current, previousLimit: $0, workArea: workArea, screen: screen, canResize: canResize)
            }
            guard let target = shrunk ?? grown else { continue }

            withEnhancedUIDisabled([pid]) { setFrame(window, target) }

            // Apps with minimum sizes may refuse; remember so we don't loop.
            let result = frame(of: window)
            let complies = result.map {
                ScreenSpaceMath.adjustedFrame(for: $0, workArea: workArea, screen: screen, canResize: false) == nil
            } ?? true
            memory.record(ref, refusedAt: complies ? nil : result)
            Logger.windows.info("pid \(pid, privacy: .public): \(String(describing: current), privacy: .public) → \(String(describing: target), privacy: .public); now \(String(describing: result), privacy: .public)\(complies ? "" : " (refused)", privacy: .public)")
        }
    }

    // MARK: Window inspection

    static func isStandard(_ window: AXUIElement) -> Bool {
        (copy(window, kAXSubroleAttribute) as? String) == (kAXStandardWindowSubrole as String)
    }

    static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
    }

    /// Frame in AX coordinates (origin top-left of the primary display).
    static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = copy(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = copy(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &origin)
        AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions)
        return CGRect(origin: origin, size: dimensions)
    }

    static func snapshot(of window: AXUIElement, pid: pid_t) -> AXWindowSnapshot? {
        guard let frame = frame(of: window), frame.width > 0, frame.height > 0 else { return nil }
        return AXWindowSnapshot(ref: AXElementRef(window), pid: pid, title: copy(window, kAXTitleAttribute) as? String ?? "", frame: frame)
    }

    // MARK: Minimize / restore

    /// The window ⌘M would minimize: focused, else main, else first standard.
    static func focusedMinimizableWindow(pid: pid_t) -> AXWindowSnapshot? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        let candidate = element(app, kAXFocusedWindowAttribute)
            ?? element(app, kAXMainWindowAttribute)
            ?? tileableWindows(pid: pid).first
        guard let window = candidate, isStandard(window), canMinimize(window),
              (copy(window, kAXMinimizedAttribute) as? Bool) != true else { return nil }
        return snapshot(of: window, pid: pid)
    }

    static func canMinimize(_ window: AXUIElement) -> Bool {
        guard let button = element(window, kAXMinimizeButtonAttribute) else { return false }
        return (copy(button, kAXEnabledAttribute) as? Bool) ?? true
    }

    static func minimize(_ window: AXUIElement) {
        setBool(window, kAXMinimizedAttribute, true)
    }

    static func restore(_ window: AXUIElement, pid: pid_t) {
        setBool(window, kAXMinimizedAttribute, false)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        setBool(AXUIElementCreateApplication(pid), kAXFrontmostAttribute, true)
    }

    static func minimizedWindows(pid: pid_t) -> [AXWindowSnapshot] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        guard let windows = copy(app, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        return windows
            .filter { isStandard($0) && (copy($0, kAXMinimizedAttribute) as? Bool) == true }
            .compactMap { snapshot(of: $0, pid: pid) }
    }

    /// Resolves a press at `point` (AX coordinates) to an enabled minimize
    /// ("yellow") button, so the group animation can start with the click.
    static func minimizeButtonHit(at point: CGPoint) -> MinimizeButtonHit? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.5)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success,
              let button = hit,
              (copy(button, kAXSubroleAttribute) as? String) == (kAXMinimizeButtonSubrole as String),
              (copy(button, kAXEnabledAttribute) as? Bool) ?? true,
              let window = element(button, kAXWindowAttribute),
              let buttonFrame = frame(of: button) else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        guard let snapshot = snapshot(of: window, pid: pid) else { return nil }
        return MinimizeButtonHit(window: snapshot, buttonFrame: buttonFrame)
    }

    static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    static func setBool(_ element: AXUIElement, _ attribute: String, _ value: Bool) {
        AXUIElementSetAttributeValue(element, attribute as CFString, (value ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef)
    }
}
