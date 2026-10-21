import Foundation

/// Localized strings for text that isn't a SwiftUI string literal: enum
/// titles, badges, AppKit menus, error messages.
///
/// SwiftUI literals (`Text("Launch & Tile")`) are resolved by SwiftUI itself
/// from the `locale` environment value; both read the same
/// `Localization/<lang>.lproj/Localizable.strings` files, which
/// `scripts/bundle.sh` copies into the app bundle.
enum L10n {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var bundle: Bundle = .main
    nonisolated(unsafe) private static var currentLocale: Locale = .autoupdatingCurrent

    static func setLanguage(_ language: AppLanguage) {
        let selected = language.lprojName
            .flatMap { Bundle.main.path(forResource: $0, ofType: "lproj") }
            .flatMap(Bundle.init(path:))
        lock.lock()
        bundle = selected ?? .main
        currentLocale = language.locale
        lock.unlock()
    }

    static var locale: Locale {
        lock.lock()
        defer { lock.unlock() }
        return currentLocale
    }

    /// Looks up `key` (the English text) and, when arguments are given, uses
    /// it as a format string (`%@`, `%lld`, `%d`).
    static func tr(_ key: String, _ arguments: CVarArg...) -> String {
        lock.lock()
        let source = bundle
        let locale = currentLocale
        lock.unlock()
        let format = source.localizedString(forKey: key, value: key, table: nil)
        return arguments.isEmpty ? format : String(format: format, locale: locale, arguments: arguments)
    }

    // MARK: Texts saved in config.json

    // Kosmodock writes a few texts into config.json itself: the default System
    // group's label, its command's fallback output and a new command tile's
    // label. They're saved in English,
    // and older configs may hold another language's spelling; either way they
    // show in the interface language. Text the user typed is shown as is.
    static let battery = configKey("Battery")
    static let acPower = configKey("AC power")
    static let uptime = configKey("Uptime")

    /// `text` in the interface language when it is a config text in any
    /// language ("Bateria" shows as "Batería" in Spanish); otherwise unchanged.
    static func configText(_ text: String) -> String {
        guard let key = configTextIndex[text.trimmingCharacters(in: .whitespaces).lowercased()] else { return text }
        return tr(key)
    }

    /// Every spelling of `keys`, lowercased, mapped to its key. Each element of
    /// `translations` gives one language's spelling of a key.
    static func index(of keys: [String], translations: [(String) -> String]) -> [String: String] {
        var index: [String: String] = [:]
        for key in keys {
            index[key.lowercased()] = key
            for translate in translations { index[translate(key).lowercased()] = key }
        }
        return index
    }

    private static let configTextIndex = index(
        of: [battery, acPower, uptime],
        translations: AppLanguage.allCases.compactMap(\.lprojName)
            .compactMap { Bundle.main.path(forResource: $0, ofType: "lproj").flatMap(Bundle.init(path:)) }
            .map { bundle in { bundle.localizedString(forKey: $0, value: $0, table: nil) } }
    )

    /// Marks a config text's key; scripts/check_localizations.py collects these.
    private static func configKey(_ key: String) -> String { key }
}
