import Foundation

// Options and pure logic of the file and sharing widgets: screenshots, shelf,
// recent files, bookmarks, app collection, shortcut and AirDrop. Their data
// comes from Services/FileWidgetServices.swift.

/// What clicking a file in the screenshots or files widget does.
enum FileClickAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case open
    case reveal
    /// The image goes to the clipboard (screenshots only).
    case copy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .open: L10n.tr("Open")
        case .reveal: L10n.tr("Show in Finder")
        case .copy: L10n.tr("Copy Image")
        }
    }
}

/// How an app collection's details arrange its apps.
enum CollectionLayout: String, Codable, CaseIterable, Identifiable, Sendable {
    case grid
    case horizontal
    case vertical

    var id: String { rawValue }

    var title: String {
        switch self {
        case .grid: L10n.tr("Grid")
        case .horizontal: L10n.tr("Row")
        case .vertical: L10n.tr("List")
        }
    }
}

/// Where the Drop Zone's tray appears while files are dragged.
enum DropZonePlacement: String, Codable, CaseIterable, Identifiable, Sendable {
    case bottomLeft
    case nearPointer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bottomLeft: L10n.tr("Bottom left")
        case .nearPointer: L10n.tr("Near the pointer")
        }
    }
}

struct Bookmark: Codable, Equatable, Hashable, Sendable {
    var title: String
    /// As typed; `https://` is assumed when it has no scheme.
    var url: String

    var resolvedURL: URL? { Self.url(from: url) }

    /// The title, or the address's host when it has none.
    var displayTitle: String {
        if !title.isBlank { return title }
        return resolvedURL?.host() ?? url
    }

    /// "example.com/docs" opens as "https://example.com/docs"; "mailto:…" and
    /// "http://…" stay as they are.
    static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        // A scheme, unless what follows the colon is a port ("localhost:3000").
        if let colon = trimmed.firstIndex(of: ":"),
           trimmed[..<colon].range(of: "^[A-Za-z][A-Za-z0-9+.-]*$", options: .regularExpression) != nil,
           !(trimmed[trimmed.index(after: colon)...].first?.isNumber ?? false) {
            return URL(string: trimmed)
        }
        return URL(string: "https://" + trimmed)
    }
}

extension Bookmark {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(.title, or: "")
        url = try c.decode(.url, or: "")
    }
}

// MARK: - Tile options

extension DockTile {
    static let fileCountRange = 6...60
    static let defaultFileCount = 12
    /// Files a shelf holds; the oldest leave first.
    static let shelfLimit = 40

    /// Screenshots and files: how many the details show.
    var shownFileCount: Int {
        min(max(fileCount ?? Self.defaultFileCount, Self.fileCountRange.lowerBound), Self.fileCountRange.upperBound)
    }

    /// Copying an image only applies to screenshots.
    var clickAction: FileClickAction {
        let action = fileAction ?? .open
        return action == .copy && kind != .screenshots ? .open : action
    }

    /// The files widget's folder, Downloads by default.
    var folderURL: URL {
        if let folder = filesFolder, !folder.isBlank {
            return URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }

    var shelfURLs: [URL] { (shelfItems ?? []).map { URL(fileURLWithPath: $0) } }
}

enum Shelf {
    /// `added` first, in that order, then the rest of `existing`, without
    /// repeats and at most `limit`: the oldest files fall off the end.
    static func adding(_ added: [String], to existing: [String], limit: Int = DockTile.shelfLimit) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for path in added + existing {
            let key = normalized(path)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            result.append(key)
        }
        return Array(result.prefix(max(0, limit)))
    }

    static func removing(_ removed: [String], from existing: [String]) -> [String] {
        let gone = Set(removed.map(normalized))
        return existing.filter { !gone.contains(normalized($0)) }
    }

    /// One spelling per file: "/a/./b/" and "/a/b" are the same.
    static func normalized(_ path: String) -> String {
        guard !path.isBlank else { return "" }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }
}

// MARK: - Config edits

extension DockConfig {
    /// The shelf files dropped on the Drop Zone go to: the first one on the
    /// bar, then the first one anywhere.
    var dropShelfTileID: String? {
        let shelves = tiles.filter { $0.kind == .shelf }
        let shown = Set(barOrder)
        return (shelves.first { shown.contains(Self.itemID(for: $0)) } ?? shelves.first)?.id
    }

    /// Parks files on a shelf: `tileID`'s, or the Drop Zone's. Without any
    /// shelf, one is added to the bar. Returns the shelf's id.
    @discardableResult
    mutating func addToShelf(_ paths: [String], tileID: String? = nil) -> String {
        if let id = tileID ?? dropShelfTileID, let index = tiles.firstIndex(where: { $0.id == id && $0.kind == .shelf }) {
            tiles[index].shelfItems = Shelf.adding(paths, to: tiles[index].shelfItems ?? [])
            return id
        }
        var shelf = DockTile(id: TileKind.shelf.rawValue, kind: .shelf)
        shelf.shelfItems = Shelf.adding(paths, to: [])
        var id = shelf.id
        addToBar { config in
            config.tiles = DockConfig.normalizedTileIDs(config.tiles + [shelf])
            id = config.tiles.last?.id ?? shelf.id
        }
        return id
    }

    /// Turns a pinned app into a collection holding it, in the app's place on
    /// every bar that has it. Returns the collection's id.
    @discardableResult
    mutating func makeCollection(from app: DockApp) -> String {
        settleOrder()
        let appItem = Self.itemID(forPinned: app)
        var collection = DockTile(id: TileKind.appCollection.rawValue, kind: .appCollection, width: .square)
        collection.collectionApps = [app]
        tiles = Self.normalizedTileIDs(tiles + [collection])
        let tile = tiles[tiles.count - 1]
        let tileItem = Self.itemID(for: tile)
        let replace: ([String]) -> [String] = { ids in ids.map { $0 == appItem ? tileItem : $0 } }
        order = replace(order)
        for index in workspaces.indices { workspaces[index].items = replace(workspaces[index].items) }
        if !barOrder.contains(tileItem) { showInActiveWorkspace(tileItem) }
        pinnedApps.removeAll { $0.id == app.id }
        return tile.id
    }
}
