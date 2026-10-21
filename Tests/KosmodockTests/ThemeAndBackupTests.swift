import Foundation
import SwiftUI
import XCTest
@testable import Kosmodock

/// Every style keeps its own edits; restoring drops only the selected one's.
final class StyleCustomizationTests: XCTestCase {
    func testSwitchingStylesKeepsAndBringsBackEdits() {
        var theme = ThemeConfig()
        theme.apply(.neon)
        theme.surface.cornerRadius = 8
        theme.apply(.paper)
        XCTAssertEqual(theme.surface, DockStyle.paper.surface, "an unedited style starts from its preset")
        XCTAssertTrue(theme.isCustomized(.neon))
        XCTAssertFalse(theme.isCustomized(.paper))
        XCTAssertEqual(theme.surface(for: .neon).cornerRadius, 8)

        theme.apply(.neon)
        XCTAssertEqual(theme.surface.cornerRadius, 8)
        XCTAssertTrue(theme.isCustomized)
        XCTAssertNil(theme.customizations[DockStyle.neon.rawValue], "the selected style's edits live in surface")
    }

    func testUneditedStylesStoreNothing() {
        var theme = ThemeConfig()
        for style in DockStyle.allCases { theme.apply(style) }
        XCTAssertEqual(theme.customizations, [:])
    }

    func testPickingTheSelectedStyleAgainKeepsItsEdits() {
        var theme = ThemeConfig()
        theme.surface.sheen = false
        theme.apply(.glass)
        XCTAssertFalse(theme.surface.sheen)
    }

    func testRestoreDropsOnlyTheSelectedStylesEdits() {
        var theme = ThemeConfig()
        theme.surface.cornerRadius = 30
        theme.apply(.graphite)
        theme.surface.reflection = false
        theme.restore()
        XCTAssertEqual(theme.surface, DockStyle.graphite.surface)
        XCTAssertFalse(theme.isCustomized)
        XCTAssertTrue(theme.isCustomized(.glass), "other styles keep their edits")

        theme.apply(.glass)
        XCTAssertEqual(theme.surface.cornerRadius, 30)
        theme.restore()
        XCTAssertEqual(theme, ThemeConfig())
    }

    func testRestoreDropsAHandWrittenEntryForTheSelectedStyle() {
        var theme = ThemeConfig()
        var edited = DockStyle.glass.surface
        edited.borderWidth = 3
        theme.customizations[DockStyle.glass.rawValue] = edited
        theme.restore()
        XCTAssertEqual(theme.customizations, [:])
    }

    func testReflectionDefaults() {
        let reflecting = DockStyle.allCases.filter { $0.surface.reflection }
        XCTAssertEqual(reflecting, [.graphite, .floating])
        XCTAssertTrue(DockStyle.allCases.allSatisfy { $0.surface.fillAngle == 0 })
    }
}

/// Configs written before these fields existed must read back exactly.
final class ThemeCompatibilityTests: XCTestCase {
    private func theme(_ json: String) throws -> ThemeConfig {
        try JSONDecoder().decode(ThemeConfig.self, from: Data(json.utf8))
    }

