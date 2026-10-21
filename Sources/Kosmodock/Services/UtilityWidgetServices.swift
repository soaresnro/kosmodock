import AppKit
import CoreText
import Foundation
import Observation

// Utility widgets: sticky note, water, unit converter, emoji and color picker,
// plus the container that also runs the clipboard history
// (ClipboardHistory.swift) and the weather (WeatherService.swift).
//
// Options live in the tile, in config.json. What changes often, like a note's
// text or today's glasses, lives in one small file per tile under
// ~/.config/kosmodock/widget-state, so typing never rewrites config.json.

// MARK: - Kinds

extension TileKind {
    /// The utility widgets, in the order of the "Add Widget" menu.
    static let utilities: [TileKind] = [.note, .water, .converter, .emoji, .colorPicker, .clipboard, .weather]

    var utilityTitle: String {
        switch self {
        case .note: L10n.tr("Sticky Note")
        case .water: L10n.tr("Water")
        case .converter: L10n.tr("Unit Converter")
        case .emoji: L10n.tr("Emoji")
        case .colorPicker: L10n.tr("Color Picker")
        case .clipboard: L10n.tr("Clipboard History")
        case .weather: L10n.tr("Weather")
        default: rawValue
        }
    }

    var utilitySymbol: String {
        switch self {
        case .note: "note.text"
        case .water: "drop.fill"
        case .converter: "arrow.left.arrow.right"
        case .emoji: "face.smiling"
        case .colorPicker: "eyedropper"
        case .clipboard: "doc.on.clipboard"
        case .weather: "cloud.sun.fill"
        default: "square"
        }
    }
}

// MARK: - Options (config.json)

enum NoteColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case yellow
    case pink
    case blue
    case green
    case purple
    case red

    var id: String { rawValue }

    var title: String {
        switch self {
        case .yellow: L10n.tr("Yellow")
        case .pink: L10n.tr("Pink")
        case .blue: L10n.tr("Blue")
        case .green: L10n.tr("Green")
        case .purple: L10n.tr("Purple")
        case .red: L10n.tr("Red")
        }
    }

    /// The paper: light enough for dark text in either appearance.
    var hex: String {
        switch self {
        case .yellow: "#FFE37A"
        case .pink: "#FFB8D0"
        case .blue: "#A9D6FF"
        case .green: "#B9EDA6"
        case .purple: "#D8C2FF"
        case .red: "#FF9F98"
        }
    }
}

struct NoteOptions: Codable, Equatable, Sendable {
    var color: NoteColor = .yellow
}

enum WaterUnit: String, Codable, CaseIterable, Identifiable, Sendable {
    case milliliters = "ml"
    case ounces = "oz"

    var id: String { rawValue }
    static let millilitersPerOunce = 29.5735295625

    var title: String {
        switch self {
        case .milliliters: L10n.tr("Milliliters")
        case .ounces: L10n.tr("Ounces")
        }
    }

    var symbol: String { rawValue }

    /// Ounces where the region measures in US units.
    static var preferred: WaterUnit { Locale.current.measurementSystem == .us ? .ounces : .milliliters }

    /// 250 ml or 8 oz, in milliliters.
    var defaultGlass: Double { self == .milliliters ? 250 : 8 * Self.millilitersPerOunce }

    func value(ofMilliliters milliliters: Double) -> Double {
        self == .milliliters ? milliliters : milliliters / Self.millilitersPerOunce
    }

    func milliliters(_ value: Double) -> Double {
        self == .milliliters ? value : value * Self.millilitersPerOunce
    }

    /// The number alone: "1,250", "8.5".
    func number(_ milliliters: Double, locale: Locale = L10n.locale) -> String {
        let value = value(ofMilliliters: milliliters)
        let digits = self == .ounces && abs(value) < 10 && abs(value - value.rounded()) >= 0.05 ? 1 : 0
        return value.formatted(.number.precision(.fractionLength(digits)).locale(locale))
    }

    /// "1,250 ml", "42 oz".
    func format(_ milliliters: Double, locale: Locale = L10n.locale) -> String {
        "\(number(milliliters, locale: locale)) \(symbol)"
    }
}

struct WaterOptions: Codable, Equatable, Sendable {
    static let goalRange: ClosedRange<Double> = 500...6000
    static let reminderChoices = [30, 45, 60, 90, 120, 180]

    /// Milliliters a day.
    var goal: Double = 2000
    /// Milliliters per glass; nil is 250 ml or 8 oz.
    var glass: Double?
    /// nil follows the region.
    var unit: WaterUnit?
    /// Minutes between glasses; nil is no reminder.
    var reminderMinutes: Int?

    var resolvedUnit: WaterUnit { unit ?? .preferred }
    var resolvedGoal: Double { min(max(goal, Self.goalRange.lowerBound), Self.goalRange.upperBound) }
    var resolvedGlass: Double { min(max(glass ?? resolvedUnit.defaultGlass, 10), 2000) }
}

enum SkinTone: String, Codable, CaseIterable, Identifiable, Sendable {
    case neutral
    case light
    case mediumLight
    case medium
    case mediumDark
    case dark

