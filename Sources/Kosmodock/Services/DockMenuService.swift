import AppKit
import ApplicationServices
import Foundation

// An app's own Dock menu (New Window, its window list, bookmarks…) lives in
// the app and reaches the native Dock through a private channel, so the only
// way to read it is to open that menu through Accessibility, read it and
// close it. It takes about 100 ms. Choosing an item opens it again and
// presses the item.

/// An item of an app's menu in the native Dock.
struct DockMenuEntry: Equatable, Sendable {
    var title: String
    var isEnabled = true
    var isSeparator = false
    /// The item's position in the native menu, to press it later.
    var index: Int
}

/// An item as read from the native menu, before filtering.
struct RawDockMenuItem: Equatable, Sendable {
    var title: String
    var isEnabled = true
    var hasSubmenu = false
}

enum DockMenuFilter {
    /// The app's own items. The native Dock closes the menu with its own block
    /// after the last separator (Show All Windows, Hide, Quit…), and adds an
    /// Options submenu (Keep in Dock, Open at Login…) about the native Dock:
    /// Kosmodock's menu has its own versions, so both go. Separators are kept
    /// only between items.
    static func appItems(_ items: [RawDockMenuItem]) -> [DockMenuEntry] {
        let isSeparator = { (item: RawDockMenuItem) in item.title.isEmpty && !item.hasSubmenu }
        guard let lastSeparator = items.lastIndex(where: isSeparator) else { return [] }
        var entries: [DockMenuEntry] = []
        for (index, item) in items[..<lastSeparator].enumerated() where !item.hasSubmenu {
            if isSeparator(item) {
                guard let last = entries.last, !last.isSeparator else { continue }
                entries.append(DockMenuEntry(title: "", isSeparator: true, index: index))
            } else {
                entries.append(DockMenuEntry(title: item.title, isEnabled: item.isEnabled, index: index))
            }
        }
        while entries.last?.isSeparator == true { entries.removeLast() }
        return entries
    }
}

/// The synchronous Accessibility work. Runs on `WindowManagerService`'s AX
/// queue (`performAX`), never on the main thread.
enum DockMenuAX {
    /// The app's item in the native Dock, matched by its file URL.
    static func dockItem(for appURL: URL) -> AXUIElement? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.5)
        let wanted = appURL.standardizedFileURL.path
        for list in children(of: app) {
            for item in children(of: list) {
                guard string(item, kAXSubroleAttribute) == DockBadgeMapping.applicationSubrole,
                      let url = value(item, kAXURLAttribute) as? URL,
                      url.standardizedFileURL.path == wanted
                else { continue }
                return item
            }
        }
        return nil
    }

    static func read(appURL: URL) -> [RawDockMenuItem]? {
        guard let item = dockItem(for: appURL), let menu = open(item) else { return nil }
        defer { AXUIElementPerformAction(menu, "AXCancel" as CFString) }
        return children(of: menu).map { element in
            RawDockMenuItem(
                title: string(element, kAXTitleAttribute) ?? "",
                isEnabled: (value(element, kAXEnabledAttribute) as? Bool) ?? true,
                hasSubmenu: !children(of: element).isEmpty
            )
        }
    }

    /// Presses the item at `index` if it still has `title`; otherwise closes
    /// the menu, so a menu that changed meanwhile never runs the wrong item.
    @discardableResult
    static func press(appURL: URL, index: Int, title: String) -> Bool {
        guard let item = dockItem(for: appURL), let menu = open(item) else { return false }
        let items = children(of: menu)
        guard items.indices.contains(index), string(items[index], kAXTitleAttribute) == title else {
            AXUIElementPerformAction(menu, "AXCancel" as CFString)
            return false
        }
        return AXUIElementPerformAction(items[index], kAXPressAction as CFString) == .success
    }

    /// Opens the item's menu and waits up to half a second for it.
    private static func open(_ item: AXUIElement) -> AXUIElement? {
        guard AXUIElementPerformAction(item, "AXShowMenu" as CFString) == .success else { return nil }
        for _ in 0..<50 {
            if let menu = value(item, "AXShownMenuUIElement") {
                // CFTypeRef → AXUIElement: the attribute only holds elements.
                return (menu as! AXUIElement)
            }
            usleep(10_000)
        }
        return nil
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }
}

@MainActor
final class DockMenuService {
    private let windows: WindowManagerService

    init(windows: WindowManagerService) {
        self.windows = windows
    }

    /// The app's own items, or none when it has no item in the native Dock
    /// (not running and not pinned there) or Accessibility isn't granted.
    func entries(for appURL: URL) async -> [DockMenuEntry] {
        guard windows.isTrusted else { return [] }
        let raw = await windows.performAX { DockMenuAX.read(appURL: appURL) }
        return raw.map(DockMenuFilter.appItems) ?? []
    }

    func press(_ entry: DockMenuEntry, appURL: URL) {
        Task { _ = await windows.performAX { DockMenuAX.press(appURL: appURL, index: entry.index, title: entry.title) } }
    }
}
