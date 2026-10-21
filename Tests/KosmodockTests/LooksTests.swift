import Foundation
import SwiftUI
import XCTest
@testable import Kosmodock

/// Seasonal styles are presets like the others, plus decorations that each
/// have a switch and are saved with the surface.
final class SeasonalStyleTests: XCTestCase {
    private let seasonal: [DockStyle] = [.halloween, .hauntedNight, .candyCorn, .christmas, .snowyNight, .candyCane]

    func testSeasonalStylesFormTheirOwnSection() {
        XCTAssertEqual(DockStyle.allCases.filter { $0.family == .seasonal }, seasonal)
        XCTAssertEqual(DockStyle.allCases.filter { $0.family == .classic }, [.glass, .midnight, .graphite, .neon, .paper, .floating])
    }

    func testPresetsTurnOnAllTheirDecorations() {
        for style in seasonal {
            XCTAssertFalse(style.decorationOptions.isEmpty, style.rawValue)
            XCTAssertEqual(style.surface.decorations, SeasonalDecoration.normalized(style.decorationOptions), style.rawValue)
            XCTAssertTrue(style.surface.isVisible, "\(style.rawValue) has a bar to decorate")
            XCTAssertNotNil(style.surface.colorScheme, "\(style.rawValue) picks a readable scheme")
        }
        XCTAssertEqual(DockStyle.halloween.decorationOptions, [.pumpkins, .bats, .cobwebs])
        XCTAssertEqual(DockStyle.candyCane.surface.colorScheme, .light)
        XCTAssertEqual(DockStyle.christmas.surface.colorScheme, .dark)
    }

    func testEveryDecorationBelongsToAStyleAndIsDrawn() {
        let offered = Set(DockStyle.allCases.flatMap(\.decorationOptions))
        XCTAssertEqual(offered, Set(SeasonalDecoration.allCases))
        XCTAssertEqual(Set(SeasonalPainter.order), Set(SeasonalDecoration.allCases))
        XCTAssertEqual(SeasonalPainter.order.count, SeasonalDecoration.allCases.count)
    }

    func testPresetsRoundTrip() throws {
        for style in seasonal {
            var theme = ThemeConfig()
            theme.apply(style)
            let decoded = try JSONDecoder().decode(ThemeConfig.self, from: JSONEncoder().encode(theme))
            XCTAssertEqual(decoded, theme, style.rawValue)
            XCTAssertFalse(decoded.isCustomized, style.rawValue)
        }
    }

