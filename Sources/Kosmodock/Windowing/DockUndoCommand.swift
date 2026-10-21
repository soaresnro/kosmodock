import AppKit

/// "Undo Last Dock Change" (⌘Z) in the Kosmodock menu, and ⌘Z through the
/// main menu: there it undoes typing while a text field has typing to undo,
/// and the last Dock change otherwise. The menu items don't keep their
/// target, so the one instance lives here.
@MainActor
final class DockUndoCommand: NSObject, NSMenuItemValidation {
    private static var shared: DockUndoCommand?
    private weak var model: AppModel?

    private init(model: AppModel) {
        self.model = model
    }

    static func command(for model: AppModel) -> DockUndoCommand {
        if let shared, shared.model === model { return shared }
        let command = DockUndoCommand(model: model)
        shared = command
        return command
    }

    /// Takes over the Edit menu's Undo item, which `MainMenuBuilder` adds.
    static func installInMainMenu(model: AppModel) {
        let undo = Selector(("undo:"))
        guard let item = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items).first(where: { $0.action == undo }) else { return }
        item.target = command(for: model)
        item.action = #selector(undoTypingOrDockChange(_:))
    }

    /// For the Kosmodock menu; enabled only while there's a change to undo.
    static func menuItem(model: AppModel) -> NSMenuItem {
        let item = NSMenuItem(title: L10n.tr("Undo Last Dock Change"), action: #selector(undoDockChange(_:)), keyEquivalent: "z")
        item.target = command(for: model)
        return item
    }

    @objc func undoDockChange(_ sender: Any?) {
        model?.undoLastDockChange()
    }

    @objc func undoTypingOrDockChange(_ sender: Any?) {
        if Self.canUndoTyping {
            NSApp.sendAction(Selector(("undo:")), to: nil, from: sender)
        } else {
            model?.undoLastDockChange()
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let canUndoDock = model?.canUndoDockChange == true
        switch menuItem.action {
        case #selector(undoTypingOrDockChange(_:)): return Self.canUndoTyping || canUndoDock
        case #selector(undoDockChange(_:)): return canUndoDock
        default: return true
        }
    }

    /// The key window's undo manager (a text field's typing) has something.
    private static var canUndoTyping: Bool {
        NSApp.keyWindow?.firstResponder?.undoManager?.canUndo == true
    }
}
