import AppKit
import ApplicationServices
import Observation
import OSLog
import ScreenCaptureKit
import SwiftUI

extension Logger {
    static let previews = Logger(subsystem: "dev.kosmodock.Kosmodock", category: "previews")
}

// MARK: - Rules

/// When window previews show, how big they are, and what they may capture.
/// Pure, so it's tested without windows.
enum WindowPreviewRules {
    static let delayRange: ClosedRange<Double> = 0...2
    /// While cards are up, resting on another icon swaps them almost at once.
    static let switchDelay: Double = 0.05
    /// The pointer away from both the icon and the cards this long closes them.
    static let closeGrace: Double = 0.3
    /// Thumbnails are reused this long, so hovering back and forth captures once.
    static let thumbnailLifetime: TimeInterval = 3
    /// The window list from ScreenCaptureKit is reused this long.
    static let windowListLifetime: TimeInterval = 1.5
    static let maximumCards = 12

    /// Seconds to wait before showing cards: the configured delay, clamped,
    /// or the short switch delay when cards are already up.
    static func delay(configured: Double, cardsAreShowing: Bool) -> Double {
        if cardsAreShowing { return switchDelay }
        guard configured.isFinite else { return BehaviorConfig().windowPreviewDelay }
        return min(max(configured, delayRange.lowerBound), delayRange.upperBound)
    }

    static func showsCards(enabled: Bool, windowCount: Int, needsTwoWindows: Bool) -> Bool {
        enabled && windowCount >= (needsTwoWindows ? 2 : 1)
    }

    /// Kosmodock's own windows are never previewed or captured.
    static func isPreviewable(pid: pid_t, bundleID: String?, ownPID: pid_t, ownBundleID: String?) -> Bool {
        guard pid != ownPID else { return false }
        guard let bundleID, let ownBundleID else { return true }
        return bundleID != ownBundleID
    }

    /// Pixel size of a thumbnail for a window of `size` points: it fits `box`
    /// (points) at `scale`, keeps the aspect ratio and never upscales.
    static func captureSize(for size: CGSize, fitting box: CGSize, scale: CGFloat) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        let fit = min(1, box.width / size.width, box.height / size.height)
        return CGSize(
            width: max(1, (size.width * fit * scale).rounded()),
            height: max(1, (size.height * fit * scale).rounded())
        )
    }
}

/// Fixed sizes of the cards, so the panel's size is known before it shows.
enum WindowPreviewMetrics {
    static let thumbnail = CGSize(width: 200, height: 120)
    static let cardPadding: CGFloat = 7
    static let titleHeight: CGFloat = 16
    static let titleSpacing: CGFloat = 6
    static let spacing: CGFloat = 8
    static let padding: CGFloat = 10
    static let headerHeight: CGFloat = 16
    /// Transparent margin under the cards. Smaller than the other sides'
    /// (`DockMetrics.shadowInset`): the panel starts above the hovered icon,
    /// so it never lies over the icon it belongs to.
    static let bottomInset: CGFloat = 16
    /// Between the hovered icon's top and the panel's bottom edge.
    static let gap: CGFloat = 2

    static var cardSize: CGSize {
        CGSize(
            width: thumbnail.width + cardPadding * 2,
            height: cardPadding + thumbnail.height + titleSpacing + titleHeight + cardPadding
        )
    }

    /// As many cards per row as `availableWidth` (points) holds, at least one.
    static func columns(count: Int, availableWidth: CGFloat) -> Int {
        let fitting = Int(((availableWidth - padding * 2 + spacing) / (cardSize.width + spacing)).rounded(.down))
        return max(1, min(count, fitting))
    }

