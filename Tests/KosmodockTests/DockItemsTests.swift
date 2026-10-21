import AppKit
import SwiftUI
import XCTest
@testable import Kosmodock

/// Folder stacks, the Trash, spacers and undoing the last bar edit.
final class DockItemsConfigTests: XCTestCase {
    private func decode(_ json: String) throws -> DockConfig {
        try JSONDecoder().decode(DockConfig.self, from: Data(json.utf8))
    }

    func testOldConfigDecodesWithoutDockItemsAndKeepsItsBar() throws {
        let json = #"""
        { "groups": [ { "id": "code", "name": "Code" } ],
          "pinnedApps": [ { "bundleId": "com.apple.finder" } ],
          "tiles": [ { "kind": "clock" } ],
          "order": ["tile:clock"] }
        """#
        let decoded = try decode(json)
        XCTAssertEqual(decoded.folders, [])
        XCTAssertEqual(decoded.spacers, [])
        XCTAssertFalse(decoded.showsTrash)
        XCTAssertEqual(decoded.barOrder, ["tile:clock", "app:com.apple.finder", "code"])
        XCTAssertEqual(try JSONDecoder().decode(DockConfig.self, from: JSONEncoder().encode(decoded)), decoded)
    }

    func testFoldersAndSpacersDecodeLeniently() throws {
        let json = #"""
        { "folders": [ { "preset": "downloads" }, { "path": "~/Projects/Client Work" }, { "path": "/tmp", "id": "x", "layout": "list", "sort": "kind", "name": "Temp" }, { "path": "/Volumes/Projects" } ],
          "spacers": [ { }, { "size": "flexible" }, { "id": "small" } ],
          "showsTrash": true }
        """#
        let decoded = try decode(json)
        XCTAssertEqual(decoded.folders.map(\.id), ["downloads", "client-work", "x", "projects"])
        let downloads = decoded.folders[0]
        XCTAssertEqual(downloads.path, "~/Downloads", "the preset knows its path")
        XCTAssertEqual(downloads.sort, .dateAdded, "Downloads lists the newest first")
        XCTAssertTrue(downloads.isDownloads)
        XCTAssertEqual(decoded.folders[1].sort, .name)
        XCTAssertEqual(decoded.folders[1].layout, .grid)
        XCTAssertEqual(decoded.folders[2].layout, .list)
        XCTAssertEqual(decoded.folders[2].displayName, "Temp")
        XCTAssertEqual(decoded.spacers.map(\.id), ["small", "flexible", "small-2"], "ids are unique, from the size when missing")
        XCTAssertEqual(decoded.spacers.map(\.size), [.small, .flexible, .small])
        XCTAssertTrue(decoded.showsTrash)
        XCTAssertEqual(try JSONDecoder().decode(DockConfig.self, from: JSONEncoder().encode(decoded)), decoded)
    }

    func testBrokenDockItemsAreReported() {
        XCTAssertThrowsError(try decode(#"{ "folders": [ { "name": "No path" } ] }"#), "a folder needs a path")
        XCTAssertThrowsError(try decode(#"{ "folders": [ { "path": "/tmp", "layout": "carousel" } ] }"#))
        XCTAssertThrowsError(try decode(#"{ "spacers": [ { "size": "huge" } ] }"#))
        XCTAssertThrowsError(try decode(#"{ "showsTrash": "yes" }"#))
    }

    func testChosenFoldersKeepTheHomeFolderShort() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folder = DockFolder(chosen: home.appendingPathComponent("Projects", isDirectory: true))
        XCTAssertEqual(folder.path, "~/Projects")
        XCTAssertNil(folder.preset)
        let downloads = DockFolder(chosen: home.appendingPathComponent("Downloads", isDirectory: true))
        XCTAssertEqual(downloads, .downloads(), "choosing Downloads gives the preset")
        XCTAssertEqual(DockFolder(chosen: URL(fileURLWithPath: "/tmp/x")).path, "/tmp/x")
    }
}

final class DockItemsBarOrderTests: XCTestCase {
    private func config() -> DockConfig {
        var config = DockConfig()
        config.groups = [DockGroup(id: "code", name: "Code")]
        config.tiles = [DockTile(id: "clock", kind: .clock)]
        config.folders = [DockFolder(id: "projects", path: "/tmp/projects")]
        config.spacers = [DockSpacer(id: "gap", size: .large)]
        return config
    }

    func testFoldersAndSpacersFollowTheOtherItemsByDefault() {
        XCTAssertEqual(config().barOrder, ["code", "tile:clock", "folder:projects", "spacer:gap"])
    }

    func testOrderPlacesFoldersAndSpacersAnywhere() {
        var config = config()
        config.order = ["spacer:gap", "code", "folder:projects", "folder:gone", "trash"]
        XCTAssertEqual(config.barOrder, ["spacer:gap", "code", "folder:projects", "tile:clock"], "unknown ids are dropped")
    }

    func testTheTrashIsNeverInTheOrder() {
        var config = config()
        config.showsTrash = true
        config.order = [DockConfig.trashItemID, "code"]
        XCTAssertFalse(config.barOrder.contains(DockConfig.trashItemID))
        config.settleOrder()
        XCTAssertFalse(config.order.contains(DockConfig.trashItemID))
    }

    func testAddedFoldersLandAtTheEndOnce() {
        var config = config()
        config.order = ["folder:projects", "code"]
        config.addFolders([DockFolder(id: "", path: "/tmp/new"), DockFolder(id: "", path: "/tmp/projects"), DockFolder(id: "", path: "/tmp/new/")])
        XCTAssertEqual(config.folders.map(\.path), ["/tmp/projects", "/tmp/new"], "the same folder isn't added twice")
        XCTAssertEqual(config.barOrder, ["folder:projects", "code", "tile:clock", "spacer:gap", "folder:new"])
        config.addFolders([.downloads(), .downloads()])
        XCTAssertEqual(config.folders.filter(\.isDownloads).count, 1)
        XCTAssertEqual(config.barOrder.last, "folder:downloads")
    }

    func testNewItemsJoinOnlyTheActiveWorkspace() {
        var config = config()
        config.workspaces = [
            Workspace(id: "work", name: "Work", items: ["code"]),
            Workspace(id: "home", name: "Home", items: ["tile:clock"]),
        ]
        config.activeWorkspaceID = "work"
        config.addFolders([.downloads()])
        config.addToBar { $0.spacers = DockConfig.normalizedSpacerIDs($0.spacers + [DockSpacer(id: "", size: .flexible)]) }
        XCTAssertEqual(config.shownItemIDs(inWorkspace: "work"), ["code", "folder:downloads", "spacer:flexible"])
        XCTAssertEqual(config.shownItemIDs(inWorkspace: "home"), ["tile:clock"])
        // A folder already in Kosmodock comes to the active workspace instead.
        config.activeWorkspaceID = "home"
        config.addFolders([DockFolder(id: "", path: "/tmp/projects")])
        XCTAssertEqual(config.folders.count, 2)
        XCTAssertEqual(config.shownItemIDs(inWorkspace: "home"), ["tile:clock", "folder:projects"])
        config.removeFromBar("folder:downloads")
        XCTAssertFalse(config.workspaces.contains { $0.items.contains("folder:downloads") })
    }
}

/// A flexible spacer takes what the row has left, never what capsules need.
@MainActor
final class FlexibleSpacerTests: XCTestCase {
    func testFlexibleSpacerTakesTheFreeWidth() {
        let widths = CapsuleRow.widths(natural: [100, 20, 60], equalized: [true, false, true], flexible: [false, true, false], spacing: 0, maxWidth: 300)
        XCTAssertEqual(widths, [100, 100, 100], "capsules equalize first, the spacer takes the rest")
    }

    func testNoFreeWidthWhileCapsulesAreSqueezed() {
        let widths = CapsuleRow.widths(natural: [120, 60, 20], equalized: [true, true, false], flexible: [false, false, true], spacing: 0, maxWidth: 200)
        XCTAssertEqual(widths, [120, 60, 20])
    }

    func testFlexibleSpacersShareTheFreeWidthWithSpacing() {
        let widths = CapsuleRow.widths(natural: [10, 50, 10], equalized: [false, false, false], flexible: [true, false, true], spacing: 5, maxWidth: 111)
        XCTAssertEqual(widths, [25, 50, 25])
        XCTAssertLessThanOrEqual(widths.reduce(0, +) + 10, 111)
    }

    func testWithoutFlexibleSpacersNothingChanges() {
        XCTAssertEqual(CapsuleRow.widths(natural: [50, 20], equalized: [false, false], spacing: 10, maxWidth: 500), [50, 20])
        XCTAssertEqual(CapsuleRow.widths(natural: [50, 20], equalized: [true, true], flexible: [false, false], spacing: 0, maxWidth: 500), [50, 50])
    }

    /// The bar still fits its candidate: the spacer fills up to `maxWidth`, not past it.
    func testRowWithAFlexibleSpacerFillsItsMaxWidth() {
        let row = CapsuleRow(spacing: 4, maxWidth: 300) {
            Color.clear.frame(width: 60, height: 10)
            Color.clear.frame(minWidth: 20, idealWidth: 20, maxWidth: .infinity).frame(height: 10).layoutValue(key: FlexibleWidthKey.self, value: true)
            Color.clear.frame(width: 60, height: 10)
        }
        XCTAssertEqual(NSHostingView(rootView: row.fixedSize()).fittingSize.width, 300)
    }
}

final class FolderListingTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("kosmodock-folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func touch(_ name: String) throws {
        try Data("x".utf8).write(to: directory.appendingPathComponent(name))
    }

    func testHalfWrittenDownloadsAreSkipped() throws {
        for name in ["report.pdf", "movie.mp4.crdownload", "archive.zip.part", ".DS_Store", "Notes.TXT"] { try touch(name) }
        // Safari's in-progress download is a bundle.
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("song.mp3.download"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Photos"), withIntermediateDirectories: true)

        let downloads = try FolderListing.read(directory, skipsPartialDownloads: true)
        XCTAssertEqual(Set(downloads.map(\.url.lastPathComponent)), ["report.pdf", "Notes.TXT", "Photos"])
        XCTAssertEqual(downloads.first { $0.url.lastPathComponent == "Photos" }?.isFolder, true)
        XCTAssertEqual(downloads.first { $0.url.lastPathComponent == "report.pdf" }?.isFolder, false)

        let everything = try FolderListing.read(directory, skipsPartialDownloads: false)
        XCTAssertEqual(everything.count, 6, "other folders keep them; hidden files never show")
        XCTAssertTrue(FolderListing.isPartialDownload(URL(fileURLWithPath: "/x/a.PART")))
        XCTAssertFalse(FolderListing.isPartialDownload(URL(fileURLWithPath: "/x/part")))
    }

    func testAMissingFolderThrows() {
        XCTAssertThrowsError(try FolderListing.read(directory.appendingPathComponent("gone"), skipsPartialDownloads: false))
    }

    private func entry(_ name: String, kind: String = "Document", minutesAgo: Double = 0) -> FolderEntry {
        FolderEntry(url: URL(fileURLWithPath: "/x/\(name)"), name: name, kind: kind, dateAdded: Date(timeIntervalSinceReferenceDate: 1_000_000 - minutesAgo * 60))
    }

    func testSortingByNameKindAndDateAdded() {
        let entries = [
            entry("c10", kind: "PDF document", minutesAgo: 30),
            entry("b", kind: "Folder", minutesAgo: 5),
            entry("A", kind: "PDF document", minutesAgo: 1),
            entry("c9", kind: "Folder", minutesAgo: 5),
        ]
        XCTAssertEqual(FolderListing.sorted(entries, by: .name).map(\.name), ["A", "b", "c9", "c10"], "numbers sort as the Finder does")
        XCTAssertEqual(FolderListing.sorted(entries, by: .kind).map(\.name), ["b", "c9", "A", "c10"], "by kind, then name")
        XCTAssertEqual(FolderListing.sorted(entries, by: .dateAdded).map(\.name), ["A", "b", "c9", "c10"], "newest first, ties by name")
    }

    func testNewCountIsWhatArrivedSinceTheFolderWasSeen() {
        let entries = [entry("old", minutesAgo: 60), entry("new", minutesAgo: 2), entry("newer", minutesAgo: 1)]
        let seen = Date(timeIntervalSinceReferenceDate: 1_000_000 - 10 * 60)
        XCTAssertEqual(FolderListing.newCount(entries, since: seen), 2)
        XCTAssertEqual(FolderListing.newCount(entries, since: nil), 0, "nothing is new before the folder was ever seen")
        XCTAssertEqual(FolderListing.newCount(entries, since: .distantFuture), 0)
    }

    func testBadgeTextStaysShort() {
        XCTAssertEqual(FolderStackDockView.badgeText(7), "7")
        XCTAssertEqual(FolderStackDockView.badgeText(120), "99+")
    }

    func testTrashState() throws {
        XCTAssertEqual(TrashReader.state(of: directory), .empty)
        try touch(".DS_Store")
        XCTAssertEqual(TrashReader.state(of: directory), .empty, "the Finder's own files don't fill it")
        try touch(".hidden-but-trashed")
        XCTAssertEqual(TrashReader.state(of: directory), .full)
        XCTAssertEqual(TrashReader.state(of: directory.appendingPathComponent("gone")), .unreadable)
    }
}

/// The service end to end, on a temporary folder.
@MainActor
final class FolderStackServiceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("kosmodock-stack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func waitUntil(_ condition: () -> Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out: \(message)", file: file, line: line) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testDownloadsCountsNewFilesUntilItsPopoverOpens() async throws {
        try Data("x".utf8).write(to: directory.appendingPathComponent("old.pdf"))
        let seen = FolderSeenStore(defaults: nil)
        let service = FolderStackService(seen: seen)
        let folder = DockFolder(id: "downloads", path: directory.path, preset: .downloads)
        service.update(folders: [folder])
        try await waitUntil({ service.stack(for: "downloads").isLoaded }, "first read")
        XCTAssertEqual(service.stack(for: "downloads").entries.count, 1)
        XCTAssertEqual(service.newCount(for: "downloads"), 0, "files already there aren't new")
        XCTAssertNotNil(seen.date(for: "downloads"))

        // Everything since long ago counts, except a download still coming in.
        seen.markSeen("downloads", at: .distantPast)
        try Data("x".utf8).write(to: directory.appendingPathComponent("new.zip"))
        try Data("x".utf8).write(to: directory.appendingPathComponent("big.iso.crdownload"))
        service.reload("downloads")
        try await waitUntil({ service.newCount(for: "downloads") == 2 }, "new files counted")
        XCTAssertEqual(service.stack(for: "downloads").entries.count, 2)

        service.didOpen("downloads")
        XCTAssertEqual(service.newCount(for: "downloads"), 0)
        XCTAssertGreaterThan(seen.date(for: "downloads") ?? .distantPast, Date().addingTimeInterval(-60))
        service.stopAll()
    }

    func testOtherFoldersCountNothingAndUnreadableOnesSaySo() async throws {
        let service = FolderStackService(seen: FolderSeenStore(defaults: nil))
        let plain = DockFolder(id: "plain", path: directory.path)
        let missing = DockFolder(id: "missing", path: directory.appendingPathComponent("gone").path)
        try Data("x".utf8).write(to: directory.appendingPathComponent("a.part"))
        service.update(folders: [plain, missing])
        try await waitUntil({ service.stack(for: "plain").isLoaded && service.stack(for: "missing").isLoaded }, "both read")
        XCTAssertEqual(service.stack(for: "plain").entries.map(\.url.lastPathComponent), ["a.part"])
        XCTAssertEqual(service.newCount(for: "plain"), 0)
        XCTAssertFalse(service.stack(for: "missing").isReadable)
        service.update(folders: [plain])
        XCTAssertFalse(service.stack(for: "missing").isLoaded, "a removed folder is forgotten")
        service.stopAll()
    }
}

final class DockBarUndoTests: XCTestCase {
    private func config() -> DockConfig {
        var config = DockConfig()
        config.groups = [DockGroup(id: "code", name: "Code")]
        config.tiles = [DockTile(id: "clock", kind: .clock)]
        config.pinnedApps = [DockApp(name: "Finder", bundleId: "com.apple.finder")]
        return config
    }

    private func edit(_ config: inout DockConfig, _ undo: inout DockBarUndo, _ change: (inout DockConfig) -> Void) {
        let before = config
        change(&config)
        undo.record(before: before, after: config)
    }

    func testUndoBringsBackARemovedItemInItsPlace() throws {
        var config = config()
        var undo = DockBarUndo()
        XCTAssertFalse(undo.canUndo(config))
        let original = config.barOrder
        edit(&config, &undo) { config in
            config.removeFromBar("tile:clock")
            config.tiles = []
        }
        XCTAssertTrue(undo.canUndo(config))
        let restored = try XCTUnwrap(undo.undone(config))
        XCTAssertEqual(restored.tiles, [DockTile(id: "clock", kind: .clock)])
        XCTAssertEqual(restored.barOrder, original)
    }

    func testUndoKeepsLaterEditsToOtherParts() throws {
        var config = config()
        var undo = DockBarUndo()
        edit(&config, &undo) { $0.moveBarItem("code", by: 1) }
        // Renaming a group isn't a bar edit, and doesn't touch what the move changed.
        config.groups[0].name = "Coding"
        config.theme.iconSize = 40
        let restored = try XCTUnwrap(undo.undone(config))
        XCTAssertEqual(restored.groups[0].name, "Coding")
        XCTAssertEqual(restored.theme.iconSize, 40)
        XCTAssertEqual(restored.barOrder, ["app:com.apple.finder", "code", "tile:clock"])
    }

    func testALaterChangeToTheSamePartCancelsTheUndo() {
        var config = config()
        var undo = DockBarUndo()
        edit(&config, &undo) { $0.tiles.append(DockTile(id: "battery", kind: .battery)) }
        config.tiles[0].width = .square
        XCTAssertFalse(undo.canUndo(config), "undoing would lose the size change")
        XCTAssertNil(undo.undone(config))
    }

    func testOnlyOneLevelAndNoOpEditsKeepIt() throws {
        var config = config()
        var undo = DockBarUndo()
        edit(&config, &undo) { $0.showsTrash = true }
        edit(&config, &undo) { $0.addFolders([.downloads()]) }
        edit(&config, &undo) { _ in }
        let restored = try XCTUnwrap(undo.undone(config))
        XCTAssertEqual(restored.folders, [], "the last edit is undone")
        XCTAssertTrue(restored.showsTrash, "the one before stays")
        XCTAssertEqual(undo.changedParts, [.folders, .order])
    }

    func testWorkspaceItemChangesUndo() throws {
        var config = config()
        var undo = DockBarUndo()
        config.addWorkspace(name: "Main")
        config.addWorkspace(name: "Other")
        edit(&config, &undo) { $0.setItem("code", included: false, inWorkspace: "main") }
        XCTAssertEqual(config.shownItemIDs(inWorkspace: "main"), ["app:com.apple.finder", "tile:clock"])
        let restored = try XCTUnwrap(undo.undone(config))
        XCTAssertEqual(restored.shownItemIDs(inWorkspace: "main"), ["app:com.apple.finder", "code", "tile:clock"])

        edit(&config, &undo) { $0.useSingleDock() }
        XCTAssertEqual(config.workspaces, [])
        let back = try XCTUnwrap(undo.undone(config))
        XCTAssertEqual(back.workspaces.map(\.id), ["main", "other"])
        XCTAssertEqual(back.activeWorkspaceID, "main")
    }
}