    /// A graphite theme as the previous version saved it: every surface key
    /// but `fillAngle` and `reflection`, and no `customizations`.
    func testOldConfigsDecodeUnchanged() throws {
        let graphite = try theme("""
        { "style": "graphite", "iconSize": 40, "surface": {
            "blur": true, "material": "hudWindow", "fillTopHex": "#3A3F4B", "fillBottomHex": "#0E1014",
            "fillOpacity": 0.86, "borderHex": "#8FB6FF", "borderOpacity": 0.55, "borderWidth": 1,
            "specularBorder": false, "glowHex": "#4C8DFF", "glowOpacity": 0.55, "sheen": true, "cornerRadius": 12 } }
        """)
        XCTAssertEqual(graphite.surface, DockStyle.graphite.surface)
        XCTAssertFalse(graphite.isCustomized)
        XCTAssertEqual(graphite.customizations, [:])
        XCTAssertEqual(graphite.surface.fillAngle, 0)
        XCTAssertTrue(graphite.surface.reflection, "graphite reflects unless turned off")

        let glass = try theme("""
        { "style": "glass", "surface": {
            "blur": true, "material": "hudWindow", "fillTopHex": null, "fillBottomHex": null,
            "fillOpacity": 0.35, "borderHex": "#FFFFFF", "borderOpacity": 0.6, "borderWidth": 1,
            "specularBorder": true, "glowHex": "#FFFFFF", "glowOpacity": 0, "sheen": true, "cornerRadius": 22 } }
        """)
        XCTAssertEqual(glass, ThemeConfig())

        let config = try JSONDecoder().decode(DockConfig.self, from: Data(#"{ "theme": { "style": "floating" } }"#.utf8))
        XCTAssertEqual(config.theme.surface, DockStyle.floating.surface)
        XCTAssertFalse(config.theme.isCustomized)
    }

    func testRoundTripKeepsEveryStylesEdits() throws {
        var original = ThemeConfig()
        original.apply(.midnight)
        original.surface.fillAngle = 135
        original.surface.reflection = true
        original.apply(.floating)
        original.surface.reflection = false
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ThemeConfig.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.customizations[DockStyle.midnight.rawValue]?.fillAngle, 135)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let kept = try XCTUnwrap(object["customizations"] as? [String: Any], "customizations is a JSON object")
        XCTAssertNotNil(kept["midnight"])
    }

    func testKeptEditsFallBackToTheirStyle() throws {
        let decoded = try theme(#"{ "customizations": { "neon": { "cornerRadius": 10 } } }"#)
        var expected = DockStyle.neon.surface
        expected.cornerRadius = 10
        XCTAssertEqual(decoded.customizations["neon"], expected)
        XCTAssertEqual(decoded.style, .glass)
        XCTAssertTrue(decoded.isCustomized(.neon))
        XCTAssertFalse(decoded.isCustomized)
    }

    func testNullCustomizationsAndWrongTypes() throws {
        XCTAssertEqual(try theme(#"{ "customizations": null }"#), ThemeConfig())
        XCTAssertThrowsError(try theme(#"{ "customizations": { "neon": { "cornerRadius": "big" } } }"#))
        XCTAssertThrowsError(try theme(#"{ "surface": { "fillAngle": "steep" } }"#))
    }

    func testFillAngleTurnsTheGradientClockwise() {
        func assertPoints(_ angle: Double, _ start: UnitPoint, _ end: UnitPoint, file: StaticString = #filePath, line: UInt = #line) {
            var surface = DockSurface()
            surface.fillAngle = angle
            let points = surface.fillPoints
            for (actual, expected) in [(points.start, start), (points.end, end)] {
                XCTAssertEqual(actual.x, expected.x, accuracy: 1e-9, "\(angle)°", file: file, line: line)
                XCTAssertEqual(actual.y, expected.y, accuracy: 1e-9, "\(angle)°", file: file, line: line)
            }
        }
        assertPoints(0, .top, .bottom)
        assertPoints(90, .trailing, .leading)
        assertPoints(180, .bottom, .top)
        assertPoints(270, .leading, .trailing)
        assertPoints(360, .top, .bottom)
        assertPoints(45, .topTrailing, .bottomLeading)
    }
}

/// Backups are plain files in a temporary folder here, never ~/.config.
@MainActor
final class ConfigBackupTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kosmodock-backups-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func contents(_ backup: ConfigBackup?) throws -> String {
        try String(contentsOf: XCTUnwrap(backup).url, encoding: .utf8)
    }

    func testFileNamesCarryTheLocalTime() throws {
        let stamp = ConfigBackupStore.stamp(start)
        let name = ConfigBackupStore.fileName(stamp: stamp, sequence: 1)
        XCTAssertNotNil(name.range(of: #"^config-\d{8}-\d{6}\.json$"#, options: .regularExpression), name)
        XCTAssertEqual(ConfigBackupStore.parse(name)?.date, start)
        XCTAssertEqual(ConfigBackupStore.parse(ConfigBackupStore.fileName(stamp: stamp, sequence: 3))?.sequence, 3)
        for other in ["config.json", "config-latest.json", "config-20260101-1200.json", "notes-20260101-120000.json", "config-20260101-120000-x.json"] {
            XCTAssertNil(ConfigBackupStore.parse(other), other)
        }
    }

    func testACopyEqualToTheNewestIsSkipped() throws {
        let store = ConfigBackupStore(directory: try makeDirectory())
        XCTAssertNotNil(try store.save(Data("a".utf8), at: start))
        XCTAssertNil(try store.save(Data("a".utf8), at: start.addingTimeInterval(60)))
        XCTAssertEqual(store.list().count, 1)
        XCTAssertNotNil(try store.save(Data("b".utf8), at: start.addingTimeInterval(120)))
        XCTAssertNotNil(try store.save(Data("a".utf8), at: start.addingTimeInterval(180)), "only the newest counts")
        XCTAssertEqual(try store.list().map { try contents($0) }, ["a", "b", "a"])
    }

    func testCopiesInTheSameSecondAreKeptInOrder() throws {
        let store = ConfigBackupStore(directory: try makeDirectory())
        try store.save(Data("first".utf8), at: start)
        let second = try store.save(Data("second".utf8), at: start)
        XCTAssertEqual(second?.sequence, 2)
        XCTAssertEqual(try store.list().map { try contents($0) }, ["second", "first"])
    }

    func testOnlyTheNewestTwentyAreKept() throws {
        let directory = try makeDirectory()
        let unrelated = directory.appendingPathComponent("notes.txt")
        try Data("mine".utf8).write(to: unrelated)
        let store = ConfigBackupStore(directory: directory)
        for index in 0..<25 {
            try store.save(Data("\(index)".utf8), at: start.addingTimeInterval(Double(index) * 60))
        }
        let backups = store.list()
        XCTAssertEqual(backups.count, ConfigBackupStore.defaultLimit)
        XCTAssertEqual(ConfigBackupStore.defaultLimit, 20)
        XCTAssertEqual(try contents(backups.first), "24")
        XCTAssertEqual(try contents(backups.last), "5")
        XCTAssertEqual(backups.first?.date, start.addingTimeInterval(24 * 60))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path), "other files are left alone")
    }

    // MARK: ConfigService

    private func makeService(groupName: String) throws -> ConfigService {
        let fileURL = try makeDirectory().appendingPathComponent("config.json")
        var config = DockConfig()
        config.groups = [DockGroup(id: "g", name: groupName)]
        try JSONEncoder().encode(config).write(to: fileURL)
        let service = ConfigService(fileURL: fileURL)
        service.reloadFromDisk(force: true)
        XCTAssertNil(service.lastError)
        return service
    }

    private func groupNameOnDisk(_ service: ConfigService) throws -> String? {
        try JSONDecoder().decode(DockConfig.self, from: Data(contentsOf: service.fileURL)).groups.first?.name
    }

    func testBackupsLiveNextToTheConfig() throws {
        let service = try makeService(groupName: "Old")
        XCTAssertEqual(service.backupStore.directory, service.fileURL.deletingLastPathComponent().appendingPathComponent("backups"))
        XCTAssertTrue(service.backUp())
        XCTAssertTrue(service.backUp())
        XCTAssertEqual(service.backups.count, 1, "an unchanged config isn't copied twice")
    }

    func testRestoreBacksUpTheCurrentConfigFirst() throws {
        let service = try makeService(groupName: "Old")
        service.backUp()
        let old = try XCTUnwrap(service.backups.first)
        service.update { $0.groups[0].name = "New" }
        service.saveNow()

        XCTAssertTrue(service.restore(old))
        XCTAssertNil(service.lastError)
        XCTAssertEqual(service.config.groups.first?.name, "Old")
        XCTAssertEqual(try groupNameOnDisk(service), "Old")
        XCTAssertEqual(service.backups.count, 2)
        let newest = try JSONDecoder().decode(DockConfig.self, from: Data(contentsOf: XCTUnwrap(service.backups.first).url))
        XCTAssertEqual(newest.groups.first?.name, "New", "the replaced config was backed up")

        // The watcher's reload sees its own write and ignores it.
        let loadedAt = service.lastLoadedAt
        service.reloadFromDisk()
        XCTAssertEqual(service.lastLoadedAt, loadedAt)
    }

    func testAnInvalidBackupChangesNothing() throws {
        let service = try makeService(groupName: "Current")
        let broken = try XCTUnwrap(try service.backupStore.save(Data(#"{ "groups": 3 }"#.utf8), at: start))
        service.refreshBackups()
        let before = try Data(contentsOf: service.fileURL)

        XCTAssertFalse(service.restore(broken))
        XCTAssertTrue(service.lastError?.contains(broken.url.lastPathComponent) == true, service.lastError ?? "")
        XCTAssertEqual(service.config.groups.first?.name, "Current")
        XCTAssertEqual(try Data(contentsOf: service.fileURL), before)
        XCTAssertEqual(service.backups.count, 1, "nothing was backed up for a restore that didn't happen")
    }

    func testABackupIncludesAnEditStillWaitingToBeSaved() throws {
        let service = try makeService(groupName: "Saved")
        service.update { $0.groups[0].name = "Pending" }
        service.backUp()
        let backup = try JSONDecoder().decode(DockConfig.self, from: Data(contentsOf: XCTUnwrap(service.backups.first).url))
        XCTAssertEqual(backup.groups.first?.name, "Pending")
        XCTAssertEqual(try groupNameOnDisk(service), "Pending")
    }
}