    var id: String { rawValue }

    /// The Fitzpatrick modifier that follows the emoji.
    var modifier: Unicode.Scalar? {
        switch self {
        case .neutral: nil
        case .light: Unicode.Scalar(0x1F3FB)
        case .mediumLight: Unicode.Scalar(0x1F3FC)
        case .medium: Unicode.Scalar(0x1F3FD)
        case .mediumDark: Unicode.Scalar(0x1F3FE)
        case .dark: Unicode.Scalar(0x1F3FF)
        }
    }

    var title: String {
        switch self {
        case .neutral: L10n.tr("Default")
        case .light: L10n.tr("Light")
        case .mediumLight: L10n.tr("Medium-light")
        case .medium: L10n.tr("Medium (skin tone)")
        case .mediumDark: L10n.tr("Medium-dark")
        case .dark: L10n.tr("Dark")
        }
    }

    /// A raised hand in this tone.
    var sample: String { EmojiEntry(emoji: "✋", name: "", keywords: "", takesSkinTone: true).with(self) }
}

struct EmojiOptions: Codable, Equatable, Sendable {
    static let recentRange = 8...64

    var recentCount = 24
    var skinTone: SkinTone = .neutral

    var resolvedRecentCount: Int { min(max(recentCount, Self.recentRange.lowerBound), Self.recentRange.upperBound) }
}

enum ColorFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case hex
    case hexLowercase
    case rgb
    case hsl
    case swiftUI
    case nsColor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hex: L10n.tr("Hex")
        case .hexLowercase: L10n.tr("Lowercase hex")
        case .rgb: "CSS rgb()"
        case .hsl: "CSS hsl()"
        case .swiftUI: "SwiftUI Color"
        case .nsColor: "NSColor"
        }
    }
}

struct ColorPickerOptions: Codable, Equatable, Sendable {
    static let recentRange = 4...60

    var recentCount = 16
    /// What a pick copies.
    var format: ColorFormat = .hex
    var copiesOnPick = true

    var resolvedRecentCount: Int { min(max(recentCount, Self.recentRange.lowerBound), Self.recentRange.upperBound) }
}

extension NoteOptions {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        color = try c.decode(.color, or: .yellow)
    }
}

extension WaterOptions {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WaterOptions()
        goal = try c.decode(.goal, or: d.goal)
        glass = try c.decodeIfPresent(Double.self, forKey: .glass)
        unit = try c.decodeIfPresent(WaterUnit.self, forKey: .unit)
        reminderMinutes = try c.decodeIfPresent(Int.self, forKey: .reminderMinutes)
    }
}

extension EmojiOptions {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EmojiOptions()
        recentCount = try c.decode(.recentCount, or: d.recentCount)
        skinTone = try c.decode(.skinTone, or: d.skinTone)
    }
}

extension ColorPickerOptions {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ColorPickerOptions()
        recentCount = try c.decode(.recentCount, or: d.recentCount)
        format = try c.decode(.format, or: d.format)
        copiesOnPick = try c.decode(.copiesOnPick, or: d.copiesOnPick)
    }
}

// MARK: - State files

/// One JSON file per tile in `directory`, readable only by you.
struct WidgetStateStore: Sendable {
    let directory: URL

    static let standard = WidgetStateStore(
        directory: ConfigService.defaultFileURL.deletingLastPathComponent().appendingPathComponent("widget-state")
    )

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Tile ids come from config.json, so anything but letters, digits, dots,
    /// dashes and underscores is replaced, and the name never starts with a dot.
    func url(for tileID: String) -> URL {
        var name = String(tileID.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII || "-_.".unicodeScalars.contains(scalar)
                ? Character(scalar) : "_"
        })
        if name.isEmpty || name.hasPrefix(".") { name = "_" + name }
        return directory.appendingPathComponent(name).appendingPathExtension("json")
    }

    func load<Value: Decodable>(_ type: Value.Type, for tileID: String) -> Value? {
        guard let data = try? Data(contentsOf: url(for: tileID)) else { return nil }
        return try? Self.decoder.decode(type, from: data)
    }

    func save<Value: Encodable>(_ value: Value, for tileID: String) throws {
        try ProtectedFiles.createDirectory(directory)
        try ProtectedFiles.write(Self.encoder.encode(value), to: url(for: tileID))
    }
}

