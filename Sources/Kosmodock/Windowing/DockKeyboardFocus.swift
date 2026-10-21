import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Navigation

/// Keyboard focus over the bar's items. Pure, so it's tested without keys.
enum DockKeyboardNavigation {
    /// Where focus starts: the item it left, while that's still on the bar,
    /// else the first.
    static func initial(in ids: [String], previous: String?) -> String? {
        if let previous, ids.contains(previous) { return previous }
        return ids.first
    }

    /// The item `step` places from `current`, wrapping around. From an item
    /// that left the bar (or none), stepping forward starts at the first.
    static func move(from current: String?, by step: Int, in ids: [String]) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else {
            return step < 0 ? ids.last : ids.first
        }
        return ids[WidgetStackMath.index(after: index, step: step, count: ids.count)]
    }
}

/// What a key does while the dock has keyboard focus.
enum DockKeyboardCommand: Equatable {
    case move(Int)
    /// ↑/↓ turn the focused widget stack.
    case turnStack(Int)
    case open
    case leave
    /// Anything else ends the focus, so typing meant for another app doesn't
    /// land in the dock.
    case other

    init(keyCode: UInt16, shift: Bool = false) {
        switch Int(keyCode) {
        case kVK_LeftArrow: self = .move(-1)
        case kVK_RightArrow: self = .move(1)
        case kVK_Tab: self = .move(shift ? -1 : 1)
        case kVK_DownArrow: self = .turnStack(1)
        case kVK_UpArrow: self = .turnStack(-1)
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space: self = .open
        case kVK_Escape: self = .leave
        default: self = .other
        }
    }
}

// MARK: - Controller

/// ⌃⌥D puts keyboard focus on the dock: the dock panel becomes key for the
/// moment (it's non-activating, so the app in front stays active), a ring
/// marks the focused item, ←/→ move it, Return or Space opens the item and
/// Esc leaves.
@MainActor
final class DockKeyboardFocusController {
    /// ⌃⌥D, through Carbon (`HotKeyCenter`): no permission needed.
    static let shortcut = HotKeyCenter.Shortcut(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey | optionKey))

    private weak var panel: FloatingPanel?
    private let model: AppModel
    /// 'KDKF', apart from the workspaces' center.
    private let hotKeys = HotKeyCenter(signature: 0x4B44_4B46)
    private var hotKeyRegistered = false
    private var monitor: Any?
    private var resignToken: NSObjectProtocol?
    private var previous: String?

    private(set) var isActive = false
    /// Called when focus starts or ends (the dock stays shown meanwhile).
    var onActiveChange: (() -> Void)?

    init(panel: FloatingPanel, model: AppModel) {
        self.panel = panel
        self.model = model
        updateHotKey()
        model.configService.addObserver { [weak self] old, new in
            guard old.behavior.dockFocusHotKey != new.behavior.dockFocusHotKey else { return }
            self?.updateHotKey()
        }
    }

    private func updateHotKey() {
        let wanted = model.config.behavior.dockFocusHotKey
        guard wanted != hotKeyRegistered else { return }
        hotKeyRegistered = wanted
        if wanted {
            hotKeys.register([(Self.shortcut, { [weak self] in self?.toggle() })])
        } else {
            hotKeys.removeAll()
            end()
        }
    }

    func toggle() {
        if isActive { end() } else { begin() }
    }

    func begin() {
        guard !isActive, let panel,
              let first = DockKeyboardNavigation.initial(in: focusableIDs, previous: previous) else { return }
        isActive = true
        model.keyboardFocusItemID = first
        panel.allowsKey = true
        panel.orderFrontRegardless()
        panel.makeKey()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return handled ? nil : event
        }
        // A click in another app takes the keys back: focus ends with it.
        resignToken = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.end() }
        }
        onActiveChange?()
    }

    func end() {
        guard isActive else { return }
        isActive = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignToken { NotificationCenter.default.removeObserver(resignToken) }
        resignToken = nil
        previous = model.keyboardFocusItemID
        model.keyboardFocusItemID = nil
        if let panel {
            panel.allowsKey = false
            if panel.isKeyWindow {
                // Ordering the key panel out hands the keys back to the app
                // in front; it comes straight back, without key.
                panel.orderOut(nil)
                panel.orderFrontRegardless()
            }
        }
        onActiveChange?()
    }

    /// True when the key was the dock's.
    private func handle(_ event: NSEvent) -> Bool {
        guard isActive, event.window === panel else { return false }
        let ids = focusableIDs
        switch DockKeyboardCommand(keyCode: event.keyCode, shift: event.modifierFlags.contains(.shift)) {
        case .move(let step):
            model.dismissPopover?()
            withAnimation(.easeOut(duration: 0.12)) {
                model.keyboardFocusItemID = DockKeyboardNavigation.move(from: model.keyboardFocusItemID, by: step, in: ids)
            }
        case .turnStack(let step):
            if let id = model.keyboardFocusItemID, let tile = model.tile(itemID: id) {
                model.stepStack(leadID: tile.id, by: step)
            }
        case .open:
            open(model.keyboardFocusItemID)
        case .leave:
            if model.popoverItemID != nil {
                model.dismissPopover?()
            } else {
                end()
            }
        case .other:
            end()
        }
        return true
    }

    /// Does what a click on the item does. An app comes to the front, which
    /// ends the focus; a group or tile opens and keeps it.
    private func open(_ itemID: String?) {
        guard let itemID, let item = model.barItems.first(where: { $0.id == itemID }) else { return }
        switch item {
        case .group(let group):
            model.tap(group)
        case .app(let app):
            end()
            model.open(app)
        case .tile(let tile):
            model.tap(model.shownTile(onBar: tile))
        case .extra(.folder(let folder)):
            model.tap(folder)
        case .extra(.trash):
            model.trash.open()
        case .extra(.spacer):
            break
        }
    }

    /// Spacers do nothing, so focus skips them.
    private var focusableIDs: [String] {
        model.barItems.compactMap { item in
            if case .extra(.spacer) = item { return nil }
            return item.id
        }
    }
}

// MARK: - Ring

extension View {
    /// The keyboard focus ring, drawn over a bar item while it has focus.
    func keyboardFocusRing(_ itemID: String) -> some View {
        modifier(KeyboardFocusRing(itemID: itemID))
    }
}

private struct KeyboardFocusRing: ViewModifier {
    @Environment(AppModel.self) private var model
    let itemID: String

    func body(content: Content) -> some View {
        let focused = model.keyboardFocusItemID == itemID
        content.overlay {
            if focused {
                RoundedRectangle(cornerRadius: model.theme.capsuleRadius + 3, style: .continuous)
                    .strokeBorder(model.accent, lineWidth: 2)
                    .padding(-3)
                    .shadow(color: model.accent.opacity(0.55), radius: 4)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
    }
}

// MARK: - Settings

/// Settings › Behavior: the dock's keyboard focus.
struct DockKeyboardFocusSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            Toggle(isOn: model.binding(\.behavior.dockFocusHotKey)) {
                Text("Focus the Dock with ⌃⌥D")
                Text("Move between items with ← and →, open one with Return or Space, turn a widget stack with ↑ and ↓, and leave with Esc.")
            }
        } header: {
            Text("Keyboard")
        }
    }
}
