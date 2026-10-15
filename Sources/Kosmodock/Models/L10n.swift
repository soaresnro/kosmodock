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
}