/// Files only you can read: folders 0700, files 0600.
enum ProtectedFiles {
    static func createDirectory(_ url: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

struct StickyNoteState: Codable, Equatable, Sendable {
    var text = ""

    /// What the tile shows: the first line with text.
    var firstLine: String {
        text.split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }
}

struct WaterDrink: Codable, Equatable, Sendable {
    var date: Date
    /// Milliliters.
    var amount: Double
}

struct WaterState: Codable, Equatable, Sendable {
    var drinks: [WaterDrink] = []
}

struct ConverterState: Codable, Equatable, Sendable {
    var category: ConverterCategory = .length
    var from = "km"
    var to = "mi"
    var value: Double = 1

    var result: Double? { UnitConversion.convert(value, from: from, to: to, in: category) }
}

struct EmojiState: Codable, Equatable, Sendable {
    /// Most recent first, as copied (with the skin tone).
    var recents: [String] = []
}

struct RecentColor: Codable, Equatable, Identifiable, Sendable {
    var hex: String
    var isPinned = false

    var id: String { hex }
}

struct ColorHistory: Codable, Equatable, Sendable {
    /// Most recent first; the first one is the tile's color.
    var colors: [RecentColor] = []

    /// `hex` first, keeping its pin, and no more than `limit` unpinned colors.
    func adding(_ hex: String, limit: Int) -> ColorHistory {
        let hex = hex.uppercased()
        var next = colors
        let existing = next.firstIndex { $0.hex == hex }.map { next.remove(at: $0) }
        next.insert(RecentColor(hex: hex, isPinned: existing?.isPinned ?? false), at: 0)
        var unpinned = 0
        next = next.filter { color in
            guard !color.isPinned else { return true }
            unpinned += 1
            return unpinned <= max(1, limit)
        }
        return ColorHistory(colors: next)
    }

    func togglingPin(_ hex: String) -> ColorHistory {
        ColorHistory(colors: colors.map { color in
            var color = color
            if color.hex == hex { color.isPinned.toggle() }
            return color
        })
    }

    func removing(_ hex: String) -> ColorHistory {
        ColorHistory(colors: colors.filter { $0.hex != hex })
    }
}

extension StickyNoteState {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(.text, or: "")
    }
}

extension WaterState {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        drinks = try c.decode(.drinks, or: [])
    }
}

extension ConverterState {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ConverterState()
        category = try c.decode(.category, or: d.category)
        from = try c.decode(.from, or: d.from)
        to = try c.decode(.to, or: d.to)
        value = try c.decode(.value, or: d.value)
    }
}

extension EmojiState {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        recents = try c.decode(.recents, or: [])
    }
}

extension ColorHistory {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        colors = try c.decode(.colors, or: [])
    }
}

extension RecentColor {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hex = try c.decode(String.self, forKey: .hex)
        isPinned = try c.decode(.isPinned, or: false)
    }
}

// MARK: - Water

struct WaterDay: Equatable, Sendable {
    var start: Date
    var amount: Double
}

/// Day totals, undo and the reminder, from the list of drinks.
enum WaterMath {
    /// The week chart needs seven days; older drinks are dropped.
    static let keptDays = 8

    static func total(of drinks: [WaterDrink], on day: Date, calendar: Calendar = .current) -> Double {
        drinks.filter { calendar.isDate($0.date, inSameDayAs: day) }.reduce(0) { $0 + $1.amount }
    }

    /// Seven days ending with `day`'s, oldest first.
    static func week(of drinks: [WaterDrink], endingOn day: Date, calendar: Calendar = .current) -> [WaterDay] {
        let today = calendar.startOfDay(for: day)
        return (0..<7).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today).map { start in
                WaterDay(start: start, amount: total(of: drinks, on: start, calendar: calendar))
            }
        }
    }

    /// Adds a glass and forgets drinks older than `keptDays`.
    static func drinking(_ amount: Double, at date: Date, to drinks: [WaterDrink], calendar: Calendar = .current) -> [WaterDrink] {
        let cutoff = calendar.date(byAdding: .day, value: -keptDays, to: calendar.startOfDay(for: date)) ?? date
        return (drinks + [WaterDrink(date: date, amount: amount)]).filter { $0.date >= cutoff }
    }

    /// Without `day`'s latest glass; nil when that day has none.
    static func takingBack(from drinks: [WaterDrink], on day: Date, calendar: Calendar = .current) -> [WaterDrink]? {
        guard let index = drinks.indices.filter({ calendar.isDate(drinks[$0].date, inSameDayAs: day) })
            .max(by: { drinks[$0].date < drinks[$1].date })
        else { return nil }
        var next = drinks
        next.remove(at: index)
        return next
    }

    /// When the next glass is due: `minutes` after today's latest one, or the
    /// start of the day before the first. Nil without a reminder or once the
    /// goal is reached.
    static func nextGlass(after drinks: [WaterDrink], every minutes: Int?, goal: Double, now: Date, calendar: Calendar = .current) -> Date? {
        guard let minutes, minutes > 0, total(of: drinks, on: now, calendar: calendar) < goal else { return nil }
        let today = drinks.filter { calendar.isDate($0.date, inSameDayAs: now) }
        guard let last = today.map(\.date).max() else { return calendar.startOfDay(for: now) }
        return last.addingTimeInterval(TimeInterval(minutes * 60))
    }

    static func progress(_ total: Double, goal: Double) -> Double {
        goal > 0 ? max(0, total / goal) : 0
    }
}

// MARK: - Unit converter

