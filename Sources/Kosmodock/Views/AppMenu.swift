import AppKit
import SwiftUI

// The right-click menu of an app icon. A SwiftUI `.contextMenu` is built when
// the view is, so it can't wait for the app's own Dock menu items: an AppKit
// view catches the right click, reads them (DockMenuService, ~100 ms) and
// pops up an NSMenu with them first and Kosmodock's actions after.

extension View {
    /// The app menu on right-click (or Control-click). `group` is nil for a
    /// pinned app.
    func appMenu(_ app: DockApp, group: DockGroup?) -> some View {
        modifier(AppMenuModifier(app: app, group: group))
    }
}

private struct AppMenuModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    let app: DockApp
    let group: DockGroup?

    func body(content: Content) -> some View {
        content.overlay {
            RightClickCatcher { view, point in
                AppMenuPresenter.show(app: app, group: group, model: model, in: view, at: point)
            }
        }
    }
}

/// Takes right clicks only; every other click falls through to SwiftUI.
private struct RightClickCatcher: NSViewRepresentable {
    var onRightClick: (NSView, NSPoint) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onRightClick = onRightClick
    }

    final class CatcherView: NSView {
        var onRightClick: ((NSView, NSPoint) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent, Self.isRightClick(event) else { return nil }
            return super.hitTest(point)
        }

        override func rightMouseDown(with event: NSEvent) {
            onRightClick?(self, convert(event.locationInWindow, from: nil))
        }

        override func mouseDown(with event: NSEvent) {
            if Self.isRightClick(event) {
                onRightClick?(self, convert(event.locationInWindow, from: nil))
            } else {
                super.mouseDown(with: event)
            }
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        static func isRightClick(_ event: NSEvent) -> Bool {
            event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        }
    }
}

@MainActor
enum AppMenuPresenter {
    static func show(app: DockApp, group: DockGroup?, model: AppModel, in view: NSView, at point: NSPoint) {
        Task { @MainActor in
            let url = model.workspace.url(for: app)
            var entries: [DockMenuEntry] = []
            if model.config.behavior.showsAppDockMenu, let url {
                entries = await model.dockMenus.entries(for: url)
            }
            let menu = NSMenu()
            menu.autoenablesItems = false
            if let url, !entries.isEmpty {
                for entry in entries {
                    if entry.isSeparator {
                        menu.addItem(.separator())
                    } else {
                        let item = ActionMenuItem(title: entry.title) { model.dockMenus.press(entry, appURL: url) }
                        item.isEnabled = entry.isEnabled
                        menu.addItem(item)
                    }
                }
                menu.addItem(.separator())
            }
            addKosmodockItems(to: menu, app: app, group: group, model: model)
            menu.popUp(positioning: nil, at: point, in: view)
        }
    }

    /// What the SwiftUI context menu used to show.
    private static func addKosmodockItems(to menu: NSMenu, app: DockApp, group: DockGroup?, model: AppModel) {
        func add(_ title: String, _ action: @escaping () -> Void) {
            menu.addItem(ActionMenuItem(title: title, handler: action))
        }
        if model.workspace.isRunning(app) {
            add(L10n.tr("Focus")) { model.workspace.focus(app) }
            if group == nil {
                add(L10n.tr("Minimize")) { model.minimizeToGroup(app) }
                let minimized = model.workspace.bundleID(for: app).map { model.minimizedWindows.windows(forBundleID: $0) } ?? []
                if !minimized.isEmpty {
                    let submenu = NSMenu()
                    for window in minimized {
                        submenu.addItem(ActionMenuItem(title: window.title.isEmpty ? model.workspace.displayName(for: app) : window.title) {
                            model.restore(window)
                        })
                    }
                    let item = NSMenuItem(title: L10n.tr("Minimized Windows"), action: nil, keyEquivalent: "")
                    item.submenu = submenu
                    menu.addItem(item)
                }
            } else {
                add(L10n.tr("Minimize to Group")) { model.minimizeToGroup(app) }
            }
            add(L10n.tr("Hide")) { model.workspace.hide(app) }
            menu.addItem(.separator())
            add(L10n.tr("Tile Left")) { model.tile(app, region: .left) }
            add(L10n.tr("Tile Right")) { model.tile(app, region: .right) }
            add(L10n.tr("Maximize")) { model.tile(app, region: .maximize) }
            menu.addItem(.separator())
            add(L10n.tr("Quit")) { model.workspace.quit(app) }
            add(L10n.tr("Force Quit")) { model.workspace.forceQuit(app) }
        } else {
            add(L10n.tr("Launch")) { model.open(app) }
        }
        menu.addItem(.separator())
        add(L10n.tr("Show in Finder")) { model.workspace.revealInFinder(app) }
        if let group {
            add(L10n.tr("Remove from %@", group.name)) { model.remove(app, from: group) }
        } else {
            add(L10n.tr("Remove from Dock")) { model.unpinApp(itemID: DockConfig.itemID(forPinned: app)) }
        }
    }
}
