import AppKit
import Observation
import SwiftUI

enum DockMetrics {
    /// Transparent margin around the glass so SwiftUI shadows and hover
    /// scaling are never clipped by the panel bounds.
    static let shadowInset: CGFloat = 28
    static let popoverGap: CGFloat = 10
    static let popoverWidth: CGFloat = 480
}

/// Geometry reported by the dock's SwiftUI tree (in the hosting view's
/// top-left coordinate space), plus conversion to screen coordinates.
/// Deliberately not observable: it feeds window placement, not rendering.
@MainActor
final class GroupGeometryTracker {
    var capsuleFrames: [String: CGRect] = [:]
    private(set) var barSize: CGSize = .zero
    /// Bar height while no group is expanded inline: the height windows are
    /// kept clear of, so expanding the accordion doesn't move them.
    var restingBarHeight: CGFloat = 0
    var onBarSizeChange: ((CGSize) -> Void)?

    func reportBar(size: CGSize) {
        guard size != barSize, size.width > 0, size.height > 0 else { return }
        barSize = size
        onBarSizeChange?(size)
    }

    /// A capsule's rect in Cocoa screen coordinates. `shownOriginY` lets the
    /// rect be resolved while Intellihide has the panel slid off-screen.
    func screenRect(forGroup groupID: String, panelFrame: CGRect, shownOriginY: CGFloat) -> CGRect? {
        guard let rect = capsuleFrames[groupID] else { return nil }
        return CGRect(
            x: panelFrame.minX + rect.minX,
            y: shownOriginY + panelFrame.height - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}

@MainActor
@Observable
final class PopoverState {
    var groupID: String?
    var isPresented = false
    /// Horizontal anchor (0…1) of the capsule inside the popover, so the
    /// open/close scale animation grows out of the capsule.
    var anchorX: CGFloat = 0.5
    @ObservationIgnored var onSizeChange: ((CGSize) -> Void)?

    func reportSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        onSizeChange?(size)
    }
}

/// Owns the dock and popover panels: sizing them to their SwiftUI content,
/// anchoring them to the screen, reserving screen space / Intellihide, the
/// minimize-into-group animation, and outside-click dismissal.
@MainActor
final class DockController {
    private let model: AppModel
    private let geometry = GroupGeometryTracker()
    private let popoverState = PopoverState()
    private let dockPanel: FloatingPanel
    private let popoverPanel: FloatingPanel
    private var popoverHost: NSView?
    private let animator = WindowMinimizeAnimator()
    private let intellihide = IntellihideController()

    private var hasPlacedDock = false
    private var lastWorkArea: SafeWorkArea?
    private var isMenuTracking = false
    private var dockShrinkTask: Task<Void, Never>?
    private var popoverShrinkTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var monitors: [Any] = []
    private var tokens: [NSObjectProtocol] = []

    private var inset: CGFloat { DockMetrics.shadowInset }

    init(model: AppModel) {
        self.model = model
        dockPanel = FloatingPanel(level: .statusBar, allowsKey: false)
        popoverPanel = FloatingPanel(level: NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1), allowsKey: true)

        dockPanel.contentView = InteractiveHostingView(rootView: DockHost(model: model, geometry: geometry))
        let popoverHost = InteractiveHostingView(rootView: PopoverHost(model: model, state: popoverState))
        popoverPanel.contentView = popoverHost
        self.popoverHost = popoverHost

        geometry.onBarSizeChange = { [weak self] size in self?.barSizeDidChange(size) }
        popoverState.onSizeChange = { [weak self] size in self?.popoverContentSizeDidChange(size) }

        model.presentPopover = { [weak self] id in self?.togglePopover(id) }
        model.dismissPopover = { [weak self] in self?.closePopover() }
        model.safeWorkAreaProvider = { [weak self] in self?.safeWorkArea() }
        model.minimizedWindows.animationHandler = { [weak self] request in self?.playMinimizeAnimation(request) }
        model.configService.addObserver { [weak self] old, new in self?.configDidChange(from: old, to: new) }
        model.axHub.addListener { [weak self] event in self?.intellihide.handle(event) }