enum ConverterCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case length
    case mass
    case temperature
    case volume
    case speed
    case area
    case data

    var id: String { rawValue }

    var title: String {
        switch self {
        case .length: L10n.tr("Length")
        case .mass: L10n.tr("Mass")
        case .temperature: L10n.tr("Temperature")
        case .volume: L10n.tr("Volume")
        case .speed: L10n.tr("Speed")
        case .area: L10n.tr("Area")
        case .data: L10n.tr("Data")
        }
    }

    var symbol: String {
        switch self {
        case .length: "ruler"
        case .mass: "scalemass"
        case .temperature: "thermometer.medium"
        case .volume: "drop"
        case .speed: "speedometer"
        case .area: "square.dashed"
        case .data: "externaldrive"
        }
    }

    /// Stable ids (saved in the state file) for Foundation's units, which
    /// give the names and symbols. Where Foundation rounds a factor (a pound
    /// is 0.453592 kg there, km/h 0.277778 m/s), the exact one converts.
    var units: [ConverterUnit] {
        switch self {
        case .length:
            [ConverterUnit("mm", UnitLength.millimeters), ConverterUnit("cm", UnitLength.centimeters),
             ConverterUnit("m", UnitLength.meters), ConverterUnit("km", UnitLength.kilometers),
             ConverterUnit("in", UnitLength.inches, exact: 0.0254), ConverterUnit("ft", UnitLength.feet, exact: 0.3048),
             ConverterUnit("yd", UnitLength.yards, exact: 0.9144), ConverterUnit("mi", UnitLength.miles, exact: 1609.344),
             ConverterUnit("nmi", UnitLength.nauticalMiles, exact: 1852)]
        case .mass:
            [ConverterUnit("mg", UnitMass.milligrams), ConverterUnit("g", UnitMass.grams),
             ConverterUnit("kg", UnitMass.kilograms), ConverterUnit("t", UnitMass.metricTons, exact: 1000),
             ConverterUnit("oz", UnitMass.ounces, exact: 0.028349523125), ConverterUnit("lb", UnitMass.pounds, exact: 0.45359237),
             ConverterUnit("st", UnitMass.stones, exact: 6.35029318)]
        case .temperature:
            [ConverterUnit("c", UnitTemperature.celsius), ConverterUnit("f", UnitTemperature.fahrenheit),
             ConverterUnit("k", UnitTemperature.kelvin)]
        case .volume:
            // US customary measures; a cup is 8 fluid ounces.
            [ConverterUnit("ml", UnitVolume.milliliters), ConverterUnit("l", UnitVolume.liters),
             ConverterUnit("m3", UnitVolume.cubicMeters),
             ConverterUnit("tsp", UnitVolume.teaspoons, exact: 0.00492892159375),
             ConverterUnit("tbsp", UnitVolume.tablespoons, exact: 0.01478676478125),
             ConverterUnit("floz", UnitVolume.fluidOunces, exact: 0.0295735295625),
             ConverterUnit("cup", UnitVolume.cups, exact: 0.2365882365), ConverterUnit("pt", UnitVolume.pints, exact: 0.473176473),
             ConverterUnit("qt", UnitVolume.quarts, exact: 0.946352946), ConverterUnit("gal", UnitVolume.gallons, exact: 3.785411784),
             ConverterUnit("impgal", UnitVolume.imperialGallons, exact: 4.54609)]
        case .speed:
            [ConverterUnit("mps", UnitSpeed.metersPerSecond), ConverterUnit("kmh", UnitSpeed.kilometersPerHour, exact: 1 / 3.6),
             ConverterUnit("mph", UnitSpeed.milesPerHour, exact: 0.44704), ConverterUnit("kn", UnitSpeed.knots, exact: 1852.0 / 3600)]
        case .area:
            [ConverterUnit("cm2", UnitArea.squareCentimeters), ConverterUnit("m2", UnitArea.squareMeters),
             ConverterUnit("km2", UnitArea.squareKilometers), ConverterUnit("ha", UnitArea.hectares, exact: 10_000),
             ConverterUnit("in2", UnitArea.squareInches, exact: 0.00064516), ConverterUnit("ft2", UnitArea.squareFeet, exact: 0.09290304),
             ConverterUnit("yd2", UnitArea.squareYards, exact: 0.83612736), ConverterUnit("ac", UnitArea.acres, exact: 4046.8564224),
             ConverterUnit("mi2", UnitArea.squareMiles, exact: 2_589_988.110336)]
        case .data:
            [ConverterUnit("bit", UnitInformationStorage.bits), ConverterUnit("B", UnitInformationStorage.bytes),
             ConverterUnit("kB", UnitInformationStorage.kilobytes), ConverterUnit("KiB", UnitInformationStorage.kibibytes),
             ConverterUnit("MB", UnitInformationStorage.megabytes), ConverterUnit("MiB", UnitInformationStorage.mebibytes),
             ConverterUnit("GB", UnitInformationStorage.gigabytes), ConverterUnit("GiB", UnitInformationStorage.gibibytes),
             ConverterUnit("TB", UnitInformationStorage.terabytes), ConverterUnit("TiB", UnitInformationStorage.tebibytes),
             ConverterUnit("Mbit", UnitInformationStorage.megabits), ConverterUnit("Gbit", UnitInformationStorage.gigabits)]
        }
    }

    var defaultPair: (from: String, to: String) {
        switch self {
        case .length: ("km", "mi")
        case .mass: ("kg", "lb")
        case .temperature: ("c", "f")
        case .volume: ("l", "gal")
        case .speed: ("kmh", "mph")
        case .area: ("m2", "ft2")
        case .data: ("GB", "GiB")
        }
    }

    func unit(_ id: String) -> ConverterUnit? {
        units.first { $0.id == id }
    }
}

