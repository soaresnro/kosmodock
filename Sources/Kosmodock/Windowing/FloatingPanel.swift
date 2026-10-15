import AppKit
import SwiftUI

/// Borderless, transparent, non-activating panel used for the dock bar and
/// the Bento popovers. Clicking it never steals focus from the frontmost app.
final class FloatingPanel: NSPanel {
    private let allowsKey: Bool

    init(level: NSWindow.Level, allowsKey: Bool) {
        self.allowsKey = allowsKey
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // `isFloatingPanel` resets the level to `.floating`, so set it first.
        isFloatingPanel = true
        self.level = level
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        becomesKeyOnlyIfNeeded = true
        worksWhenModal = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    /// Borderless panels may live partly off-screen (Intellihide slides the
    /// dock below the bottom edge); never let AppKit pull them back.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Hosting view that reacts to the first click even though the window isn't
/// key and the app isn't active.
final class InteractiveHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
        // The panel's frame is driven by measured content; don't let the
        // hosting view impose Auto Layout size constraints on the window.
        sizingOptions = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
