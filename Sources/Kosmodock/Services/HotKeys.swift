import Carbon.HIToolbox
import OSLog

/// System-wide shortcuts through Carbon's `RegisterEventHotKey`, which works
/// for a background app and needs no permission (unlike a global key monitor,
/// which needs Accessibility or Input Monitoring). A combination another app
/// already registered fails to register and is logged.
@MainActor
final class HotKeyCenter {
    struct Shortcut: Equatable {
        /// A virtual key code (`kVK_…`).
        var keyCode: UInt32
        /// Carbon modifiers (`controlKey | optionKey`).
        var modifiers: UInt32
    }

    /// 'KDWS', which tells our hotkey events apart from other components'.
    private static let signature: OSType = 0x4B44_5753

    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: @MainActor () -> Void] = [:]
    private var handler: EventHandlerRef?

    /// Replaces every registered shortcut.
    func register(_ shortcuts: [(Shortcut, @MainActor () -> Void)]) {
        removeAll()
        guard !shortcuts.isEmpty else { return }
        installHandlerIfNeeded()
        for (index, (shortcut, action)) in shortcuts.enumerated() {
            let id = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: Self.signature, id: id),
                GetApplicationEventTarget(), 0, &ref
            )
            if status == noErr, let ref {
                refs.append(ref)
                actions[id] = action
            } else {
                Logger.hotKeys.error("Hotkey \(shortcut.keyCode, privacy: .public) not registered: \(status, privacy: .public)")
            }
        }
    }

    func removeAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        actions.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // The application target delivers on the main thread.
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr, hotKeyID.signature == HotKeyCenter.signature else { return OSStatus(eventNotHandledErr) }
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { center.actions[hotKeyID.id]?() }
            return noErr
        }, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    /// ⌃⌥1 … ⌃⌥9.
    static func controlOption(digit: Int) -> Shortcut? {
        let keys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        guard (1...keys.count).contains(digit) else { return nil }
        return Shortcut(keyCode: UInt32(keys[digit - 1]), modifiers: UInt32(controlKey | optionKey))
    }
}

extension Logger {
    static let hotKeys = Logger(subsystem: "dev.kosmodock.Kosmodock", category: "hotkeys")
}