struct ConverterUnit: Identifiable {
    let id: String
    let dimension: Dimension
    /// Base units (meters, kilograms, liters…) in one, when Foundation's own
    /// factor is rounded.
    let exact: Double?

    init(_ id: String, _ dimension: Dimension, exact: Double? = nil) {
        self.id = id
        self.dimension = dimension
        self.exact = exact
    }

    func baseValue(of value: Double) -> Double {
        exact.map { value * $0 } ?? dimension.converter.baseUnitValue(fromValue: value)
    }

    func value(ofBase base: Double) -> Double {
        exact.map { base / $0 } ?? dimension.converter.value(fromBaseUnitValue: base)
    }

    var symbol: String { dimension.symbol }

    /// "kilometers", in the interface language.
    func name(locale: Locale = L10n.locale) -> String {
        let formatter = MeasurementFormatter()
        formatter.locale = locale
        formatter.unitStyle = .long
        formatter.unitOptions = .providedUnit
        return formatter.string(from: dimension)
    }
}

enum UnitConversion {
    static func convert(_ value: Double, from: String, to: String, in category: ConverterCategory) -> Double? {
        guard value.isFinite, let source = category.unit(from), let target = category.unit(to) else { return nil }
        guard source.id != target.id else { return value }
        return target.value(ofBase: source.baseValue(of: value))
    }

    /// Up to six decimals, or six significant digits below 1: "1,609.344",
    /// "0.000621". `grouping` off is for copying.
    static func format(_ value: Double, locale: Locale = L10n.locale, grouping: Bool = true) -> String {
        guard value.isFinite else { return "—" }
        let style = FloatingPointFormatStyle<Double>.number
            .locale(locale)
            .grouping(grouping ? .automatic : .never)
        if value != 0, abs(value) < 1 {
            return value.formatted(style.precision(.significantDigits(1...6)))
        }
        return value.formatted(style.precision(.fractionLength(0...6)))
    }

    /// A shorter reading for the tile: four significant digits, or whole
    /// numbers from 10,000.
    static func short(_ value: Double, locale: Locale = L10n.locale) -> String {
        guard value.isFinite else { return "—" }
        let style = FloatingPointFormatStyle<Double>.number.locale(locale)
        if abs(value) >= 10_000 { return value.formatted(style.precision(.fractionLength(0))) }
        return value.formatted(style.precision(.significantDigits(1...4)))
    }

    /// The language's decimal separator, or a dot; grouping separators are skipped.
    static func parse(_ text: String, locale: Locale = L10n.locale) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.isLenient = true
        if let number = formatter.number(from: trimmed) { return number.doubleValue }
        return Double(trimmed.replacingOccurrences(of: ",", with: "."))
    }
}

// MARK: - Emoji

struct EmojiEntry: Hashable, Identifiable, Sendable {
    /// As shown, without a skin tone.
    let emoji: String
    /// "Grinning face", in English (Unicode's names).
    let name: String
    /// Lowercased names, without diacritics, to search.
    let keywords: String
    let takesSkinTone: Bool

    var id: String { emoji }

    func with(_ tone: SkinTone) -> String {
        guard takesSkinTone, let modifier = tone.modifier, let base = emoji.unicodeScalars.first else { return emoji }
        var scalars = String.UnicodeScalarView()
        scalars.append(base)
        scalars.append(modifier)
        return String(scalars)
    }
}

/// Every single-character emoji the system font draws, with its Unicode name,
/// and the flags of every region. Built once, with no network.
enum EmojiCatalog {
    static let all: [EmojiEntry] = build()

    /// Faces first, then people, animals and food, objects, travel, symbols.
    private static let blocks: [ClosedRange<UInt32>] = [
        0x1F600...0x1F64F, 0x1F900...0x1F9FF, 0x1FA70...0x1FAFF, 0x1F300...0x1F5FF,
        0x1F680...0x1F6FF, 0x2600...0x27BF, 0x1F000...0x1F2FF, 0x2000...0x25FF, 0x27C0...0x2BFF, 0x3000...0x33FF,
    ]

    static func search(_ query: String, in entries: [EmojiEntry] = all) -> [EmojiEntry] {
        let words = fold(query).split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return entries }
        return entries.filter { entry in
            entry.emoji == query || words.allSatisfy { entry.keywords.contains($0) }
        }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func build() -> [EmojiEntry] {
        let font = CTFontCreateWithName("AppleColorEmoji" as CFString, 20, nil)
        var seen = Set<String>()
        var entries: [EmojiEntry] = []
        for block in blocks {
            for value in block {
                guard let scalar = Unicode.Scalar(value) else { continue }
                let properties = scalar.properties
                guard properties.isEmoji, !properties.isEmojiModifier, !(0x1F1E6...0x1F1FF).contains(value),
                      let name = properties.name, !name.hasPrefix("EMOJI COMPONENT"),
                      draws(String(Character(scalar)), in: font)
                else { continue }
                // Text-style characters such as ❤ need the emoji variation selector.
                let emoji = properties.isEmojiPresentation ? String(Character(scalar)) : String(Character(scalar)) + "\u{FE0F}"
                guard seen.insert(emoji).inserted else { continue }
                let names = [name] + (properties.nameAlias.map { [$0] } ?? [])
                entries.append(EmojiEntry(
                    emoji: emoji, name: sentenceCase(name),
                    keywords: fold(names.joined(separator: " ")), takesSkinTone: properties.isEmojiModifierBase
                ))
            }
        }
        return entries + flags(font: font)
    }