    func testASurfaceWithoutDecorationsGetsTheStylesOwn() throws {
        // As a hand-written config might say it: the style and a few values.
        let theme = try JSONDecoder().decode(ThemeConfig.self, from: Data(#"{ "style": "christmas", "surface": { "cornerRadius": 12 } }"#.utf8))
        XCTAssertEqual(theme.surface.decorations, [.snow, .snowCap, .icicles, .twinkleLights])
        XCTAssertEqual(theme.surface.cornerRadius, 12)
    }

    func testDecorationsAreNormalizedAndUnknownOnesFail() throws {
        let surface = try JSONDecoder().decode(DockSurface.self, from: Data(#"{ "decorations": ["snow", "bats", "snow"] }"#.utf8))
        XCTAssertEqual(surface.decorations, [.bats, .snow], "once each, in declaration order")
        XCTAssertThrowsError(try JSONDecoder().decode(DockSurface.self, from: Data(#"{ "decorations": ["confetti"] }"#.utf8)))
    }

    func testTurningADecorationOffCustomizesTheStyle() {
        var theme = ThemeConfig()
        theme.apply(.halloween)
        theme.surface.decorations.removeAll { $0 == .bats }
        XCTAssertTrue(theme.isCustomized)
        theme.apply(.glass)
        XCTAssertEqual(theme.customizations[DockStyle.halloween.rawValue]?.decorations, [.pumpkins, .cobwebs], "kept for when it's picked again")
        theme.apply(.halloween)
        theme.restore()
        XCTAssertEqual(theme.surface.decorations, [.pumpkins, .bats, .cobwebs])
    }

    /// Configs from before decorations, pets and icon packs read back as they were.
    func testOldConfigsDecodeUnchanged() throws {
        let theme = try JSONDecoder().decode(ThemeConfig.self, from: Data("""
        { "style": "neon", "surface": {
            "blur": true, "material": "hudWindow", "fillTopHex": "#0A0A12", "fillBottomHex": "#000000", "fillAngle": 0,
            "fillOpacity": 0.9, "borderHex": "#FF2BD6", "borderOpacity": 0.9, "borderWidth": 1.5, "specularBorder": false,
            "glowHex": "#00E5FF", "glowOpacity": 0.75, "sheen": false, "cornerRadius": 26, "reflection": false } }
        """.utf8))
        XCTAssertEqual(theme.surface, DockStyle.neon.surface)
        XCTAssertEqual(theme.surface.decorations, [])
        XCTAssertNil(theme.iconPack)
        XCTAssertEqual(theme.appIcons, [:])

        let config = try JSONDecoder().decode(DockConfig.self, from: Data(#"{ "tiles": [{ "id": "clock", "kind": "clock" }] }"#.utf8))
        XCTAssertNil(config.tiles[0].pet)
        XCTAssertEqual(config.theme, ThemeConfig())
        // A tile without pet options writes none.
        let data = try JSONEncoder().encode(config.tiles[0])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("pet"))
    }

    func testIconChoicesRoundTrip() throws {
        var theme = ThemeConfig()
        theme.iconPack = "flat"
        theme.appIcons = ["com.apple.Safari": "~/Pictures/safari.png", "com.apple.Notes": ""]
        let decoded = try JSONDecoder().decode(ThemeConfig.self, from: JSONEncoder().encode(theme))
        XCTAssertEqual(decoded, theme)
    }
}

/// Pet options decode leniently, and the pet's pace and sleep are pure functions.
final class PetTests: XCTestCase {
    func testPetOptionsDecodeLeniently() throws {
        let tile = try JSONDecoder().decode(DockTile.self, from: Data(#"{ "id": "pet", "kind": "pet", "pet": { "animal": "ladybug", "roams": true } }"#.utf8))
        XCTAssertEqual(tile.kind, .pet)
        XCTAssertEqual(tile.petOptions, PetOptions(animal: .ladybug, roams: true))
        XCTAssertEqual(tile.petOptions.size, .medium)
        XCTAssertEqual(tile.petOptions.follows, .cpu)
        XCTAssertEqual(tile.petOptions.coat, PetAnimal.ladybug.naturalHex)
        let bare = try JSONDecoder().decode(DockTile.self, from: Data(#"{ "kind": "pet" }"#.utf8))
        XCTAssertEqual(bare.petOptions, PetOptions())
        XCTAssertThrowsError(try JSONDecoder().decode(PetOptions.self, from: Data(#"{ "animal": "dragon" }"#.utf8)))
        var full = PetOptions(animal: .dog, coatHex: "#7A4A26", size: .large, follows: .memory, roams: true, staysVisible: true)
        XCTAssertEqual(try JSONDecoder().decode(PetOptions.self, from: JSONEncoder().encode(full)), full)
        full.coatHex = nil
        XCTAssertEqual(full.coat, PetAnimal.dog.naturalHex)
    }

    func testPaceFollowsTheThresholds() {
        XCTAssertEqual(PetActivity.level(load: 0.05, metric: .cpu), .sitting)
        XCTAssertEqual(PetActivity.level(load: 0.15, metric: .cpu), .walking)
        XCTAssertEqual(PetActivity.level(load: 0.49, metric: .cpu), .walking)
        XCTAssertEqual(PetActivity.level(load: 0.5, metric: .cpu), .running)
        XCTAssertEqual(PetActivity.level(load: 0.59, metric: .memory), .sitting)
        XCTAssertEqual(PetActivity.level(load: 0.7, metric: .memory), .walking)
        XCTAssertEqual(PetActivity.level(load: 0.9, metric: .memory), .running)
        XCTAssertEqual(PetActivity.next(after: nil, load: 0.16, metric: .cpu), .walking, "the first reading decides")
    }

    func testPaceChangesOnlyClearlyPastAThreshold() {
        XCTAssertEqual(PetActivity.next(after: .sitting, load: 0.16, metric: .cpu), .sitting)
        XCTAssertEqual(PetActivity.next(after: .sitting, load: 0.19, metric: .cpu), .walking)
        XCTAssertEqual(PetActivity.next(after: .walking, load: 0.13, metric: .cpu), .walking)
        XCTAssertEqual(PetActivity.next(after: .walking, load: 0.11, metric: .cpu), .sitting)
        XCTAssertEqual(PetActivity.next(after: .running, load: 0.48, metric: .cpu), .running)
        XCTAssertEqual(PetActivity.next(after: .running, load: 0.4, metric: .cpu), .walking)
        XCTAssertEqual(PetActivity.next(after: .sitting, load: 0.9, metric: .cpu), .running, "a jump goes straight to running")
    }

    func testItNapsAfterAQuietWhileAndWakesWhenTheMacWorks() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var memory = PetMemory()
        memory.record(load: 0.05, metric: .cpu, at: start)
        XCTAssertEqual(memory.mood(at: start), .sitting)
        memory.record(load: 0.05, metric: .cpu, at: start.addingTimeInterval(60))
        XCTAssertEqual(memory.quietSince, start, "quiet since the first quiet reading")
        XCTAssertEqual(memory.mood(at: start.addingTimeInterval(PetMemory.sleepAfter - 1)), .sitting)
        XCTAssertEqual(memory.mood(at: start.addingTimeInterval(PetMemory.sleepAfter)), .sleeping)

        memory.record(load: 0.7, metric: .cpu, at: start.addingTimeInterval(200))
        XCTAssertNil(memory.quietSince)
        XCTAssertEqual(memory.mood(at: start.addingTimeInterval(200)), .running)
        memory.record(load: 0.05, metric: .cpu, at: start.addingTimeInterval(300))
        XCTAssertEqual(memory.mood(at: start.addingTimeInterval(300 + PetMemory.sleepAfter - 1)), .sitting, "the quiet while starts over")
    }

    func testFoodWakesItAndItEatsForAMoment() {
        let start = Date(timeIntervalSinceReferenceDate: 5_000)
        var memory = PetMemory()
        memory.record(load: 0, metric: .cpu, at: start)
        let asleep = start.addingTimeInterval(PetMemory.sleepAfter + 30)
        XCTAssertEqual(memory.mood(at: asleep), .sleeping)
        memory.feed(at: asleep)
        XCTAssertEqual(memory.mood(at: asleep), .eating)
        XCTAssertEqual(memory.mood(at: asleep.addingTimeInterval(PetMemory.mealLength - 0.5)), .eating)
        XCTAssertEqual(memory.mood(at: asleep.addingTimeInterval(PetMemory.mealLength)), .sitting, "awake after the meal")
        XCTAssertEqual(memory.mood(at: asleep.addingTimeInterval(PetMemory.sleepAfter)), .sleeping, "until another quiet while")
    }

    func testWalkTurnsAtTheEnds() {
        let path = PetPath(startX: 10, startTime: 100, facingRight: true)
        XCTAssertEqual(path.position(at: 100, speed: 20, range: 50).x, 10)
        XCTAssertEqual(path.position(at: 101, speed: 20, range: 50).x, 30, accuracy: 0.001)
        let turned = path.position(at: 103, speed: 20, range: 50)
        XCTAssertEqual(turned.x, 30, accuracy: 0.001, "60 pt on: 40 to the end, 20 back")
        XCTAssertFalse(turned.facingRight)
        XCTAssertEqual(path.position(at: 105, speed: 20, range: 50).x, 10, accuracy: 0.001, "a full loop later, back where it began")
        XCTAssertTrue(path.position(at: 105, speed: 20, range: 50).facingRight)

        let left = PetPath(startX: 10, startTime: 0, facingRight: false)
        XCTAssertEqual(left.position(at: 0.25, speed: 20, range: 50).x, 5, accuracy: 0.001)
        XCTAssertTrue(left.position(at: 1, speed: 20, range: 50).facingRight, "bounced off the left end")
        XCTAssertEqual(left.position(at: 1, speed: 20, range: 50).x, 10, accuracy: 0.001)
    }

    func testAStillPetStaysPutInsideItsRange() {
        let path = PetPath(startX: 80, startTime: 0, facingRight: false)
        XCTAssertEqual(path.position(at: 10, speed: 0, range: 50).x, 50, "clamped when the range shrank")
        XCTAssertFalse(path.position(at: 10, speed: 0, range: 50).facingRight)
        XCTAssertEqual(path.position(at: 10, speed: 30, range: 0).x, 0)
    }

    func testCoatsMatchByHex() {
        XCTAssertEqual(PetCoat(hex: nil), .natural)
        XCTAssertEqual(PetCoat(hex: PetCoat.golden.hex?.lowercased()), .golden)
        XCTAssertNil(PetCoat(hex: "#123456"), "a custom color")
    }
}

/// Icon packs match file names loosely, pack.json maps the rest, and the
/// resolver picks a custom icon, then the pack, then the app's own.
final class IconPackTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("kosmodock-icon-packs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func makePack(_ name: String, files: [String], manifest: String? = nil) throws -> URL {
        let pack = folder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        for file in files { try Data([0x89, 0x50, 0x4E, 0x47]).write(to: pack.appendingPathComponent(file)) }
        if let manifest { try Data(manifest.utf8).write(to: pack.appendingPathComponent(IconPack.manifestName)) }
        return pack
    }

    func testKeysIgnoreCaseAndPunctuation() {
        XCTAssertEqual(IconPackMatching.key("Visual-Studio-Code"), "visualstudiocode")
        XCTAssertEqual(IconPackMatching.key("visual studio code"), "visualstudiocode")
        XCTAssertEqual(IconPackMatching.key("com.apple.Safari"), "comapplesafari")
        XCTAssertEqual(IconPackMatching.key("Café_Bar"), "cafébar")
        let keys = IconPackMatching.keys(name: "Visual Studio Code", displayName: "Code", bundleFileName: "Visual Studio Code", bundleID: "com.microsoft.VSCode")
        XCTAssertEqual(keys, ["commicrosoftvscode", "visualstudiocode", "code"], "bundle id first, no repeats")
    }

    func testFileNamesMatchNamesBundleIDsAndSlugs() throws {
        let url = try makePack("flat", files: ["Visual-Studio-Code.PNG", "com.apple.Safari.png", "slack.png", "notes.txt", ".hidden.png"])
        let pack = IconPack.load(from: url)
        XCTAssertEqual(pack.id, "flat")
        XCTAssertEqual(pack.name, "flat", "the folder's name without pack.json")
        XCTAssertEqual(pack.padding, 0)
        XCTAssertNil(pack.problem)
        XCTAssertEqual(pack.iconCount, 3, "images only, no hidden files")
        XCTAssertEqual(pack.iconURL(forKeys: IconPackMatching.keys(name: "Visual Studio Code"))?.lastPathComponent, "Visual-Studio-Code.PNG")
        XCTAssertEqual(pack.iconURL(forKeys: IconPackMatching.keys(name: "Safari", bundleID: "com.apple.Safari"))?.lastPathComponent, "com.apple.Safari.png")
        XCTAssertEqual(pack.iconURL(forKeys: IconPackMatching.keys(name: "SLACK"))?.lastPathComponent, "slack.png")
        XCTAssertNil(pack.iconURL(forKeys: IconPackMatching.keys(name: "Notes")))
    }

    func testManifestNamesThePackAndMapsApps() throws {
        let url = try makePack("letters", files: ["term.png", "Terminal.png", "safari.png"], manifest: """
        { "name": "Flat Letters", "author": "Someone", "padding": 0.15,
          "icons": { "Terminal": "term.png", "com.apple.Safari": "missing.png", "Escape": "../outside.png" } }
        """)
        let pack = IconPack.load(from: url)
        XCTAssertEqual(pack.name, "Flat Letters")
        XCTAssertEqual(pack.author, "Someone")
        XCTAssertEqual(pack.padding, 0.15, accuracy: 0.0001)
        XCTAssertEqual(pack.iconURL(forKeys: IconPackMatching.keys(name: "Terminal"))?.lastPathComponent, "term.png", "pack.json wins over a file name")
        XCTAssertEqual(
            pack.iconURL(forKeys: IconPackMatching.keys(name: "Safari", bundleID: "com.apple.Safari"))?.lastPathComponent, "safari.png",
            "a mapping to a file that isn't there is skipped"
        )
        XCTAssertNil(pack.mapped[IconPackMatching.key("Escape")], "only files inside the pack")
    }

    func testPaddingStaysInBounds() throws {
        XCTAssertEqual(IconPack.clampedPadding(nil), 0)
        XCTAssertEqual(IconPack.clampedPadding(-1), 0)
        XCTAssertEqual(IconPack.clampedPadding(0.9), 0.4)
        XCTAssertEqual(IconPack.clampedPadding(.nan), 0)
        XCTAssertEqual(IconPack.clampedPadding(0.25), 0.25)
        let url = try makePack("wide", files: ["a.png"], manifest: #"{ "padding": 2 }"#)
        XCTAssertEqual(IconPack.load(from: url).padding, IconPack.maximumPadding)
    }

    func testABrokenManifestIsReportedAndIgnored() throws {
        let url = try makePack("broken", files: ["Safari.png"], manifest: #"{ "padding": "lots" }"#)
        let pack = IconPack.load(from: url)
        XCTAssertNotNil(pack.problem)
        XCTAssertEqual(pack.name, "broken")
        XCTAssertNotNil(pack.iconURL(forKeys: ["safari"]), "its images still count")
    }

    func testPacksAreListedByName() throws {
        _ = try makePack("zeta", files: ["a.png"], manifest: #"{ "name": "Alpha Icons" }"#)
        _ = try makePack("beta", files: ["b.png"])
        try Data().write(to: folder.appendingPathComponent("loose.png"))
        XCTAssertEqual(IconPack.loadAll(in: folder).map(\.name), ["Alpha Icons", "beta"])
        XCTAssertEqual(IconPack.loadAll(in: folder.appendingPathComponent("none")), [])
    }

    func testCustomIconThenPackThenTheAppsOwn() throws {
        let pack = IconPack.load(from: try makePack("p", files: ["Safari.png"], manifest: #"{ "padding": 0.1 }"#))
        let names = IconPackMatching.keys(name: "Safari", bundleID: "com.apple.Safari")
        let exists: (String) -> Bool = { $0.hasSuffix("custom.png") }
        let custom = ["com.apple.Safari": "/icons/custom.png"]

        XCTAssertEqual(
            IconResolver.choice(overrideKeys: ["com.apple.Safari"], overrides: custom, nameKeys: names, pack: pack, fileExists: exists),
            .custom(URL(fileURLWithPath: "/icons/custom.png"))
        )
        guard case .pack(let url, let padding) = IconResolver.choice(overrideKeys: ["com.apple.Safari"], overrides: [:], nameKeys: names, pack: pack) else {
            return XCTFail("the pack covers Safari")
        }
        XCTAssertEqual(url.lastPathComponent, "Safari.png")
        XCTAssertEqual(padding, 0.1, accuracy: 0.0001)
        XCTAssertEqual(IconResolver.choice(overrideKeys: ["com.apple.Safari"], overrides: [:], nameKeys: names, pack: nil), .app)
        XCTAssertEqual(
            IconResolver.choice(overrideKeys: ["com.apple.Notes"], overrides: [:], nameKeys: IconPackMatching.keys(name: "Notes"), pack: pack), .app,
            "apps the pack doesn't cover keep their icon"
        )
    }

    func testAnEmptyCustomPathKeepsTheAppsOwnIconAndAMissingOneFallsThrough() throws {
        let pack = IconPack.load(from: try makePack("p", files: ["Safari.png"]))
        let names = IconPackMatching.keys(name: "Safari")
        XCTAssertEqual(IconResolver.choice(overrideKeys: ["com.apple.Safari"], overrides: ["com.apple.Safari": ""], nameKeys: names, pack: pack), .app)
        let gone = IconResolver.choice(overrideKeys: ["com.apple.Safari"], overrides: ["com.apple.Safari": "/nowhere/x.png"], nameKeys: names, pack: pack, fileExists: { _ in false })
        guard case .pack = gone else { return XCTFail("a custom image that's gone falls through to the pack") }
        XCTAssertEqual(
            IconResolver.choice(overrideKeys: ["com.apple.Safari", "Safari"], overrides: ["Safari": "~/a.png"], nameKeys: names, pack: nil, fileExists: { _ in true }),
            .custom(URL(fileURLWithPath: ("~/a.png" as NSString).expandingTildeInPath)),
            "the entry's id when it was saved without a bundle id, with ~ expanded"
        )
    }

    func testPaddingInsetsTheImage() throws {
        let image = NSImage(size: NSSize(width: 64, height: 32))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 64, height: 32).fill()
        image.unlockFocus()
        let url = folder.appendingPathComponent("wide.png")
        let png = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation))?.representation(using: .png, properties: [:]))
        try png.write(to: url)
        let padded = try XCTUnwrap(IconLibrary.image(at: url, padding: 0.4))
        XCTAssertEqual(padded.size, NSSize(width: 256, height: 256), "always a square")
        XCTAssertNil(IconLibrary.image(at: folder.appendingPathComponent("none.png"), padding: 0))
    }
}
