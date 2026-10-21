import Foundation
import XCTest
@testable import Kosmodock

/// File and sharing widgets: screenshot detection, recent files, the shelf,
/// collections, config decoding and `shortcuts list`. Files live in temp
/// directories; nothing runs a shortcut, opens a file or sends one.
final class FileWidgetTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("file-widgets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private func touch(_ name: String, in folder: URL? = nil) throws -> URL {
        let url = (folder ?? directory).appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    /// The marker `screencapture` leaves on its files.
    private func markAsScreenCapture(_ url: URL, _ value: Bool = true) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
        let result = data.withUnsafeBytes { bytes in
            setxattr(url.path, ScreenshotDetector.metadataAttribute, bytes.baseAddress, data.count, 0, 0)
        }
        XCTAssertEqual(result, 0, "setxattr failed")
    }

    // MARK: Screenshots

    func testScreenshotNamesInEveryLanguage() {
        for name in [
            "Screenshot 2026-10-21 at 09.41.00", "Screen Shot 2019-05-02 at 10.00.00", "screenshot",
            "Captura de Tela 2026-10-21 às 09.41.00", "Captura de pantalla 2026-10-21 a las 9.41.00",
            "Capture d’écran 2026-10-21 à 09.41.00", "Bildschirmfoto 2026-10-21 um 09.41.00",
            "スクリーンショット 2026-10-21 9.41.00", "CleanShot 2026-10-21 at 09.41.00@2x", "Screenshot_2026",
        ] {
            XCTAssertTrue(ScreenshotDetector.looksLikeScreenshot(name: name), name)
        }
        // Decomposed accents, as HFS+ stores them, still match.
        XCTAssertTrue(ScreenshotDetector.looksLikeScreenshot(name: "Capture d’écran 1".decomposedStringWithCanonicalMapping))
        for name in ["Screenshots guide", "IMG_0042", "My Screenshot 1", "Screenshotting tips", ""] {
            XCTAssertFalse(ScreenshotDetector.looksLikeScreenshot(name: name), name)
        }
        // `defaults write com.apple.screencapture name Shot`
        XCTAssertTrue(ScreenshotDetector.looksLikeScreenshot(name: "Shot 2026-10-21 at 09.41.00", customPrefix: "Shot"))
        XCTAssertFalse(ScreenshotDetector.looksLikeScreenshot(name: "Shot 2026-10-21 at 09.41.00", customPrefix: " "))
    }

    func testScreenshotsAreFoundByNameOrMetadata() throws {
        let named = try touch("Screenshot 2026-10-21 at 09.41.00.png")
        let marked = try touch("IMG_0042.png")
        try markAsScreenCapture(marked)
        let unmarked = try touch("IMG_0043.png")
        let markedFalse = try touch("IMG_0044.jpg")
        try markAsScreenCapture(markedFalse, false)
        let text = try touch("Screenshot notes.txt")
        let custom = try touch("Shot 1.heic")

        XCTAssertTrue(ScreenshotDetector.isScreenCapture(marked))
        XCTAssertFalse(ScreenshotDetector.isScreenCapture(unmarked))
        XCTAssertFalse(ScreenshotDetector.isScreenCapture(markedFalse))
        XCTAssertTrue(ScreenshotDetector.isScreenshot(named))
        XCTAssertTrue(ScreenshotDetector.isScreenshot(marked), "no screenshot name, but the marker")
        XCTAssertFalse(ScreenshotDetector.isScreenshot(unmarked))
        XCTAssertFalse(ScreenshotDetector.isScreenshot(text), "not an image")
        XCTAssertFalse(ScreenshotDetector.isScreenshot(custom))
        XCTAssertTrue(ScreenshotDetector.isScreenshot(custom, customPrefix: "Shot"))

        let found = RecentFiles.entries(in: directory, limit: 60) { ScreenshotDetector.isScreenshot($0) }
        XCTAssertEqual(Set(found.map(\.name)), ["Screenshot 2026-10-21 at 09.41.00.png", "IMG_0042.png"])
    }

    func testScreenshotFolderFollowsThePreference() throws {
        let home = directory!
        let shots = home.appendingPathComponent("Pictures/Shots", isDirectory: true)
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let exists: (URL) -> Bool = { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
        XCTAssertEqual(ScreenshotDetector.folder(preference: "~/Pictures/Shots", home: home, isDirectory: exists).path, shots.path)
        XCTAssertEqual(ScreenshotDetector.folder(preference: shots.path + "/", home: home, isDirectory: exists).path, shots.path)
        XCTAssertEqual(ScreenshotDetector.folder(preference: "~/Gone", home: home, isDirectory: exists), desktop, "a deleted folder falls back")
        XCTAssertEqual(ScreenshotDetector.folder(preference: nil, home: home, isDirectory: exists), desktop)
        XCTAssertEqual(ScreenshotDetector.folder(preference: "  ", home: home, isDirectory: exists), desktop)
    }

    // MARK: Recent files

    func testRecentFilesAreNewestFirstAndCountNewOnes() throws {
        let base = Date(timeIntervalSince1970: 2_000_000_000)
        func entry(_ name: String, _ offset: TimeInterval) -> FileEntry {
            FileEntry(url: URL(fileURLWithPath: "/tmp/\(name)"), date: base.addingTimeInterval(offset), isDirectory: false)
        }
        let entries = [entry("old.pdf", -3600), entry("b.zip", 60), entry("a.zip", 60), entry("newest.dmg", 600)]
        XCTAssertEqual(RecentFiles.sorted(entries).map(\.name), ["newest.dmg", "a.zip", "b.zip", "old.pdf"], "same second: by name")
        XCTAssertEqual(RecentFiles.newCount(entries, since: base), 3)
        XCTAssertEqual(RecentFiles.newCount(entries, since: base.addingTimeInterval(60)), 1, "only later than the last look")
        XCTAssertEqual(RecentFiles.newCount(entries, since: nil), 0, "nothing is new before the first look")

        for name in ["report.pdf", "photo.jpg", "movie.mov.crdownload", "setup.dmg.download", ".DS_Store"] {
            try touch(name)
        }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Unzipped"), withIntermediateDirectories: true)
        let listed = RecentFiles.entries(in: directory, limit: 60)
        XCTAssertEqual(Set(listed.map(\.name)), ["report.pdf", "photo.jpg", "Unzipped"], "no partial downloads or hidden files")
        XCTAssertEqual(listed.first { $0.name == "Unzipped" }?.isDirectory, true)
        XCTAssertEqual(RecentFiles.entries(in: directory, limit: 2).count, 2)
        XCTAssertEqual(RecentFiles.entries(in: directory.appendingPathComponent("missing"), limit: 10), [])
    }

    func testFileTileOptions() {
        var tile = DockTile(id: "files", kind: .files)
        XCTAssertEqual(tile.shownFileCount, DockTile.defaultFileCount)
        tile.fileCount = 2
        XCTAssertEqual(tile.shownFileCount, 6)
        tile.fileCount = 500
        XCTAssertEqual(tile.shownFileCount, 60)
        XCTAssertEqual(tile.folderURL.lastPathComponent, "Downloads")
        tile.filesFolder = "~/Documents/Invoices"
        XCTAssertEqual(tile.folderURL.path, NSHomeDirectory() + "/Documents/Invoices")
        tile.fileAction = .copy
        XCTAssertEqual(tile.clickAction, .open, "copying images is for screenshots")
        tile.kind = .screenshots
        XCTAssertEqual(tile.clickAction, .copy)
    }

    // MARK: Shelf

    func testShelfKeepsFortyFilesWithoutRepeats() {
        let existing = (1...40).map { "/Users/me/file\($0).txt" }
        let added = Shelf.adding(["/Users/me/new.txt", "/Users/me/./file3.txt", "/Users/me/new.txt/"], to: existing)
        XCTAssertEqual(added.count, 40)
        XCTAssertEqual(added.prefix(2), ["/Users/me/new.txt", "/Users/me/file3.txt"], "dropped files come first, once")
        XCTAssertEqual(added.filter { $0 == "/Users/me/file3.txt" }.count, 1)
        XCTAssertFalse(added.contains("/Users/me/file40.txt"), "the oldest falls off")
        XCTAssertEqual(Shelf.adding(["", "  "], to: []), [])
        XCTAssertEqual(Shelf.removing(["/Users/me/./new.txt"], from: added).count, 39)

        let many = (1...60).map { "/tmp/\($0)" }
        XCTAssertEqual(Shelf.adding(many, to: []).count, DockTile.shelfLimit)
    }

    func testDroppedFilesGoToTheShelfOnTheBar() {
        var config = DockConfig()
        let first = config.addToShelf(["/tmp/a.txt"])
        XCTAssertEqual(first, "shelf", "without a shelf, one is added")
        XCTAssertEqual(config.tiles.map(\.kind), [.shelf])
        XCTAssertEqual(config.barOrder, ["tile:shelf"])
        config.addToShelf(["/tmp/b.txt", "/tmp/a.txt"])
        XCTAssertEqual(config.tiles.count, 1)
        XCTAssertEqual(config.tiles[0].shelfItems, ["/tmp/b.txt", "/tmp/a.txt"])

        // With workspaces, the shelf on the active bar wins over the first one.
        config.tiles.append(DockTile(id: "shelf-2", kind: .shelf))
        config.workspaces = [
            Workspace(id: "home", name: "Home", items: ["tile:shelf"]),
            Workspace(id: "work", name: "Work", items: ["tile:shelf-2"]),
        ]
        config.activeWorkspaceID = "work"
        XCTAssertEqual(config.dropShelfTileID, "shelf-2")
        config.addToShelf(["/tmp/c.txt"])
        XCTAssertEqual(config.tiles.first { $0.id == "shelf-2" }?.shelfItems, ["/tmp/c.txt"])
        config.addToShelf(["/tmp/d.txt"], tileID: "shelf")
        XCTAssertEqual(config.tiles[0].shelfItems?.first, "/tmp/d.txt", "a drop on a tile goes to that tile")
    }

    // MARK: App collections

    func testCreateCollectionTakesThePinnedAppsPlace() {
        let finder = DockApp(name: "Finder", bundleId: "com.apple.finder")
        let safari = DockApp(name: "Safari", bundleId: "com.apple.Safari")
        var config = DockConfig()
        config.pinnedApps = [finder, safari]
        config.groups = [DockGroup(id: "work", name: "Work")]
        config.tiles = [DockTile(id: "appCollection", kind: .appCollection)]
        config.order = ["app:com.apple.Safari", "work", "app:com.apple.finder"]

        let id = config.makeCollection(from: safari)
        XCTAssertEqual(id, "appCollection-2", "ids stay unique")
        XCTAssertEqual(config.pinnedApps, [finder])
        XCTAssertEqual(config.tiles.last?.collectionApps, [safari])
        XCTAssertEqual(config.tiles.last?.width, .square)
        XCTAssertEqual(config.barOrder, ["tile:appCollection-2", "work", "app:com.apple.finder", "tile:appCollection"])

        // Every workspace that had the app gets the collection in its place.
        config.workspaces = [
            Workspace(id: "a", name: "A", items: ["app:com.apple.finder", "work"]),
            Workspace(id: "b", name: "B", items: ["work"]),
        ]
        config.activeWorkspaceID = "a"
        let second = config.makeCollection(from: finder)
        XCTAssertEqual(config.workspaces[0].items, ["tile:\(second)", "work"])
        XCTAssertEqual(config.workspaces[1].items, ["work"])
        XCTAssertTrue(config.pinnedApps.isEmpty)
    }

    // MARK: Config

    func testOldConfigsDecodeWithTheDefaults() throws {
        let old = #"{ "tiles": [ { "id": "clock", "kind": "clock" } ], "behavior": { "focusMode": true } }"#
        let config = try JSONDecoder().decode(DockConfig.self, from: Data(old.utf8))
        let tile = try XCTUnwrap(config.tiles.first)
        XCTAssertNil(tile.fileCount)
        XCTAssertNil(tile.shelfItems)
        XCTAssertNil(tile.bookmarks)
        XCTAssertNil(tile.collectionApps)
        XCTAssertNil(tile.shortcutName)
        XCTAssertFalse(config.behavior.dropZone, "off by default")
        XCTAssertEqual(config.behavior.dropZonePlacement, .bottomLeft)

        // A tile with every option survives a round trip and writes no empty keys for others.
        var full = DockTile(id: "s", kind: .shortcut)
        full.shortcutName = "Morning"
        full.shortcutSymbol = "sun.max.fill"
        full.shortcutTintHex = "#FF9F0A"
        full.bookmarks = [Bookmark(title: "Docs", url: "example.com")]
        full.collectionApps = [DockApp(name: "Notes", bundleId: "com.apple.Notes")]
        full.collectionLayout = .vertical
        full.fileAction = .reveal
        full.removesOnDragOut = true
        let data = try JSONEncoder().encode(full)
        XCTAssertEqual(try JSONDecoder().decode(DockTile.self, from: data), full)
        let clock = String(decoding: try JSONEncoder().encode(DockTile(id: "c", kind: .clock)), as: UTF8.self)
        XCTAssertFalse(clock.contains("shelfItems") || clock.contains("bookmarks"), clock)

        let newKinds = #"[{"kind":"screenshots"},{"kind":"shelf"},{"kind":"files"},{"kind":"bookmarks","bookmarks":[{"url":"a.com"}]},{"kind":"appCollection"},{"kind":"shortcut"},{"kind":"airDrop"}]"#
        let tiles = try JSONDecoder().decode([DockTile].self, from: Data(newKinds.utf8))
        XCTAssertEqual(tiles.map(\.kind), [.screenshots, .shelf, .files, .bookmarks, .appCollection, .shortcut, .airDrop])
        XCTAssertEqual(tiles[3].bookmarks, [Bookmark(title: "", url: "a.com")], "a bookmark without a title")
        XCTAssertThrowsError(try JSONDecoder().decode(DockTile.self, from: Data(#"{"kind":"files","fileAction":"delete"}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(BehaviorConfig.self, from: Data(#"{"dropZonePlacement":"top"}"#.utf8)))
    }

    func testBookmarkAddresses() {
        XCTAssertEqual(Bookmark.url(from: "example.com/docs")?.absoluteString, "https://example.com/docs")
        XCTAssertEqual(Bookmark.url(from: " http://intranet.local ")?.absoluteString, "http://intranet.local")
        XCTAssertEqual(Bookmark.url(from: "localhost:3000")?.absoluteString, "https://localhost:3000")
        XCTAssertEqual(Bookmark.url(from: "mailto:team@example.com")?.scheme, "mailto")
        XCTAssertNil(Bookmark.url(from: ""))
        XCTAssertNil(Bookmark.url(from: "two words"))
        XCTAssertEqual(Bookmark(title: "", url: "github.com/kosmodock").displayTitle, "github.com")
        XCTAssertEqual(Bookmark(title: "Repo", url: "github.com").displayTitle, "Repo")
    }

    // MARK: Shortcuts

    func testShortcutsListParsing() {
        let output = "Morning Routine\n  Send ETA  \n\nMorning Routine\r\nalpha\nZeta (work)\nShortcut 10\nShortcut 9\n"
        XCTAssertEqual(ShortcutsRunner.parseList(output), ["alpha", "Morning Routine", "Send ETA", "Shortcut 9", "Shortcut 10", "Zeta (work)"])
        XCTAssertEqual(ShortcutsRunner.parseList(""), [])
        XCTAssertEqual(ShortcutsRunner.parseList("\n \n"), [])

        let notFound = ShellResult(exitCode: 1, stdout: "", stderr: "\nError: The operation couldn’t be completed. (WFBackgroundShortcutRunnerError error 1.)\n")
        XCTAssertEqual(ShortcutsRunner.failure(from: notFound), "Error: The operation couldn’t be completed. (WFBackgroundShortcutRunnerError error 1.)")
        XCTAssertEqual(ShortcutsRunner.failure(from: ShellResult(exitCode: 127, stdout: "", stderr: "")), L10n.tr("The shortcuts command isn't available."))
        XCTAssertEqual(ShortcutsRunner.failure(from: ShellResult(exitCode: 1, stdout: "", stderr: "")), L10n.tr("The shortcut stopped with an error."))
    }
}