    /// Regions with a flag the font draws as one glyph, named in English,
    /// Portuguese and Spanish.
    private static func flags(font: CTFont) -> [EmojiEntry] {
        let locales = ["en_US", "pt_BR", "es_ES"].map(Locale.init(identifier:))
        return Locale.Region.isoRegions.compactMap { region -> EmojiEntry? in
            let code = region.identifier
            guard code.count == 2, code.unicodeScalars.allSatisfy({ (65...90).contains($0.value) }),
                  let english = locales[0].localizedString(forRegionCode: code)
            else { return nil }
            var scalars = String.UnicodeScalarView()
            for letter in code.unicodeScalars {
                if let indicator = Unicode.Scalar(0x1F1E6 + letter.value - 65) { scalars.append(indicator) }
            }
            let flag = String(scalars)
            guard draws(flag, in: font) else { return nil }
            let names = locales.compactMap { $0.localizedString(forRegionCode: code) }
            return EmojiEntry(
                emoji: flag, name: "Flag: \(english)",
                keywords: fold("flag " + Set(names).sorted().joined(separator: " ")), takesSkinTone: false
            )
        }
        .sorted { $0.keywords < $1.keywords }
    }

    /// "GRINNING FACE" as "Grinning face".
    private static func sentenceCase(_ name: String) -> String {
        let lower = name.lowercased()
        return lower.prefix(1).uppercased() + lower.dropFirst()
    }

    /// The font draws `text` as one glyph of its own (no fallback, no letters).
    private static func draws(_ text: String, in font: CTFont) -> Bool {
        let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let line = CTLineCreateWithAttributedString(attributed)
        guard CTLineGetGlyphCount(line) == 1,
              let runs = CTLineGetGlyphRuns(line) as? [CTRun], runs.count == 1,
              let attributes = CTRunGetAttributes(runs[0]) as? [String: Any],
              let used = attributes[kCTFontAttributeName as String] as? NSFont,
              used.fontName == CTFontCopyPostScriptName(font) as String
        else { return false }
        var glyph = CGGlyph()
        CTRunGetGlyphs(runs[0], CFRange(location: 0, length: 1), &glyph)
        return glyph != 0
    }
}

// MARK: - Colors

/// An 8-bit sRGB color and the ways to copy it.
struct RGBColor: Equatable, Hashable, Sendable {
    var red: Int
    var green: Int
    var blue: Int

    init(red: Int, green: Int, blue: Int) {
        self.red = min(255, max(0, red))
        self.green = min(255, max(0, green))
        self.blue = min(255, max(0, blue))
    }

