import AppKit
import SwiftUI

// The Drop Zone: while files are dragged in any app, a glass tray appears
// (bottom left, or near the pointer) to drop them on the shelf, and goes away
// when the mouse button is released.
//
// A drag is noticed with a global mouse monitor, which needs no permission:
// the drag pasteboard's change count moves when another app starts a drag,
// and its types say whether files are on it. Their contents are read only
// when they're dropped on the tray. Drags that start in Kosmodock itself
// never reach a global monitor, so dragging off the shelf shows no tray.

@MainActor
@Observable
final class DropZoneState {
    var isTargeted = false
    /// Files the last drop parked; the tray shows a check while it's above zero.
    var dropped = 0
}

@MainActor
final class DropZoneController {
    private let model: AppModel
    private let state = DropZoneState()
    private var panel: FloatingPanel?
    private var monitor: Any?
    /// The drag pasteboard's change count when the mouse went down.
    private var changeCountAtPress: Int?
    private var lastCheck = Date.distantPast
    private var isShown = false
    private var releaseWatch: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?

    static let traySize = CGSize(width: 230, height: 124)

    init(model: AppModel) {
        self.model = model
        model.configService.addObserver { [weak self] old, new in
            guard old.behavior.dropZone != new.behavior.dropZone else { return }
            self?.setEnabled(new.behavior.dropZone)
        }
        setEnabled(model.config.behavior.dropZone)
    }

    private func setEnabled(_ enabled: Bool) {
        if enabled, monitor == nil {
            monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
            }
        } else if !enabled, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
            hide(after: .zero)
        }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            changeCountAtPress = NSPasteboard(name: .drag).changeCount
        case .leftMouseDragged:
            guard !isShown, let pressed = changeCountAtPress else { return }
            // A few checks a second are plenty while the mouse moves.
            let now = Date()
            guard now.timeIntervalSince(lastCheck) > 0.08 else { return }
            lastCheck = now
            let pasteboard = NSPasteboard(name: .drag)
            guard pasteboard.changeCount != pressed else { return }
            // One look per drag, at the types only.
            changeCountAtPress = nil
            guard pasteboard.types?.contains(.fileURL) == true else { return }
            show(pointer: NSEvent.mouseLocation)
        case .leftMouseUp:
            changeCountAtPress = nil
            if isShown { hide(after: releaseDelay) }
        default:
            break
        }
    }

    // MARK: Tray

    private func show(pointer: NSPoint) {
        hideTask?.cancel()
        state.isTargeted = false
        state.dropped = 0
        let panel = self.panel ?? makePanel()
        panel.setFrame(trayFrame(pointer: pointer), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            panel.animator().alphaValue = 1
        }
        isShown = true
        watchRelease()
    }

    /// The mouse-up of a drag that ends in another app may not reach the
    /// monitor, so the button is also polled while the tray is up.
    private func watchRelease() {
        releaseWatch?.cancel()
        releaseWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, self.isShown else { return }
                if NSEvent.pressedMouseButtons & 1 == 0 {
                    self.hide(after: self.releaseDelay)
                    return
                }
            }
        }
    }

    /// Long enough to see the check after a drop; the files may still be
    /// loading when the button comes up.
    private var releaseDelay: Duration {
        state.dropped > 0 || state.isTargeted ? .milliseconds(800) : .milliseconds(120)
    }

    private func hide(after delay: Duration) {
        guard isShown else { return }
        isShown = false
        releaseWatch?.cancel()
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, let panel = self.panel else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                panel.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated {
                    if !self.isShown { panel.orderOut(nil) }
                }
            }
        }
    }

    private func makePanel() -> FloatingPanel {
        // Above the dock and its popovers.
        let panel = FloatingPanel(level: NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2), allowsKey: false)
        panel.contentView = InteractiveHostingView(rootView: DropZoneHost(model: model, state: state))
        self.panel = panel
        return panel
    }

    private func trayFrame(pointer: NSPoint) -> NSRect {
        let screens = NSScreen.screens
        let screen = screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main ?? screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let inset = DockMetrics.shadowInset
        let size = CGSize(width: Self.traySize.width + inset * 2, height: Self.traySize.height + inset * 2)
        let margin: CGFloat = 16
        var tray: NSRect
        switch model.config.behavior.dropZonePlacement {
        case .bottomLeft:
            tray = NSRect(x: visible.minX + margin, y: visible.minY + margin, width: Self.traySize.width, height: Self.traySize.height)
            // Clear of the dock when it reaches that far.
            if let dock = model.safeWorkAreaProvider?()?.dockFrame, screen == screens.first, tray.intersects(dock) {
                tray.origin.y = dock.maxY + margin
            }
        case .nearPointer:
            // Beside the pointer, not under it, so letting go at once drops nothing.
            tray = NSRect(x: pointer.x + 40, y: pointer.y + 24, width: Self.traySize.width, height: Self.traySize.height)
            if tray.maxX > visible.maxX - margin { tray.origin.x = pointer.x - 40 - tray.width }
            if tray.maxY > visible.maxY - margin { tray.origin.y = pointer.y - 24 - tray.height }
        }
        tray.origin.x = min(max(tray.minX, visible.minX + margin), visible.maxX - margin - tray.width)
        tray.origin.y = min(max(tray.minY, visible.minY + margin), visible.maxY - margin - tray.height)
        return NSRect(origin: CGPoint(x: (tray.minX - inset).rounded(), y: (tray.minY - inset).rounded()), size: size)
    }
}

private struct DropZoneHost: View {
    let model: AppModel
    let state: DropZoneState

    var body: some View {
        DropZoneTrayView(state: state)
            .padding(DockMetrics.shadowInset)
            .environment(model)
            .environment(\.locale, model.locale)
            .id(model.language)
    }
}

/// The tray itself: glass with a dashed edge that lights up under the files.
struct DropZoneTrayView: View {
    @Environment(AppModel.self) private var model
    let state: DropZoneState

    var body: some View {
        let accent = model.accent
        let isTargeted = state.isTargeted
        let done = state.dropped > 0
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        VStack(spacing: 7) {
            ZStack {
                Circle()
                    .fill(accent.opacity(isTargeted ? 0.32 : 0.16))
                    .frame(width: 46, height: 46)
                Image(systemName: done ? "checkmark" : "tray.and.arrow.down.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(accent)
                    .contentTransition(.symbolEffect(.replace))
            }
            Text(done ? (state.dropped == 1 ? L10n.tr("1 file on the Shelf") : L10n.tr("%lld files on the Shelf", state.dropped)) : L10n.tr("Drop to keep on the Shelf"))
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text("Drag them out of the Shelf when you need them.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .frame(width: DropZoneController.traySize.width, height: DropZoneController.traySize.height)
        .background(SurfaceBackground(surface: model.theme.popoverSurface, cornerRadius: 22))
        .overlay {
            shape.strokeBorder(accent.opacity(isTargeted ? 0.95 : 0.4), style: StrokeStyle(lineWidth: isTargeted ? 2 : 1.5, dash: [7, 5]))
                .padding(5)
        }
        .contentShape(shape)
        .scaleEffect(isTargeted ? 1.04 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isTargeted)
        .animation(.easeOut(duration: 0.2), value: done)
        .onDrop(of: [.fileURL], isTargeted: Binding(get: { state.isTargeted }, set: { state.isTargeted = $0 })) { providers in
            FileDrop.loadURLs(from: providers) { urls in
                guard !urls.isEmpty else { return }
                model.addToShelf(urls)
                state.dropped = urls.count
            }
            return true
        }
    }
}
