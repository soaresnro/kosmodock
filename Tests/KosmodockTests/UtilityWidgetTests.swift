import AppKit
import XCTest
@testable import Kosmodock

/// Utility widgets: conversions, water math, color formats, the clipboard
/// history's filtering and limits, Open-Meteo parsing and the config. No
/// network, and only private pasteboards (`NSPasteboard.withUniqueName()`).
final class UtilityWidgetTests: XCTestCase {
    private let english = Locale(identifier: "en_US")
    private let portuguese = Locale(identifier: "pt_BR")

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 2026-10-21 at `hour`:`minute`, UTC.
    private func date(day: Int = 21, hour: Int = 12, minute: Int = 0) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kosmodock-utility-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func permissions(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    // MARK: Unit converter

    func testConversions() throws {
        func convert(_ value: Double, _ from: String, _ to: String, _ category: ConverterCategory) throws -> Double {
            try XCTUnwrap(UnitConversion.convert(value, from: from, to: to, in: category))
        }
        XCTAssertEqual(try convert(1, "mi", "km", .length), 1.609344, accuracy: 1e-12)
        XCTAssertEqual(try convert(1, "km", "mi", .length), 0.621371192, accuracy: 1e-9)
        XCTAssertEqual(try convert(12, "in", "cm", .length), 30.48, accuracy: 1e-9)
        XCTAssertEqual(try convert(1, "lb", "kg", .mass), 0.45359237, accuracy: 1e-12)
        XCTAssertEqual(try convert(1, "st", "lb", .mass), 14, accuracy: 1e-9)
        XCTAssertEqual(try convert(16, "oz", "lb", .mass), 1, accuracy: 1e-12)
        XCTAssertEqual(try convert(1, "cup", "floz", .volume), 8, accuracy: 1e-9)
        XCTAssertEqual(try convert(1, "gal", "qt", .volume), 4, accuracy: 1e-9)
        XCTAssertEqual(try convert(100, "c", "f", .temperature), 212, accuracy: 1e-9)
        XCTAssertEqual(try convert(32, "f", "c", .temperature), 0, accuracy: 1e-9)
        XCTAssertEqual(try convert(0, "c", "k", .temperature), 273.15, accuracy: 1e-9)
        XCTAssertEqual(try convert(1, "gal", "l", .volume), 3.785411784, accuracy: 1e-12)
        XCTAssertEqual(try convert(100, "kmh", "mph", .speed), 62.1371192, accuracy: 1e-6)
        XCTAssertEqual(try convert(36, "kmh", "mps", .speed), 10, accuracy: 1e-12)
        XCTAssertEqual(try convert(1, "kn", "kmh", .speed), 1.852, accuracy: 1e-12)
        XCTAssertEqual(try convert(1, "ac", "m2", .area), 4046.8564224, accuracy: 1e-9)
        XCTAssertEqual(try convert(640, "ac", "mi2", .area), 1, accuracy: 1e-12)
        XCTAssertEqual(try convert(1, "km2", "ha", .area), 100, accuracy: 1e-9)
        XCTAssertEqual(try convert(1, "GiB", "MB", .data), 1073.741824, accuracy: 1e-9)
        XCTAssertEqual(try convert(1, "B", "bit", .data), 8, accuracy: 1e-9)
        XCTAssertNil(UnitConversion.convert(1, from: "km", to: "kg", in: .length), "a unit of another category")
        XCTAssertNil(UnitConversion.convert(.nan, from: "km", to: "mi", in: .length))
    }

    func testEveryCategoryHasUniqueUnitsAndRoundTrips() throws {
        for category in ConverterCategory.allCases {
            let ids = category.units.map(\.id)
            XCTAssertEqual(Set(ids).count, ids.count, "\(category) repeats a unit id")
            XCTAssertNotNil(category.unit(category.defaultPair.from), "\(category)")
            XCTAssertNotNil(category.unit(category.defaultPair.to), "\(category)")
            for from in ids {
                for to in ids {
                    let there = try XCTUnwrap(UnitConversion.convert(42.5, from: from, to: to, in: category))
                    let back = try XCTUnwrap(UnitConversion.convert(there, from: to, to: from, in: category))
                    XCTAssertEqual(back, 42.5, accuracy: 1e-6, "\(from) → \(to)")
                }
            }
            XCTAssertFalse(try XCTUnwrap(category.units.first).name(locale: english).isEmpty)
        }
    }

    func testConversionFormattingAndParsing() {
        XCTAssertEqual(UnitConversion.format(1609.344, locale: english), "1,609.344")
        XCTAssertEqual(UnitConversion.format(1609.344, locale: portuguese), "1.609,344")
        XCTAssertEqual(UnitConversion.format(1609.344, locale: english, grouping: false), "1609.344")
        XCTAssertEqual(UnitConversion.format(0.000621371, locale: english), "0.000621371")
        XCTAssertEqual(UnitConversion.format(2, locale: english), "2")
        XCTAssertEqual(UnitConversion.short(0.621371, locale: english), "0.6214")
        XCTAssertEqual(UnitConversion.short(12_345.6, locale: english), "12,346")

        XCTAssertEqual(UnitConversion.parse("1,5", locale: portuguese), 1.5)
        XCTAssertEqual(UnitConversion.parse("1.5", locale: english), 1.5)
        XCTAssertEqual(UnitConversion.parse("1,234.5", locale: english), 1234.5)
        XCTAssertEqual(UnitConversion.parse(" -3 ", locale: english), -3)
        XCTAssertNil(UnitConversion.parse("", locale: english))
        XCTAssertNil(UnitConversion.parse("abc", locale: english))
    }

    func testConverterStateDecodesLeniently() throws {
        let empty = try JSONDecoder().decode(ConverterState.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, ConverterState())
        XCTAssertEqual(try XCTUnwrap(empty.result), 0.621371, accuracy: 1e-6, "1 km in miles")
        let partial = try JSONDecoder().decode(ConverterState.self, from: Data(#"{ "category": "temperature", "from": "c", "to": "f", "value": 20 }"#.utf8))
        XCTAssertEqual(try XCTUnwrap(partial.result), 68, accuracy: 1e-9)
        XCTAssertThrowsError(try JSONDecoder().decode(ConverterState.self, from: Data(#"{ "category": "time" }"#.utf8)))
    }

    // MARK: Water

    func testWaterTotalsAndWeek() {
        let calendar = utc
        let drinks = [
            WaterDrink(date: date(day: 14, hour: 9), amount: 300),  // a week ago: not in the chart
            WaterDrink(date: date(day: 15, hour: 9), amount: 500),
            WaterDrink(date: date(day: 20, hour: 23, minute: 59), amount: 250),
            WaterDrink(date: date(hour: 8), amount: 250),
            WaterDrink(date: date(hour: 10), amount: 400),
        ]
        XCTAssertEqual(WaterMath.total(of: drinks, on: date(), calendar: calendar), 650)
        let week = WaterMath.week(of: drinks, endingOn: date(), calendar: calendar)
        XCTAssertEqual(week.count, 7)
        XCTAssertEqual(week.first?.start, calendar.startOfDay(for: date(day: 15)))
        XCTAssertEqual(week.last?.start, calendar.startOfDay(for: date()))
        XCTAssertEqual(week.map(\.amount), [500, 0, 0, 0, 0, 250, 650])
        XCTAssertEqual(WaterMath.progress(650, goal: 2000), 0.325, accuracy: 1e-9)
        XCTAssertEqual(WaterMath.progress(2500, goal: 2000), 1.25, accuracy: 1e-9, "past the goal")
    }

    func testDrinkingAndTakingBack() throws {
        let calendar = utc
        let old = WaterDrink(date: date(day: 1), amount: 250)
        var drinks = WaterMath.drinking(250, at: date(hour: 9), to: [old], calendar: calendar)
        XCTAssertEqual(drinks, [WaterDrink(date: date(hour: 9), amount: 250)], "drinks older than the week are dropped")
        drinks = WaterMath.drinking(330, at: date(hour: 11), to: drinks, calendar: calendar)
        let yesterday = WaterDrink(date: date(day: 20, hour: 18), amount: 500)
        drinks.insert(yesterday, at: 0)

        // Takes back today's latest glass only, never yesterday's.
        var taken = try XCTUnwrap(WaterMath.takingBack(from: drinks, on: date(hour: 12), calendar: calendar))
        XCTAssertEqual(taken, [yesterday, WaterDrink(date: date(hour: 9), amount: 250)])
        taken = try XCTUnwrap(WaterMath.takingBack(from: taken, on: date(hour: 12), calendar: calendar))
        XCTAssertEqual(taken, [yesterday])
        XCTAssertNil(WaterMath.takingBack(from: taken, on: date(hour: 12), calendar: calendar), "nothing to take back today")
    }

    func testNextGlassReminder() {
        let calendar = utc
        let drinks = [WaterDrink(date: date(hour: 10), amount: 250), WaterDrink(date: date(hour: 9), amount: 250)]
        let now = date(hour: 10, minute: 20)
        XCTAssertNil(WaterMath.nextGlass(after: drinks, every: nil, goal: 2000, now: now, calendar: calendar), "no reminder")
        XCTAssertEqual(WaterMath.nextGlass(after: drinks, every: 45, goal: 2000, now: now, calendar: calendar), date(hour: 10, minute: 45))
        XCTAssertNil(WaterMath.nextGlass(after: drinks, every: 45, goal: 500, now: now, calendar: calendar), "goal reached")
        XCTAssertEqual(
            WaterMath.nextGlass(after: drinks, every: 45, goal: 2000, now: date(day: 22, hour: 8), calendar: calendar),
            calendar.startOfDay(for: date(day: 22)), "a new day starts due"
        )
    }

    func testWaterUnitsAndOptions() throws {
        XCTAssertEqual(WaterUnit.milliliters.format(2000, locale: english), "2,000 ml")
        XCTAssertEqual(WaterUnit.ounces.format(8 * WaterUnit.millilitersPerOunce, locale: english), "8 oz")
        XCTAssertEqual(WaterUnit.ounces.format(250, locale: english), "8.5 oz")
        XCTAssertEqual(WaterUnit.ounces.format(2000, locale: english), "68 oz")
        XCTAssertEqual(WaterUnit.ounces.milliliters(1), WaterUnit.millilitersPerOunce)

        XCTAssertEqual(WaterOptions(goal: 100).resolvedGoal, 500)
        XCTAssertEqual(WaterOptions(goal: 9000).resolvedGoal, 6000)
        XCTAssertEqual(WaterOptions(unit: .milliliters).resolvedGlass, 250)
        XCTAssertEqual(WaterOptions(unit: .ounces).resolvedGlass, 8 * WaterUnit.millilitersPerOunce, accuracy: 1e-9)
        XCTAssertEqual(WaterOptions(glass: 400, unit: .ounces).resolvedGlass, 400)
    }

    // MARK: Colors

    func testColorFormats() throws {
        let color = try XCTUnwrap(RGBColor(hex: "#1A2B3C"))
        XCTAssertEqual(color, RGBColor(red: 26, green: 43, blue: 60))
        XCTAssertEqual(color.formatted(.hex), "#1A2B3C")
        XCTAssertEqual(color.formatted(.hexLowercase), "#1a2b3c")
        XCTAssertEqual(color.formatted(.rgb), "rgb(26, 43, 60)")
        XCTAssertEqual(color.formatted(.hsl), "hsl(210, 40%, 17%)")
        XCTAssertEqual(color.formatted(.swiftUI), "Color(red: 0.102, green: 0.169, blue: 0.235)")
        XCTAssertEqual(color.formatted(.nsColor), "NSColor(srgbRed: 0.102, green: 0.169, blue: 0.235, alpha: 1)")

        let white = try XCTUnwrap(RGBColor(hex: "ffffff"))
        XCTAssertEqual(white.formatted(.hsl), "hsl(0, 0%, 100%)")
        XCTAssertEqual(white.formatted(.swiftUI), "Color(red: 1, green: 1, blue: 1)")
        XCTAssertEqual(RGBColor(red: 0, green: 0, blue: 0).formatted(.nsColor), "NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)")
        XCTAssertEqual(RGBColor(red: 0, green: 255, blue: 0).formatted(.hsl), "hsl(120, 100%, 50%)")
        XCTAssertEqual(RGBColor(red: 0, green: 0, blue: 255).formatted(.hsl), "hsl(240, 100%, 50%)")
        XCTAssertEqual(RGBColor(red: 255, green: 0, blue: 191).formatted(.hsl), "hsl(315, 100%, 50%)")
        XCTAssertGreaterThan(white.luminance, 0.99)

        XCTAssertNil(RGBColor(hex: "#12345"))
        XCTAssertNil(RGBColor(hex: "#GGGGGG"))
        XCTAssertEqual(RGBColor(NSColor(srgbRed: 0.102, green: 0.169, blue: 0.235, alpha: 1))?.hex, "#1A2B3C")
        XCTAssertEqual(RGBColor(red: 300, green: -4, blue: 12), RGBColor(red: 255, green: 0, blue: 12), "components are clamped")
    }

    func testRecentColorsKeepPinsBeyondTheLimit() {
        var history = ColorHistory()
        for hex in ["#111111", "#222222", "#333333"] { history = history.adding(hex, limit: 2) }
        XCTAssertEqual(history.colors.map(\.hex), ["#333333", "#222222"])
        history = history.togglingPin("#222222")
        history = history.adding("#444444", limit: 2).adding("#555555", limit: 2)
        XCTAssertEqual(history.colors.map(\.hex), ["#555555", "#444444", "#222222"], "a pinned color doesn't count")
        // Picking a color again moves it first and keeps its pin.
        history = history.adding("#222222", limit: 2)
        XCTAssertEqual(history.colors.map(\.hex), ["#222222", "#555555", "#444444"])
        XCTAssertEqual(history.colors.first?.isPinned, true)
        XCTAssertEqual(history.removing("#555555").colors.map(\.hex), ["#222222", "#444444"])
        XCTAssertEqual(ColorHistory().adding("#abcdef", limit: 4).colors.first?.hex, "#ABCDEF")
    }

    // MARK: Clipboard history

    private func pasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard.withUniqueName()
        addTeardownBlock { pasteboard.releaseGlobally() }
        return pasteboard
    }

    func testConcealedAndTransientCopiesAreSkipped() {
        XCTAssertTrue(ClipboardFilter.shouldIgnore([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")]))
        XCTAssertTrue(ClipboardFilter.shouldIgnore([NSPasteboard.PasteboardType("org.nspasteboard.TransientType")]))
        XCTAssertTrue(ClipboardFilter.shouldIgnore([NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"), .png]))
        XCTAssertFalse(ClipboardFilter.shouldIgnore([.string, .rtf, .fileURL]))

        let board = pasteboard()
        board.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], owner: nil)
        board.setString("hunter2", forType: .string)
        XCTAssertNil(ClipboardFilter.content(of: board), "a password from a password manager")

        board.clearContents()
        board.setString("Hello", forType: .string)
        XCTAssertEqual(ClipboardFilter.content(of: board), .text("Hello"))

        board.clearContents()
        board.setString("  \n ", forType: .string)
        XCTAssertNil(ClipboardFilter.content(of: board), "blank text")

        board.clearContents()
        board.writeObjects([URL(fileURLWithPath: "/Applications/Safari.app") as NSURL])
        XCTAssertEqual(ClipboardFilter.content(of: board), .files(["/Applications/Safari.app"]))

        let png = try? XCTUnwrap(Self.samplePNG())
        board.clearContents()
        board.setData(png, forType: .png)
        XCTAssertEqual(ClipboardFilter.content(of: board), png.map { ClipboardContent.image($0) })
    }

    private static func samplePNG(width: Int = 40, height: Int = 20) -> Data? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage().flatMap(ClipboardImage.encodePNG)
    }

    private func item(_ id: String, daysAgo: Double = 0, pinned: Bool = false, now: Date) -> ClipboardItem {
        ClipboardItem(id: id, kind: .text, text: id, digest: id, date: now.addingTimeInterval(-daysAgo * 86_400), isPinned: pinned)
    }

    func testClipboardLimitAndExpiry() {
        let now = date()
        let items = [
            item("a", now: now), item("b", daysAgo: 1, now: now), item("pinned", daysAgo: 400, pinned: true, now: now),
            item("c", daysAgo: 2, now: now), item("d", daysAgo: 3, now: now), item("old", daysAgo: 31, now: now),
        ]
        let byLimit = ClipboardPolicy.pruned(items, limit: 3, days: 30, now: now)
        XCTAssertEqual(byLimit.kept.map(\.id), ["a", "b", "pinned", "c"], "pinned items don't count and never expire")
        XCTAssertEqual(byLimit.removed.map(\.id), ["d", "old"])
        let byAge = ClipboardPolicy.pruned(items, limit: 200, days: 2, now: now)
        XCTAssertEqual(byAge.kept.map(\.id), ["a", "b", "pinned", "c"])
        XCTAssertEqual(ClipboardOptions(limit: 5, days: 0).resolvedLimit, 10)
        XCTAssertEqual(ClipboardOptions(limit: 5, days: 0).resolvedDays, 1)
        XCTAssertEqual(ClipboardOptions(limit: 5000, days: 900).resolvedLimit, 1000)
    }

    func testCopyingAgainMovesAnItemUpAndKeepsItsPin() {
        let now = date()
        let items = [item("a", now: now), item("b", pinned: true, now: now), item("c", now: now)]
        var again = item("b", now: now.addingTimeInterval(60))
        again.id = "new"
        let result = ClipboardPolicy.inserting(again, into: items)
        XCTAssertEqual(result.map(\.id), ["new", "a", "c"])
        XCTAssertEqual(result.first?.isPinned, true)
        XCTAssertEqual(ClipboardPolicy.digest(of: .text("x")), ClipboardPolicy.digest(of: .text("x")))
        XCTAssertNotEqual(ClipboardPolicy.digest(of: .text("x")), ClipboardPolicy.digest(of: .files(["x"])))
    }

    func testClipboardSearch() {
        let now = date()
        let items = [
            ClipboardItem(id: "1", kind: .text, text: "Café com leite", digest: "1", date: now),
            ClipboardItem(id: "2", kind: .files, paths: ["/Users/me/Report.pdf"], digest: "2", date: now),
            ClipboardItem(id: "3", kind: .image, image: "3.png", pixelWidth: 10, pixelHeight: 5, digest: "3", date: now),
        ]
        XCTAssertEqual(ClipboardPolicy.search("cafe LEITE", in: items).map(\.id), ["1"])
        XCTAssertEqual(ClipboardPolicy.search("report", in: items).map(\.id), ["2"])
        XCTAssertEqual(ClipboardPolicy.search("  ", in: items).map(\.id), ["1", "2", "3"])
        XCTAssertEqual(items[1].summary, "Report.pdf")
        XCTAssertEqual(items[0].summary, "Café com leite")
    }

    func testClipboardStoreIsPrivate() throws {
        let store = ClipboardStore(directory: try temporaryDirectory().appendingPathComponent("clipboard"))
        let items = [ClipboardItem(id: "1", kind: .text, text: "secret", digest: "d", date: Date(timeIntervalSince1970: 1_800_000_000), isPinned: true)]
        try store.save(items)
        XCTAssertEqual(store.load(), items)
        XCTAssertEqual(try permissions(store.directory), 0o700)
        XCTAssertEqual(try permissions(store.historyFile), 0o600)
        try store.writeImage(Data([1, 2, 3]), named: "x.png")
        XCTAssertEqual(try permissions(store.imageURL("x.png")), 0o600)
        store.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
    }

    @MainActor
    func testClipboardHistoryRecordsSkipsAndPurges() throws {
        let board = pasteboard()
        let store = ClipboardStore(directory: try temporaryDirectory().appendingPathComponent("clipboard"))
        let history = ClipboardHistory(store: store, pasteboard: { board })
        board.clearContents()
        board.setString("copied before", forType: .string)
        history.setEnabled(true, options: ClipboardOptions(limit: 10, days: 30))
        history.poll()
        XCTAssertTrue(history.items.isEmpty, "what was there before the widget isn't kept")

        board.clearContents()
        board.setString("first", forType: .string)
        history.poll()
        board.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.TransientType")], owner: nil)
        board.setString("one-time code", forType: .string)
        history.poll()
        board.clearContents()
        board.setString("second", forType: .string)
        history.poll()
        XCTAssertEqual(history.items.compactMap(\.text), ["second", "first"])

        // Putting an item back is our own write, not a new item.
        history.copy(history.items[1])
        history.poll()
        XCTAssertEqual(board.string(forType: .string), "first")
        XCTAssertEqual(history.items.compactMap(\.text), ["first", "second"])

        history.togglePin(history.items[1])
        history.clear()
        XCTAssertEqual(history.items.compactMap(\.text), ["second"], "Clear History keeps pinned items")
        history.waitForWrites()
        XCTAssertEqual(store.load().compactMap(\.text), ["second"])

        history.setEnabled(false, options: ClipboardOptions())
        history.purge()
        history.waitForWrites()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
    }

    func testClipboardImagesGetAThumbnail() throws {
        let png = try XCTUnwrap(Self.samplePNG(width: 400, height: 200))
        let image = try XCTUnwrap(ClipboardImage.make(from: png))
        XCTAssertEqual(image.png, png, "a PNG is kept as it is")
        XCTAssertEqual(image.width, 400)
        XCTAssertEqual(image.height, 200)
        let thumbnail = try XCTUnwrap(NSBitmapImageRep(data: image.thumbnail))
        XCTAssertEqual(max(thumbnail.pixelsWide, thumbnail.pixelsHigh), ClipboardImage.thumbnailSize)
        XCTAssertNil(ClipboardImage.make(from: Data("not an image".utf8)))
    }

    // MARK: Weather

    private static let forecast = #"""
    {"latitude":38.72,"longitude":-9.14,"generationtime_ms":0.05,"utc_offset_seconds":3600,"timezone":"Europe/Lisbon",
     "timezone_abbreviation":"WEST","elevation":45.0,
     "current_units":{"time":"iso8601","interval":"seconds","temperature_2m":"°C","apparent_temperature":"°C","weather_code":"wmo code","is_day":""},
     "current":{"time":"2026-10-21T14:15","interval":900,"temperature_2m":21.6,"apparent_temperature":20.2,"weather_code":2,"is_day":1},
     "daily_units":{"time":"iso8601","weather_code":"wmo code","temperature_2m_max":"°C","temperature_2m_min":"°C"},
     "daily":{"time":["2026-10-21","2026-10-22","2026-10-23","2026-10-24","2026-10-25"],
              "weather_code":[2,61,null,80,0],
              "temperature_2m_max":[24.4,19.6,18.0,20.3,null],
              "temperature_2m_min":[15.2,13.9,12.5,14.1,16.0]}}
    """#

    func testForecastParsing() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let report = try OpenMeteo.report(from: Data(Self.forecast.utf8), now: now)
        XCTAssertEqual(report.temperature, 21.6)
        XCTAssertEqual(report.feelsLike, 20.2)
        XCTAssertEqual(report.condition, .partlyCloudy)
        XCTAssertTrue(report.isDay)
        XCTAssertEqual(report.updatedAt, now)
        // A day without a high is left out; one without a code is unknown.
        XCTAssertEqual(report.days.map(\.date), ["2026-10-21", "2026-10-22", "2026-10-23", "2026-10-24"])
        XCTAssertEqual(report.days[1], WeatherDay(date: "2026-10-22", code: 61, high: 19.6, low: 13.9))
        XCTAssertEqual(report.days[2].condition, .unknown)
    }

    func testOpenMeteoErrorsAreReported() {
        XCTAssertThrowsError(try OpenMeteo.report(from: Data(#"{"error":true,"reason":"Latitude must be in range of -90 to 90°. Given: 123.0."}"#.utf8))) { error in
            XCTAssertEqual((error as? OpenMeteo.Failure)?.reason, "Latitude must be in range of -90 to 90°. Given: 123.0.")
        }
        XCTAssertThrowsError(try OpenMeteo.report(from: Data(#"{"latitude":1,"daily":{"time":[]}}"#.utf8)), "no current reading")
        XCTAssertThrowsError(try OpenMeteo.report(from: Data("<html>".utf8)))
    }

    func testGeocodingParsing() throws {
        let json = #"""
        {"results":[
          {"id":2267057,"name":"Lisboa","latitude":38.71667,"longitude":-9.13333,"elevation":45.0,"feature_code":"PPLC","country_code":"PT",
           "admin1_id":2267056,"timezone":"Europe/Lisbon","population":517802,"country_id":2264397,"country":"Portugal","admin1":"Lisboa"},
          {"id":4161625,"name":"Lisbon","latitude":28.87,"longitude":-81.78,"country":"United States","admin1":"Florida"},
          {"id":1,"name":"Nowhere","latitude":1.5,"longitude":2.5}
        ],"generationtime_ms":0.6}
        """#
        let places = try OpenMeteo.places(from: Data(json.utf8))
        XCTAssertEqual(places.map(\.name), ["Lisboa", "Lisbon", "Nowhere"])
        XCTAssertEqual(places[0].detail, "Portugal", "the state is left out when it repeats the name")
        XCTAssertEqual(places[1].title, "Lisbon, Florida, United States")
        XCTAssertEqual(places[0].latitude, 38.71667)
        XCTAssertNil(places[2].detail)
        XCTAssertEqual(try OpenMeteo.places(from: Data(#"{"generationtime_ms":0.3}"#.utf8)), [], "no matches")
    }

    func testOpenMeteoURLs() throws {
        let location = WeatherLocation(name: "Lisboa", latitude: 38.71667, longitude: -9.13333)
        let forecast = try XCTUnwrap(OpenMeteo.forecastURL(for: location)?.absoluteString)
        XCTAssertTrue(forecast.hasPrefix("https://api.open-meteo.com/v1/forecast?"))
        XCTAssertTrue(forecast.contains("latitude=38.7167"))
        XCTAssertTrue(forecast.contains("longitude=-9.1333"))
        XCTAssertTrue(forecast.contains("current=temperature_2m,apparent_temperature,weather_code"))
        XCTAssertTrue(forecast.contains("daily=weather_code,temperature_2m_max,temperature_2m_min"))
        let search = try XCTUnwrap(OpenMeteo.searchURL(for: " São Paulo ", language: "pt")?.absoluteString)
        XCTAssertTrue(search.hasPrefix("https://geocoding-api.open-meteo.com/v1/search?"))
        XCTAssertTrue(search.contains("name=S%C3%A3o%20Paulo"))
        XCTAssertTrue(search.contains("language=pt"))
        XCTAssertNil(OpenMeteo.searchURL(for: "  ", language: "en"))
    }

    func testWeatherCodes() {
        XCTAssertEqual(WeatherCondition(code: 0), .clear)
        XCTAssertEqual(WeatherCondition(code: 0).symbol(isDay: true), "sun.max.fill")
        XCTAssertEqual(WeatherCondition(code: 0).symbol(isDay: false), "moon.stars.fill")
        XCTAssertEqual(WeatherCondition(code: 2).symbol(isDay: false), "cloud.moon.fill")
        XCTAssertEqual(WeatherCondition(code: 3), .overcast)
        XCTAssertEqual(WeatherCondition(code: 48), .fog)
        XCTAssertEqual(WeatherCondition(code: 55), .drizzle)
        XCTAssertEqual(WeatherCondition(code: 57), .freezingDrizzle)
        XCTAssertEqual(WeatherCondition(code: 63), .rain)
        XCTAssertEqual(WeatherCondition(code: 65).symbol(), "cloud.heavyrain.fill")
        XCTAssertEqual(WeatherCondition(code: 73), .snow)
        XCTAssertEqual(WeatherCondition(code: 81).symbol(isDay: true), "cloud.sun.rain.fill")
        XCTAssertEqual(WeatherCondition(code: 86), .snowShowers)
        XCTAssertEqual(WeatherCondition(code: 95).symbol(), "cloud.bolt.rain.fill")
        XCTAssertEqual(WeatherCondition(code: 99), .hail)
        XCTAssertEqual(WeatherCondition(code: 4), .unknown)
        XCTAssertEqual(WeatherCondition(code: -1), .unknown)
        let known = [0, 1, 2, 3, 45, 48, 51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 71, 73, 75, 77, 80, 81, 82, 85, 86, 95, 96, 99]
        for code in known {
            let condition = WeatherCondition(code: code)
            XCTAssertNotEqual(condition, .unknown, "code \(code)")
            XCTAssertNotNil(NSImage(systemSymbolName: condition.symbol(isDay: true), accessibilityDescription: nil), "code \(code)")
            XCTAssertNotNil(NSImage(systemSymbolName: condition.symbol(isDay: false), accessibilityDescription: nil), "code \(code)")
            XCTAssertFalse(condition.title.isEmpty)
        }
    }

    func testTemperatures() {
        XCTAssertEqual(TemperatureUnit.celsius.degrees(21.6), "22°")
        XCTAssertEqual(TemperatureUnit.fahrenheit.degrees(21.6), "71°")
        XCTAssertEqual(TemperatureUnit.celsius.degrees(-0.4), "0°", "never -0°")
        XCTAssertEqual(TemperatureUnit.fahrenheit.value(ofCelsius: 100), 212)
        XCTAssertEqual(OpenMeteo.dayLabel("2026-10-22", isFirst: false, locale: english), "Thu")
        XCTAssertEqual(OpenMeteo.dayLabel("2026-10-21", isFirst: true, locale: english), L10n.tr("Today"))
        XCTAssertEqual(OpenMeteo.dayLabel("garbage", isFirst: false, locale: english), "garbage")
    }

    // MARK: Config

    private func tiles(_ json: String) throws -> [DockTile] {
        try JSONDecoder().decode(DockConfig.self, from: Data(json.utf8)).tiles
    }

    func testOldConfigsAndPartialOptionsDecode() throws {
        let old = try tiles(#"{ "tiles": [ { "kind": "clock", "showsSeconds": true }, { "kind": "command", "command": "uptime" } ] }"#)
        XCTAssertEqual(old.map(\.kind), [.clock, .command])
        XCTAssertTrue(old.allSatisfy { $0.note == nil && $0.water == nil && $0.emoji == nil && $0.colors == nil && $0.clipboard == nil && $0.weather == nil })

        let utility = try tiles(#"""
        { "tiles": [
          { "kind": "note" }, { "kind": "water", "water": { "goal": 3000 } }, { "kind": "converter" },
          { "kind": "emoji", "emoji": {} }, { "kind": "colorPicker", "colors": { "format": "hsl" } },
          { "kind": "clipboard", "clipboard": { "days": 7 } },
          { "kind": "weather", "weather": { "location": { "latitude": 52.52, "longitude": 13.41 } } }
        ] }
        """#)
        XCTAssertEqual(utility.map(\.kind), TileKind.utilities)
        XCTAssertEqual(utility.map(\.id), ["note", "water", "converter", "emoji", "colorPicker", "clipboard", "weather"])
        XCTAssertEqual(utility[1].water, WaterOptions(goal: 3000))
        XCTAssertNil(utility[1].water?.unit, "the unit follows the region until chosen")
        XCTAssertEqual(utility[3].emoji, EmojiOptions())
        XCTAssertEqual(utility[4].colors, ColorPickerOptions(format: .hsl))
        XCTAssertEqual(utility[5].clipboard, ClipboardOptions(limit: 200, days: 7))
        XCTAssertEqual(utility[6].weather?.location, WeatherLocation(name: "", latitude: 52.52, longitude: 13.41))
        XCTAssertTrue(utility.allSatisfy { $0.kind.category == .utilities })
        XCTAssertTrue(TileKind.utilities.allSatisfy { !$0.title.isEmpty && $0.symbol != "square" })
    }

    func testWrongOptionValuesAreReported() {
        XCTAssertThrowsError(try tiles(#"{ "tiles": [ { "kind": "water", "water": { "goal": "lots" } } ] }"#))
        XCTAssertThrowsError(try tiles(#"{ "tiles": [ { "kind": "note", "note": { "color": "teal" } } ] }"#))
        XCTAssertThrowsError(try tiles(#"{ "tiles": [ { "kind": "weather", "weather": { "location": { "name": "Berlin" } } } ] }"#), "a place without coordinates")
    }

    func testOptionsRoundTripAndPlainTilesStayPlain() throws {
        var config = DockConfig()
        config.tiles = [
            DockTile(id: "clock", kind: .clock),
            DockTile(id: "note", kind: .note, note: NoteOptions(color: .purple)),
            DockTile(id: "water", kind: .water, water: WaterOptions(goal: 2500, glass: 300, unit: .ounces, reminderMinutes: 45)),
            DockTile(id: "weather", kind: .weather, weather: WeatherOptions(location: WeatherLocation(name: "Porto", latitude: 41.15, longitude: -8.61, detail: "Portugal"), unit: .fahrenheit)),
        ]
        let data = try JSONEncoder().encode(config)
        XCTAssertEqual(try JSONDecoder().decode(DockConfig.self, from: data).tiles, config.tiles)
        let clock = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(DockTile(id: "clock", kind: .clock))) as? [String: Any])
        XCTAssertEqual(Set(clock.keys), ["id", "kind", "width", "showsSeconds"], "no option keys for other tiles")
    }

    // MARK: State files

    func testStateFilesArePrivateAndNamedSafely() throws {
        let directory = try temporaryDirectory().appendingPathComponent("widget-state")
        let store = WidgetStateStore(directory: directory)
        try store.save(StickyNoteState(text: "Buy milk"), for: "note")
        XCTAssertEqual(store.load(StickyNoteState.self, for: "note"), StickyNoteState(text: "Buy milk"))
        XCTAssertEqual(try permissions(store.url(for: "note")), 0o600)
        XCTAssertEqual(try permissions(directory), 0o700)
        XCTAssertEqual(store.url(for: "../../evil").deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
        XCTAssertEqual(store.url(for: "../../evil").lastPathComponent, "_.._.._evil.json")
        XCTAssertEqual(store.url(for: "").lastPathComponent, "_.json")
        XCTAssertNil(store.load(WaterState.self, for: "missing"))
    }

    func testNoteFirstLine() {
        XCTAssertEqual(StickyNoteState(text: "\n\n   Shopping list  \nmilk").firstLine, "Shopping list")
        XCTAssertEqual(StickyNoteState(text: " \n ").firstLine, "")
    }

    @MainActor
    func testWidgetStateIsSavedAndLoadedByTile() throws {
        let board = pasteboard()
        let store = WidgetStateStore(directory: try temporaryDirectory())
        let note = DockTile(id: "note", kind: .note)
        let water = DockTile(id: "water", kind: .water, water: WaterOptions(glass: 300, unit: .milliliters))
        let emoji = DockTile(id: "emoji", kind: .emoji, emoji: EmojiOptions(recentCount: 8))
        let widgets = UtilityWidgets(store: store, pasteboard: { board })
        widgets.update(tiles: [note, water, emoji])
        widgets.setNoteText("Call Ana\nabout Friday", for: "note")
        widgets.drink(water)
        widgets.drink(water)
        widgets.takeBackGlass(water)
        for index in 0..<10 { widgets.useEmoji(String(UnicodeScalar(0x1F600 + index)!), tile: emoji) }
        widgets.useEmoji("😀", tile: emoji)
        XCTAssertEqual(board.string(forType: .string), "😀", "a click copies the emoji")
        XCTAssertEqual(widgets.emojiState("emoji").recents.count, 8)
        XCTAssertEqual(widgets.emojiState("emoji").recents.first, "😀")
        widgets.stop()

        let again = UtilityWidgets(store: store, pasteboard: { board })
        again.update(tiles: [note, water, emoji])
        XCTAssertEqual(again.note("note").firstLine, "Call Ana")
        XCTAssertEqual(again.waterState("water").drinks.map(\.amount), [300])
        XCTAssertEqual(again.emojiState("emoji").recents.first, "😀")
        XCTAssertTrue(again.notes.keys.contains("note"))
        again.update(tiles: [])
        XCTAssertTrue(again.notes.isEmpty, "a removed tile's state leaves memory")
        XCTAssertNotNil(store.load(StickyNoteState.self, for: "note"), "and stays on disk")
    }

    // MARK: Emoji

    func testEmojiCatalog() throws {
        let all = EmojiCatalog.all
        XCTAssertGreaterThan(all.count, 1000)
        XCTAssertEqual(Set(all.map(\.emoji)).count, all.count, "no repeats")
        let grinning = try XCTUnwrap(all.first { $0.emoji == "😀" })
        XCTAssertEqual(grinning.name, "Grinning face")
        XCTAssertEqual(all.first?.emoji, "😀", "faces first")
        XCTAssertTrue(EmojiCatalog.search("grinning").contains(grinning))
        XCTAssertTrue(EmojiCatalog.search("HEAVY black heart").contains { $0.emoji == "❤️" }, "text-style emoji get the emoji selector")
        XCTAssertTrue(EmojiCatalog.search("brasil").contains { $0.emoji == "🇧🇷" }, "flags by their Portuguese names too")
        XCTAssertTrue(EmojiCatalog.search("flag japan").contains { $0.emoji == "🇯🇵" })
        XCTAssertFalse(all.contains { $0.emoji.unicodeScalars.contains { $0.properties.isEmojiModifier } }, "no bare skin tones")

        let thumbsUp = try XCTUnwrap(all.first { $0.emoji == "👍" })
        XCTAssertTrue(thumbsUp.takesSkinTone)
        XCTAssertEqual(thumbsUp.with(.dark), "👍🏿")
        XCTAssertEqual(thumbsUp.with(.neutral), "👍")
        XCTAssertEqual(grinning.with(.medium), "😀")
        XCTAssertEqual(SkinTone.light.sample, "✋🏻")
    }
}