    /// `#RRGGBB` or `RRGGBB`.
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(red: Int(value >> 16 & 0xFF), green: Int(value >> 8 & 0xFF), blue: Int(value & 0xFF))
    }

    init?(_ color: NSColor) {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        func component(_ value: CGFloat) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
        self.init(red: component(rgb.redComponent), green: component(rgb.greenComponent), blue: component(rgb.blueComponent))
    }

    var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }

    /// Relative luminance, 0 (black) to 1 (white), for picking a text color.
    var luminance: Double {
        0.2126 * Double(red) / 255 + 0.7152 * Double(green) / 255 + 0.0722 * Double(blue) / 255
    }

    /// Hue in degrees, saturation and lightness in percent, rounded.
    var hsl: (hue: Int, saturation: Int, lightness: Int) {
        let r = Double(red) / 255, g = Double(green) / 255, b = Double(blue) / 255
        let high = max(r, g, b), low = min(r, g, b)
        let lightness = (high + low) / 2
        guard high > low else { return (0, 0, Int((lightness * 100).rounded())) }
        let delta = high - low
        let saturation = lightness > 0.5 ? delta / (2 - high - low) : delta / (high + low)
        var hue: Double
        switch high {
        case r: hue = (g - b) / delta + (g < b ? 6 : 0)
        case g: hue = (b - r) / delta + 2
        default: hue = (r - g) / delta + 4
        }
        hue *= 60
        return (Int(hue.rounded()) % 360, Int((saturation * 100).rounded()), Int((lightness * 100).rounded()))
    }

    func formatted(_ format: ColorFormat) -> String {
        switch format {
        case .hex: return hex
        case .hexLowercase: return hex.lowercased()
        case .rgb: return "rgb(\(red), \(green), \(blue))"
        case .hsl:
            let hsl = hsl
            return "hsl(\(hsl.hue), \(hsl.saturation)%, \(hsl.lightness)%)"
        case .swiftUI:
            return "Color(red: \(Self.unit(red)), green: \(Self.unit(green)), blue: \(Self.unit(blue)))"
        case .nsColor:
            return "NSColor(srgbRed: \(Self.unit(red)), green: \(Self.unit(green)), blue: \(Self.unit(blue)), alpha: 1)"
        }
    }

    /// 0…255 as 0…1 with up to three decimals, always with a dot: "0.102", "1".
    private static func unit(_ component: Int) -> String {
        var text = String(format: "%.3f", Double(component) / 255)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

// MARK: - Service

/// The utility widgets' state, by tile id, and the services of the ones that
/// read the pasteboard or the network. Each part runs only while its tile is
/// on the bar (`update(tiles:)`).
@MainActor
@Observable
final class UtilityWidgets {
    private(set) var notes: [String: StickyNoteState] = [:]
    private(set) var water: [String: WaterState] = [:]
    private(set) var conversions: [String: ConverterState] = [:]
    private(set) var emoji: [String: EmojiState] = [:]
    private(set) var colors: [String: ColorHistory] = [:]
    /// The tile sampling a screen color right now.
    private(set) var samplingTileID: String?

    let clipboard: ClipboardHistory
    let weather: WeatherService

    @ObservationIgnored private let store: WidgetStateStore
    @ObservationIgnored private var kinds: [String: TileKind] = [:]
    @ObservationIgnored private var dirty: Set<String> = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var sampler: NSColorSampler?
    @ObservationIgnored private let pasteboardProvider: @MainActor () -> NSPasteboard
    /// Debug snapshots: no pasteboard, network or state file writes.
    @ObservationIgnored var isPreview = false {
        didSet {
            clipboard.isPreview = isPreview
            weather.isPreview = isPreview
        }
    }

    /// Tests pass their own store and pasteboard.
    init(
        store: WidgetStateStore = .standard, clipboard: ClipboardHistory? = nil, weather: WeatherService? = nil,
        pasteboard: @escaping @MainActor () -> NSPasteboard = { .general }
    ) {
        self.store = store
        self.clipboard = clipboard ?? ClipboardHistory(pasteboard: pasteboard)
        self.weather = weather ?? WeatherService()
        pasteboardProvider = pasteboard
    }

    /// Loads the state of new tiles, saves and forgets removed ones, and
    /// starts or stops the clipboard history and the weather.
    func update(tiles: [DockTile]) {
        var next: [String: TileKind] = [:]
        for tile in tiles where TileKind.utilities.contains(tile.kind) { next[tile.id] = tile.kind }
        let hadClipboard = kinds.values.contains(.clipboard)
        for (id, kind) in kinds where next[id] != kind {
            if dirty.contains(id) { save(id, kind: kind) }
            forget(id, kind: kind)
        }
        for (id, kind) in next where kinds[id] != kind { load(id, kind: kind) }
        kinds = next

        let clipboardTile = tiles.first { $0.kind == .clipboard }
        clipboard.setEnabled(clipboardTile != nil, options: clipboardTile?.clipboard ?? ClipboardOptions())
        // Removing the widget deletes what it kept.
        if hadClipboard, clipboardTile == nil { clipboard.purge() }
        weather.update(tiles: tiles.filter { $0.kind == .weather })
    }

    /// Saves what's pending and stops the services (quitting).
    func stop() {
        saveTask?.cancel()
        saveTask = nil
        for id in dirty { if let kind = kinds[id] { save(id, kind: kind) } }
        dirty.removeAll()
        clipboard.setEnabled(false, options: ClipboardOptions())
        // The app exits right after: the history's queued writes finish first.
        clipboard.waitForWrites()
        weather.update(tiles: [])
    }

    /// The details opened: fresh readings where it helps.
    func detailsDidOpen(_ tile: DockTile) {
        if tile.kind == .weather { weather.refresh(tileID: tile.id, force: false) }
    }

    // MARK: Note

    func note(_ tileID: String) -> StickyNoteState { notes[tileID] ?? StickyNoteState() }

    func setNoteText(_ text: String, for tileID: String) {
        guard notes[tileID]?.text != text else { return }
        notes[tileID, default: StickyNoteState()].text = text
        markDirty(tileID)
    }

    // MARK: Water

    func waterState(_ tileID: String) -> WaterState { water[tileID] ?? WaterState() }

    func drink(_ tile: DockTile, at date: Date = Date()) {
        let options = tile.water ?? WaterOptions()
        water[tile.id] = WaterState(drinks: WaterMath.drinking(options.resolvedGlass, at: date, to: waterState(tile.id).drinks))
        markDirty(tile.id)
    }

    func takeBackGlass(_ tile: DockTile, at date: Date = Date()) {
        guard let drinks = WaterMath.takingBack(from: waterState(tile.id).drinks, on: date) else { return }
        water[tile.id] = WaterState(drinks: drinks)
        markDirty(tile.id)
    }

    // MARK: Converter

    func conversion(_ tileID: String) -> ConverterState { conversions[tileID] ?? ConverterState() }

    func setConversion(_ state: ConverterState, for tileID: String) {
        guard conversions[tileID] != state else { return }
        conversions[tileID] = state
        markDirty(tileID)
    }

    // MARK: Emoji

    func emojiState(_ tileID: String) -> EmojiState { emoji[tileID] ?? EmojiState() }

    /// Copies `text` and puts it first in the tile's recents.
    func useEmoji(_ text: String, tile: DockTile) {
        copy(text)
        let limit = (tile.emoji ?? EmojiOptions()).resolvedRecentCount
        var recents = emojiState(tile.id).recents.filter { $0 != text }
        recents.insert(text, at: 0)
        emoji[tile.id] = EmojiState(recents: Array(recents.prefix(limit)))
        markDirty(tile.id)
    }

    // MARK: Color picker

    func colorHistory(_ tileID: String) -> ColorHistory { colors[tileID] ?? ColorHistory() }

    /// Shows the system's magnifier; a pick becomes the tile's color, is
    /// copied when the tile says so, and then `picked` runs. Needs no Screen
    /// Recording permission.
    func sampleColor(for tile: DockTile, picked: @escaping @MainActor () -> Void) {
        guard samplingTileID == nil else { return }
        let sampler = NSColorSampler()
        self.sampler = sampler
        samplingTileID = tile.id
        let tileID = tile.id
        let options = tile.colors ?? ColorPickerOptions()
        sampler.show { [weak self] color in
            let rgb = color.flatMap(RGBColor.init)
            Task { @MainActor in
                guard let self else { return }
                self.sampler = nil
                self.samplingTileID = nil
                guard let rgb else { return }
                self.addColor(rgb.hex, to: tileID, options: options)
                if options.copiesOnPick { self.copy(rgb.formatted(options.format)) }
                picked()
            }
        }
    }

    func addColor(_ hex: String, to tileID: String, options: ColorPickerOptions) {
        colors[tileID] = colorHistory(tileID).adding(hex, limit: options.resolvedRecentCount)
        markDirty(tileID)
    }

    func togglePin(_ hex: String, in tileID: String) {
        colors[tileID] = colorHistory(tileID).togglingPin(hex)
        markDirty(tileID)
    }

    func removeColor(_ hex: String, from tileID: String) {
        colors[tileID] = colorHistory(tileID).removing(hex)
        markDirty(tileID)
    }

    // MARK: Pasteboard

    /// Puts `text` on the pasteboard, as a plain string.
    func copy(_ text: String) {
        guard !isPreview else { return }
        let pasteboard = pasteboardProvider()
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: Files

    private func load(_ id: String, kind: TileKind) {
        switch kind {
        case .note: notes[id] = store.load(StickyNoteState.self, for: id) ?? StickyNoteState()
        case .water: water[id] = store.load(WaterState.self, for: id) ?? WaterState()
        case .converter: conversions[id] = store.load(ConverterState.self, for: id) ?? ConverterState()
        case .emoji: emoji[id] = store.load(EmojiState.self, for: id) ?? EmojiState()
        case .colorPicker: colors[id] = store.load(ColorHistory.self, for: id) ?? ColorHistory()
        default: break
        }
    }

    private func forget(_ id: String, kind: TileKind) {
        dirty.remove(id)
        switch kind {
        case .note: notes[id] = nil
        case .water: water[id] = nil
        case .converter: conversions[id] = nil
        case .emoji: emoji[id] = nil
        case .colorPicker: colors[id] = nil
        default: break
        }
    }

    private func markDirty(_ id: String) {
        dirty.insert(id)
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            let pending = self.dirty
            self.dirty.removeAll()
            self.saveTask = nil
            for id in pending { if let kind = self.kinds[id] { self.save(id, kind: kind) } }
        }
    }

    private func save(_ id: String, kind: TileKind) {
        guard !isPreview else { return }
        do {
            switch kind {
            case .note: if let state = notes[id] { try store.save(state, for: id) }
            case .water: if let state = water[id] { try store.save(state, for: id) }
            case .converter: if let state = conversions[id] { try store.save(state, for: id) }
            case .emoji: if let state = emoji[id] { try store.save(state, for: id) }
            case .colorPicker: if let state = colors[id] { try store.save(state, for: id) }
            default: break
            }
        } catch {
            NSLog("Kosmodock: could not save the state of widget \(id): \(error.localizedDescription)")
        }
    }
}

// MARK: - App model

extension AppModel {
    /// Samples a screen color for the tile, then shows its details. The open
    /// popover is closed first, so the color under it can be picked too.
    func sampleColor(_ tile: DockTile) {
        let itemID = DockConfig.itemID(for: tile)
        dismissPopover?()
        utilities.sampleColor(for: tile) { [weak self] in
            guard let self, self.popoverItemID != itemID else { return }
            self.presentPopover?(itemID)
        }
    }

    /// Edits a tile's options in config.json, by id.
    func updateTile(_ id: String, _ change: (inout DockTile) -> Void) {
        configService.update { config in
            guard let index = config.tiles.firstIndex(where: { $0.id == id }) else { return }
            change(&config.tiles[index])
        }
    }
}
