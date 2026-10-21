import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    func show(section: SettingsSection?) {
        if let section { model.settingsSelection = section }
        let window = self.window ?? makeWindow()
        self.window = window
        // Kosmodock is an accessory app; activate it so text fields get focus.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let controller = NSHostingController(rootView: SettingsHost(model: model))
        controller.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: controller)
        window.title = L10n.tr("Kosmodock Settings")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 920, height: 640))
        window.center()
        window.setFrameAutosaveName("KosmodockSettings")
        window.delegate = self
        model.configService.addObserver { [weak window] old, new in
            guard old.behavior.language != new.behavior.language else { return }
            window?.title = L10n.tr("Kosmodock Settings")
        }
        return window
    }
}

/// Re-creates the settings UI when the language changes so every string —
/// including ones built in code — is re-resolved.
struct SettingsHost: View {
    let model: AppModel

    var body: some View {
        SettingsView()
            .environment(model)
            .environment(\.locale, model.locale)
            .id(model.language)
    }
}

/// Menu shared by the menu bar icon and the dock's utility button.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private var statusItem: NSStatusItem?
    private lazy var menu: NSMenu = {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }()

    init(model: AppModel) {
        self.model = model
        super.init()
        model.popUpMainMenu = { [weak self] in self?.popUpMenu() }
        setVisible(model.config.behavior.showMenuBarIcon)
        model.configService.addObserver { [weak self] old, new in
            guard old.behavior.showMenuBarIcon != new.behavior.showMenuBarIcon else { return }
            self?.setVisible(new.behavior.showMenuBarIcon)
        }
    }

    private func setVisible(_ visible: Bool) {
        if visible, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "Kosmodock")
            item.button?.toolTip = "Kosmodock"
            item.menu = menu
            statusItem = item
        } else if !visible, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    func popUpMenu() {
        rebuild(menu)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu)
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let behavior = model.config.behavior

        menu.addItem(item(L10n.tr("Kosmodock Settings…"), #selector(openSettings), key: ","))
        menu.addItem(.separator())
        for workspaceItem in WorkspaceMenu.items(model: model) { menu.addItem(workspaceItem) }

        let dockItem = item(L10n.tr("Hide Native macOS Dock"), #selector(toggleNativeDock))
        dockItem.state = behavior.suppressNativeDock ? .on : .off
        menu.addItem(dockItem)

        let focusItem = item(L10n.tr("Focus Mode on Launch & Tile"), #selector(toggleFocusMode))
        focusItem.state = behavior.focusMode ? .on : .off
        menu.addItem(focusItem)

        let reserveItem = item(L10n.tr("Reserve Screen Space (Push Windows)"), #selector(toggleReserveSpace))
        reserveItem.state = behavior.reserveScreenSpace ? .on : .off
        reserveItem.toolTip = L10n.tr("Off = Intellihide")
        menu.addItem(reserveItem)

        let minimizeItem = item(L10n.tr("Minimize Windows into Groups"), #selector(toggleMinimizeToGroups))
        minimizeItem.state = behavior.minimizeToGroups ? .on : .off
        menu.addItem(minimizeItem)

        let modeItem = NSMenuItem(title: L10n.tr("Expansion Mode"), action: nil, keyEquivalent: "")
        let modeMenu = NSMenu()
        for mode in ExpansionMode.allCases {
            let entry = item(mode.title, #selector(selectExpansionMode(_:)))
            entry.representedObject = mode.rawValue
            entry.state = behavior.expansionMode == mode ? .on : .off
            modeMenu.addItem(entry)
        }
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        if !model.windows.isTrusted {
            menu.addItem(.separator())
            menu.addItem(item(L10n.tr("Grant Accessibility Access…"), #selector(grantAccessibility)))
        }

        menu.addItem(.separator())
        menu.addItem(item(L10n.tr("Reload config.json"), #selector(reloadConfig), key: "r"))
        menu.addItem(item(L10n.tr("Open config.json"), #selector(openConfig)))
        menu.addItem(item(L10n.tr("Reveal Config in Finder"), #selector(revealConfig)))
        menu.addItem(.separator())
        menu.addItem(item(L10n.tr("Quit Kosmodock"), #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func openSettings() { model.openSettings(nil) }
    @objc private func toggleNativeDock() { model.configService.update { $0.behavior.suppressNativeDock.toggle() } }
    @objc private func toggleFocusMode() { model.configService.update { $0.behavior.focusMode.toggle() } }
    @objc private func toggleReserveSpace() { model.configService.update { $0.behavior.reserveScreenSpace.toggle() } }
    @objc private func toggleMinimizeToGroups() { model.configService.update { $0.behavior.minimizeToGroups.toggle() } }
    @objc private func grantAccessibility() { model.windows.requestAccess() }
    @objc private func reloadConfig() { model.configService.reloadFromDisk(force: true) }
    @objc private func openConfig() { model.configService.openInEditor() }
    @objc private func revealConfig() { model.configService.revealInFinder() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func selectExpansionMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = ExpansionMode(rawValue: raw) else { return }
        model.configService.update { $0.behavior.expansionMode = mode }
    }
}

/// Accessory apps have no visible menu bar, but key equivalents (⌘C/⌘V/⌘W…)
/// are still dispatched through the main menu, so text fields need one.
enum MainMenuBuilder {
    @MainActor
    static func install() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Kosmodock")
        appMenu.addItem(withTitle: "Quit Kosmodock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }
}