        configureIntellihide()

        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenParametersDidChange() }
        })
        tokens.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePopover() }
        })
        // Keep the dock up while one of our context menus is open.
        tokens.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isMenuTracking = true
                self?.intellihide.evaluate()
            }
        })
        tokens.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isMenuTracking = false
                self?.intellihide.evaluate()
            }
        })
        applyAppearance()
    }

    func show() {
        updateMaxWidth()
        dockPanel.contentView?.layoutSubtreeIfNeeded()
        if !hasPlacedDock { placeDock(size: dockPanel.frame.size) }
        dockPanel.orderFrontRegardless()
        intellihide.setEnabled(!model.config.behavior.reserveScreenSpace)
    }

    // MARK: Geometry

    /// The display hosting the dock: the primary (menu bar) screen.
    private var dockScreen: NSScreen {
        NSScreen.screens.first ?? NSScreen.main ?? NSScreen()
    }

    private var shrinkDelay: Duration {
        .milliseconds(Int(max(0.3, model.theme.springResponse * 1.8) * 1000))
    }

    /// Bar height used for reserving space: the resting (collapsed) height,
    /// so expanding a group inline never moves the reserved line.
    private var stableBarHeight: CGFloat {
        geometry.restingBarHeight > 0 ? geometry.restingBarHeight : max(geometry.barSize.height, CGFloat(model.theme.iconSize) * 0.62 + 30)
    }

    private func shownOrigin(for size: CGSize) -> CGPoint {
        let screen = dockScreen
        return CGPoint(
            x: (screen.frame.midX - size.width / 2).rounded(),
            y: (screen.visibleFrame.minY + CGFloat(model.theme.dockMargin) - inset).rounded()
        )
    }

    private func hiddenOrigin(for size: CGSize) -> CGPoint {
        CGPoint(x: shownOrigin(for: size).x, y: dockScreen.frame.minY - size.height - 4)
    }

    /// Grows the panel immediately (so expanding content is never clipped) but
    /// shrinks it only after the spring settles (so collapsing content can
    /// animate inside the old bounds).
    private func barSizeDidChange(_ barSize: CGSize) {
        if model.expandedGroupID == nil { geometry.restingBarHeight = barSize.height }
        let target = panelSize(forBar: barSize)
        dockShrinkTask?.cancel()
        guard hasPlacedDock else {
            placeDock(size: target)
            return
        }
        let current = dockPanel.frame.size
        let grown = CGSize(width: max(current.width, target.width), height: max(current.height, target.height))
        if grown != current { placeDock(size: grown) }
        if grown != target {
            let delay = shrinkDelay
            dockShrinkTask = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                // The latest measurement, not `target`: the panel must end up
                // matching the bar it shows, or the bar's ends are cut off.
                self.placeDock(size: self.panelSize(forBar: self.geometry.barSize))
            }
        }
    }

    private func panelSize(forBar barSize: CGSize) -> CGSize {
        CGSize(width: ceil(barSize.width + inset * 2), height: ceil(barSize.height + inset * 2))
    }

    private func placeDock(size: CGSize) {
        let origin = intellihide.isHidden ? hiddenOrigin(for: size) : shownOrigin(for: size)
        dockPanel.setFrame(NSRect(origin: origin, size: size), display: true)
        hasPlacedDock = true
        if popoverState.isPresented { positionPopover() }
        publishWorkAreaIfChanged()
    }

    /// Visible frame of the dock's screen minus the band the dock reserves.
    func safeWorkArea() -> SafeWorkArea {
        let screen = dockScreen
        let visible = screen.visibleFrame
        let size = dockPanel.frame.size
        let shown = shownOrigin(for: size)
        let barSize = geometry.barSize
        let dockFrame = CGRect(
            x: shown.x + (size.width - barSize.width) / 2,
            y: shown.y + inset,
            width: barSize.width,
            height: barSize.height
        )
        let reserves = model.config.behavior.reserveScreenSpace
        var bottom = visible.minY
        if reserves {
            let reservedLine = shown.y + inset + stableBarHeight + max(0, CGFloat(model.theme.dockClearance))
            bottom = min(max(visible.minY, reservedLine), visible.maxY - 240)
        }
        return SafeWorkArea(
            screenFrame: screen.frame,
            workFrame: CGRect(x: visible.minX, y: bottom, width: visible.width, height: visible.maxY - bottom),
            dockFrame: dockFrame,
            reservesSpace: reserves,
            primaryScreenHeight: WindowManagerService.primaryScreenHeight
        )
    }

    /// Tells the enforcer to re-check every window when the reserved band moves.
    private func publishWorkAreaIfChanged() {
        // Wait for the first measurement so windows aren't fitted to a guess.
        guard geometry.restingBarHeight > 0 else { return }
        let area = safeWorkArea()
        guard area.workFrame != lastWorkArea?.workFrame || area.reservesSpace != lastWorkArea?.reservesSpace else { return }
        let previous = lastWorkArea
        lastWorkArea = area
        model.workAreaDidChange(from: previous, to: area)
    }

    private func screenParametersDidChange() {
        closePopover()
        updateMaxWidth()
        placeDock(size: dockPanel.frame.size)
    }

    /// Caps the bar at the screen width; the dock view steps down its
    /// density (and finally scrolls) to stay within it.
    private func updateMaxWidth() {
        let width = max(400, dockScreen.visibleFrame.width - 24)
        if model.dockMaxWidth != width { model.dockMaxWidth = width }
    }

    private func configDidChange(from old: DockConfig, to new: DockConfig) {
        if old.theme.appearance != new.theme.appearance { applyAppearance() }
        if old.theme.dockMargin != new.theme.dockMargin || old.theme.iconSize != new.theme.iconSize
            || old.theme.dockClearance != new.theme.dockClearance {
            placeDock(size: dockPanel.frame.size)
        }
        if old.behavior.reserveScreenSpace != new.behavior.reserveScreenSpace {
            intellihide.setEnabled(!new.behavior.reserveScreenSpace)
            publishWorkAreaIfChanged()
        }
    }

    private func applyAppearance() {
        let appearance = model.theme.appearance.nsAppearance
        dockPanel.appearance = appearance
        popoverPanel.appearance = appearance
    }

    // MARK: Intellihide

    private func configureIntellihide() {
        intellihide.dockFrameProvider = { [weak self] in self?.safeWorkArea().dockFrame }
        intellihide.screenProvider = { [weak self] in self?.dockScreen }
        intellihide.isPinned = { [weak self] in
            guard let self else { return false }
            return self.popoverState.isPresented || self.isMenuTracking || self.model.expandedGroupID != nil
        }
        intellihide.applyHidden = { [weak self] hidden in self?.setDockHidden(hidden) }
    }

    private func setDockHidden(_ hidden: Bool) {
        if hidden { closePopover() }
        let size = dockPanel.frame.size
        let target = NSRect(origin: hidden ? hiddenOrigin(for: size) : shownOrigin(for: size), size: size)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = hidden ? 0.26 : 0.22
            context.timingFunction = CAMediaTimingFunction(name: hidden ? .easeIn : .easeOut)
            dockPanel.animator().setFrame(target, display: true)
        }
    }

    // MARK: Minimize animation

    private func playMinimizeAnimation(_ request: MinimizeAnimationRequest) {
        guard let group = model.group(id: request.groupID) else { return }
        if intellihide.isHidden { intellihide.peek(for: 1.0) }
        let size = dockPanel.frame.size
        let shown = shownOrigin(for: size)
        guard let capsule = geometry.screenRect(
            forGroup: request.groupID,
            panelFrame: NSRect(origin: shown, size: size),
            shownOriginY: shown.y
        ) else { return }

        // AX → Cocoa is the same flip in both directions.
        let windowFrame = TilingEngine.accessibilityRect(fromCocoa: request.windowFrame, primaryScreenHeight: WindowManagerService.primaryScreenHeight)
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: request.bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
            ?? NSImage()
        let tint = NSColor(model.tint(for: group))
        let groupID = group.id
        let direction = request.direction

        animator.play(direction, windowFrame: windowFrame, capsuleFrame: capsule, icon: icon, title: request.title, tint: tint) { [weak self] in
            if direction == .intoGroup { self?.model.pulse(groupID) }
        }
    }

    // MARK: Popover

    private func togglePopover(_ groupID: String) {
        if popoverState.groupID == groupID, popoverState.isPresented {
            closePopover()
        } else {
            openPopover(groupID)
        }
    }

    private func openPopover(_ groupID: String) {
        hideTask?.cancel()
        model.windows.refreshTrust()
        let wasPresented = popoverState.isPresented
        popoverState.groupID = groupID
        model.popoverGroupID = groupID

        // Lay out synchronously so the measured size is known before the
        // panel is placed; the content stays transparent until presented.
        popoverHost?.layoutSubtreeIfNeeded()
        positionPopover()
        popoverPanel.orderFrontRegardless()
        if !wasPresented {
            Task { @MainActor [weak self] in self?.popoverState.isPresented = true }
        }
        installMonitors()
        model.refreshTelemetry(for: groupID)
    }

    func closePopover() {
        guard popoverState.groupID != nil else { return }
        popoverState.isPresented = false
        model.popoverGroupID = nil
        removeMonitors()
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(240))
            guard let self, !Task.isCancelled else { return }
            self.popoverPanel.orderOut(nil)
            self.popoverState.groupID = nil
            self.intellihide.evaluate()
        }
    }

    private func popoverContentSizeDidChange(_ contentSize: CGSize) {
        let target = CGSize(width: ceil(contentSize.width + inset * 2), height: ceil(contentSize.height + inset * 2))
        popoverShrinkTask?.cancel()
        let current = popoverPanel.frame.size
        let grown = CGSize(width: max(current.width, target.width), height: max(current.height, target.height))
        if !popoverPanel.isVisible || grown != current {
            positionPopover(size: popoverPanel.isVisible ? grown : target)
        }
        if popoverPanel.isVisible, grown != target {
            let delay = shrinkDelay
            popoverShrinkTask = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                self?.positionPopover(size: target)
            }
        }
    }

    private func positionPopover(size requested: CGSize? = nil) {
        guard let groupID = popoverState.groupID else { return }
        let size = requested ?? popoverPanel.frame.size
        let dockFrame = NSRect(origin: shownOrigin(for: dockPanel.frame.size), size: dockPanel.frame.size)
        let anchorX = geometry.capsuleFrames[groupID].map { dockFrame.minX + $0.midX } ?? dockFrame.midX
        let barTop = dockFrame.minY + inset + geometry.barSize.height
        let visible = dockScreen.visibleFrame

        let minX = visible.minX + 6 - inset
        let maxX = visible.maxX - 6 + inset - size.width
        let x = min(max(anchorX - size.width / 2, minX), max(minX, maxX))
        let y = barTop + DockMetrics.popoverGap - inset
        popoverPanel.setFrame(NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height), display: true)

        let contentWidth = max(1, size.width - inset * 2)
        popoverState.anchorX = min(1, max(0, (anchorX - x - inset) / contentWidth))
    }

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        // Clicks in other apps.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.closePopover() }
        }) {
            monitors.append(monitor)
        }
        // Clicks in our other windows (e.g. Settings). Dock clicks are handled
        // by the capsules themselves so switching groups works.
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                if event.window !== self.popoverPanel, event.window !== self.dockPanel { self.closePopover() }
            }
            return event
        }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { self?.closePopover() }
            return nil
        }) {
            monitors.append(monitor)
        }
        // Escape while another app is focused (delivered only with AX trust).
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return }
            MainActor.assumeIsolated { self?.closePopover() }
        }) {
            monitors.append(monitor)
        }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }
}

// MARK: - Hosting roots

struct DockHost: View {
    let model: AppModel
    let geometry: GroupGeometryTracker

    var body: some View {
        DockRootView(geometry: geometry)
            .environment(model)
            .environment(\.locale, model.locale)
            .id(model.language)
    }
}

struct PopoverHost: View {
    let model: AppModel
    let state: PopoverState

    var body: some View {
        PopoverRootView(state: state)
            .environment(model)
            .environment(\.locale, model.locale)
            .id(model.language)
    }
}