    /// The cards' panel in Cocoa screen coordinates: centered over `anchor`
    /// (the hovered icon) and above it, within `visible` (the screen's
    /// visible frame), with transparent margins for the shadow.
    static func panelFrame(content: CGSize, above anchor: CGRect, within visible: CGRect) -> CGRect {
        let inset = DockMetrics.shadowInset
        let size = CGSize(width: content.width + inset * 2, height: content.height + inset + bottomInset)
        let minX = visible.minX + 6 - inset
        let maxX = visible.maxX - 6 + inset - size.width
        let x = min(max(anchor.midX - size.width / 2, minX), max(minX, maxX))
        var y = anchor.maxY + gap
        if y + size.height - inset > visible.maxY { y = visible.maxY - size.height + inset }
        return CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    /// The cards' panel content: a header line, then rows of cards.
    static func contentSize(count: Int, columns: Int) -> CGSize {
        let columns = max(1, columns)
        let rows = max(1, Int((Double(count) / Double(columns)).rounded(.up)))
        let card = cardSize
        return CGSize(
            width: CGFloat(columns) * card.width + CGFloat(columns - 1) * spacing + padding * 2,
            height: headerHeight + spacing + CGFloat(rows) * card.height + CGFloat(rows - 1) * spacing + padding * 2
        )
    }
}

/// Pairs the AX layer's windows with ScreenCaptureKit's: same process and
/// nearly the same frame (both in the top-left, primary-display space). The
/// title only breaks ties between windows with the same frame.
enum WindowMatching {
    struct Window: Equatable {
        var pid: pid_t
        var frame: CGRect
        var title: String = ""
    }

    /// Largest difference of an edge, in points, still taken for the same window.
    static let tolerance: CGFloat = 6

    /// For each of `ax`, the index of its window in `sc`, or nil. Each `sc`
    /// window is used once; the closest pairs win.
    static func match(ax: [Window], sc: [Window]) -> [Int?] {
        struct Pair {
            var ax: Int
            var sc: Int
            var distance: CGFloat
            var sameTitle: Bool
        }
        var pairs: [Pair] = []
        for (i, a) in ax.enumerated() {
            for (j, s) in sc.enumerated() where s.pid == a.pid {
                let distance = Self.distance(a.frame, s.frame)
                guard distance <= tolerance else { continue }
                pairs.append(Pair(ax: i, sc: j, distance: distance.rounded(), sameTitle: a.title == s.title))
            }
        }
        pairs.sort { lhs, rhs in
            if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
            if lhs.sameTitle != rhs.sameTitle { return lhs.sameTitle }
            return (lhs.ax, lhs.sc) < (rhs.ax, rhs.sc)
        }
        var result = [Int?](repeating: nil, count: ax.count)
        var used = Set<Int>()
        for pair in pairs where result[pair.ax] == nil && !used.contains(pair.sc) {
            result[pair.ax] = pair.sc
            used.insert(pair.sc)
        }
        return result
    }

    /// The largest difference between the two rects' origins and sizes.
    static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.width - b.width), abs(a.height - b.height))
    }
}

/// Values that expire `lifetime` seconds after they're stored.
struct ExpiringCache<Key: Hashable, Value> {
    var lifetime: TimeInterval
    private var entries: [Key: (value: Value, stored: Date)] = [:]

    init(lifetime: TimeInterval) {
        self.lifetime = lifetime
    }

    func value(for key: Key, now: Date = Date()) -> Value? {
        guard let entry = entries[key], now.timeIntervalSince(entry.stored) < lifetime else { return nil }
        return entry.value
    }

    mutating func insert(_ value: Value, for key: Key, now: Date = Date()) {
        entries = entries.filter { now.timeIntervalSince($0.value.stored) < lifetime }
        entries[key] = (value, now)
    }
}

// MARK: - Windows

/// A window on a card. It comes from the AX layer, so clicking can raise it.
struct WindowPreviewCard: Identifiable, Sendable {
    let window: AXWindowSnapshot
    let isMinimized: Bool

    /// Stable while the window lives, like `MinimizedWindow.id`.
    var id: String { "\(window.pid):\(window.ref.hashValue)" }
}

extension AXWindowOps {
    /// Standard windows of `pids` for the preview cards, front to back as the
    /// AX list has them, minimized ones last. Call only off the main thread.
    static func previewWindows(pids: [pid_t]) -> [WindowPreviewCard] {
        var shown: [WindowPreviewCard] = []
        var minimized: [WindowPreviewCard] = []
        for pid in pids {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 1.0)
            guard let windows = copy(app, kAXWindowsAttribute) as? [AXUIElement] else { continue }
            for window in windows where isStandard(window) {
                let isMinimized = (copy(window, kAXMinimizedAttribute) as? Bool) == true
                let snapshot = AXWindowSnapshot(
                    ref: AXElementRef(window), pid: pid,
                    title: copy(window, kAXTitleAttribute) as? String ?? "",
                    frame: frame(of: window) ?? .zero
                )
                if isMinimized {
                    minimized.append(WindowPreviewCard(window: snapshot, isMinimized: true))
                } else {
                    shown.append(WindowPreviewCard(window: snapshot, isMinimized: false))
                }
            }
        }
        return shown + minimized
    }
}

extension WindowManagerService {
    /// Brings a window to the front: restores it when minimized, raises it
    /// and activates its app, as restoring a minimized window does.
    func raise(_ window: AXWindowSnapshot) async {
        let pid = window.pid
        let ref = window.ref
        NSRunningApplication(processIdentifier: pid)?.unhide()
        await performAX { AXWindowOps.restore(ref.element, pid: pid) }
        NSRunningApplication(processIdentifier: pid)?.activate(options: [])
    }
}

// MARK: - Screen Recording

/// Thumbnails need Screen Recording. Checking never prompts; only `request()`
/// (the button in Settings › Permissions) does.
enum ScreenRecordingAccess {
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt the first time; later calls only report.
    @discardableResult
    static func request() -> Bool { CGRequestScreenCaptureAccess() }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Controller

/// What the cards panel shows.
@MainActor
@Observable
final class WindowPreviewState {
    var app: DockApp?
    var cards: [WindowPreviewCard] = []
    var columns = 1
    var thumbnails: [String: NSImage] = [:]
    var isPresented = false
    @ObservationIgnored var onSelect: ((WindowPreviewCard) -> Void)?
    @ObservationIgnored var onHover: ((Bool) -> Void)?
}

/// Window previews: resting the pointer on a running app's icon shows cards
/// for its windows above it, in a non-activating panel; clicking one raises
/// that window. Thumbnails are captured only while hovering, and only with
/// Screen Recording; without it the cards show the app icon and the title.
@MainActor
final class WindowPreviewController {
    private struct Hover {
        var app: DockApp
        /// The icon's frame in its window's content (top-left origin).
        var rect: CGRect
        weak var window: NSWindow?
    }

    private let model: AppModel
    private let panel: FloatingPanel
    private let state = WindowPreviewState()
    private var hover: Hover?
    private var shownAppID: String?
    private var isOverCards = false
    /// Tells a hover's async work apart from a later hover's.
    private var generation = 0
    private var thumbnails = ExpiringCache<String, NSImage>(lifetime: WindowPreviewRules.thumbnailLifetime)
    private var windowList: (windows: [SCWindow], date: Date)?
    private var pendingTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var monitors: [Any] = []
    private var clickMonitor: Any?
    private var tokens: [NSObjectProtocol] = []

    /// Cards are up (the dock stays shown meanwhile).
    var isShowing: Bool { shownAppID != nil }
    var onShowingChange: (() -> Void)?

    init(model: AppModel, level: NSWindow.Level) {
        self.model = model
        panel = FloatingPanel(level: level, allowsKey: false)
        panel.contentView = InteractiveHostingView(rootView: WindowPreviewHost(model: model, state: state))
        state.onSelect = { [weak self] card in self?.select(card) }
        state.onHover = { [weak self] hovering in self?.cardsHover(hovering) }
        model.windowPreviewHover = { [weak self] app, rect, hovering in
            if hovering { self?.pointerEntered(app, rect: rect) } else { self?.pointerExited(app) }
        }
        // A click anywhere but the cards (the icon itself too) cancels them.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window !== self.panel else { return }
                self.hide()
            }
            return event
        }
        tokens.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        })
    }

    func setAppearance(_ appearance: NSAppearance?) {
        panel.appearance = appearance
    }

    // MARK: Hover

    private func pointerEntered(_ app: DockApp, rect: CGRect) {
        closeTask?.cancel()
        let behavior = model.config.behavior
        guard behavior.showsWindowPreviews, model.windows.isTrusted, model.workspace.isRunning(app) else { return }
        let point = NSEvent.mouseLocation
        let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        hover = Hover(app: app, rect: rect, window: NSApp.windows.first { $0.windowNumber == number && $0 !== panel })
        guard shownAppID != app.id else { return }
        pendingTask?.cancel()
        generation += 1
        let current = generation
        let delay = WindowPreviewRules.delay(configured: behavior.windowPreviewDelay, cardsAreShowing: isShowing)
        pendingTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.load(app, generation: current)
        }
    }

    private func pointerExited(_ app: DockApp) {
        guard hover?.app.id == app.id else { return }
        hover = nil
        pendingTask?.cancel()
        scheduleClose()
    }

    private func cardsHover(_ hovering: Bool) {
        isOverCards = hovering
        if hovering {
            closeTask?.cancel()
        } else {
            scheduleClose()
        }
    }

    private func scheduleClose() {
        closeTask?.cancel()
        guard isShowing else { return }
        closeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(WindowPreviewRules.closeGrace))
            guard let self, !Task.isCancelled, !self.isOverCards, self.hover == nil else { return }
            self.hide()
        }
    }

    // MARK: Showing

    private func load(_ app: DockApp, generation current: Int) async {
        let me = getpid()
        let pids = (model.workspace.state(for: app)?.pids ?? []).filter { $0 != me }
        guard let first = pids.first, WindowPreviewRules.isPreviewable(
            pid: first, bundleID: model.workspace.bundleID(for: app), ownPID: me, ownBundleID: Bundle.main.bundleIdentifier
        ) else { return }
        let cards = await model.windows.performAX { AXWindowOps.previewWindows(pids: pids) }
        guard current == generation, hover?.app.id == app.id else { return }
        let behavior = model.config.behavior
        guard WindowPreviewRules.showsCards(enabled: behavior.showsWindowPreviews, windowCount: cards.count, needsTwoWindows: behavior.windowPreviewsNeedTwoWindows) else {
            hide()
            return
        }
        present(app, cards: Array(cards.prefix(WindowPreviewRules.maximumCards)), generation: current)
    }

    private func present(_ app: DockApp, cards: [WindowPreviewCard], generation current: Int) {
        hideTask?.cancel()
        let anchor = anchorRect()
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) } ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? anchor.insetBy(dx: -600, dy: -400)
        let columns = WindowPreviewMetrics.columns(count: cards.count, availableWidth: visible.width - 24)
        let now = Date()
        state.app = app
        state.cards = cards
        state.columns = columns
        state.thumbnails = Dictionary(uniqueKeysWithValues: cards.compactMap { card in
            thumbnails.value(for: card.id, now: now).map { (card.id, $0) }
        })
        place(contentSize: WindowPreviewMetrics.contentSize(count: cards.count, columns: columns), above: anchor, within: visible)
        panel.orderFrontRegardless()
        let wasShowing = isShowing
        shownAppID = app.id
        if !wasShowing {
            Task { @MainActor [weak self] in self?.state.isPresented = true }
            installMonitors()
            onShowingChange?()
        }
        captureThumbnails(for: cards, generation: current)
    }

    /// The hovered icon in screen coordinates; the pointer when it's unknown.
    private func anchorRect() -> CGRect {
        guard let hover, let window = hover.window else {
            let point = NSEvent.mouseLocation
            return CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)
        }
        let rect = hover.rect
        return CGRect(x: window.frame.minX + rect.minX, y: window.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    private func place(contentSize: CGSize, above anchor: CGRect, within visible: CGRect) {
        panel.setFrame(WindowPreviewMetrics.panelFrame(content: contentSize, above: anchor, within: visible), display: true)
    }

    /// Hides the cards (and cancels cards about to show).
    func hide() {
        pendingTask?.cancel()
        closeTask?.cancel()
        captureTask?.cancel()
        guard isShowing else { return }
        shownAppID = nil
        isOverCards = false
        state.isPresented = false
        removeMonitors()
        onShowingChange?()
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard let self, !Task.isCancelled else { return }
            self.panel.orderOut(nil)
            self.state.cards = []
            self.state.thumbnails = [:]
        }
    }

    private func select(_ card: WindowPreviewCard) {
        hide()
        if card.isMinimized, let tracked = model.minimizedWindows.windows.first(where: { $0.ref == card.window.ref }) {
            // Kosmodock knows it: restore with the animation out of its group.
            model.restore(tracked)
            return
        }
        model.dismissPopover?()
        let window = card.window
        Task { await model.windows.raise(window) }
    }

    // MARK: Thumbnails

    private func captureThumbnails(for cards: [WindowPreviewCard], generation current: Int) {
        captureTask?.cancel()
        let now = Date()
        let wanted = cards.filter { !$0.isMinimized && thumbnails.value(for: $0.id, now: now) == nil }
        guard !wanted.isEmpty, ScreenRecordingAccess.isGranted else { return }
        let scale = panel.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        captureTask = Task { [weak self] in
            guard let self, let windows = await self.shareableWindows(), !Task.isCancelled else { return }
            let matches = WindowMatching.match(
                ax: wanted.map { WindowMatching.Window(pid: $0.window.pid, frame: $0.window.frame, title: $0.window.title) },
                sc: windows.map { WindowMatching.Window(pid: $0.owningApplication?.processID ?? -1, frame: $0.frame, title: $0.title ?? "") }
            )
            for (card, match) in zip(wanted, matches) {
                guard let match else { continue }
                guard !Task.isCancelled, current == self.generation else { return }
                guard let image = await Self.capture(windows[match], scale: scale) else { continue }
                let thumbnail = NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
                self.thumbnails.insert(thumbnail, for: card.id)
                guard current == self.generation, self.isShowing else { return }
                self.state.thumbnails[card.id] = thumbnail
            }
        }
    }

    /// Other apps' normal windows, from ScreenCaptureKit; never Kosmodock's.
    private func shareableWindows() async -> [SCWindow]? {
        if let windowList, Date().timeIntervalSince(windowList.date) < WindowPreviewRules.windowListLifetime {
            return windowList.windows
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            let me = getpid()
            let ownBundleID = Bundle.main.bundleIdentifier
            let windows = content.windows.filter { window in
                guard let owner = window.owningApplication, window.windowLayer == 0,
                      window.frame.width > 1, window.frame.height > 1 else { return false }
                return WindowPreviewRules.isPreviewable(pid: owner.processID, bundleID: owner.bundleIdentifier, ownPID: me, ownBundleID: ownBundleID)
            }
            windowList = (windows, Date())
            return windows
        } catch {
            Logger.previews.error("Window list unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func capture(_ window: SCWindow, scale: CGFloat) async -> CGImage? {
        let size = WindowPreviewRules.captureSize(for: window.frame.size, fitting: WindowPreviewMetrics.thumbnail, scale: scale)
        guard size.width >= 1, size.height >= 1 else { return nil }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(size.width)
        configuration.height = Int(size.height)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        do {
            return try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration)
        } catch {
            Logger.previews.info("Capture failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: Monitors

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { self?.hide() }
            return event
        }) {
            monitors.append(monitor)
        }
        // Escape while another app is focused (delivered only with AX trust).
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return }
            MainActor.assumeIsolated { self?.hide() }
        }) {
            monitors.append(monitor)
        }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }
}
