import Foundation

// MARK: - Folder stacks

/// How a folder's popover lists what's in it.
enum FolderLayout: String, Codable, CaseIterable, Identifiable, Sendable {
    case grid
    case list

    var id: String { rawValue }

    var title: String {
        switch self {
        case .grid: L10n.tr("Grid")
        case .list: L10n.tr("List")
        }
    }

    var symbol: String {
        switch self {
        case .grid: "square.grid.3x2"
        case .list: "list.bullet"
        }
    }
}

enum FolderSort: String, Codable, CaseIterable, Identifiable, Sendable {
    case name
    case kind
    /// Newest first.
    case dateAdded

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: L10n.tr("Name")
        case .kind: L10n.tr("Kind")
        case .dateAdded: L10n.tr("Date Added")
        }
    }
}

/// Folders Kosmodock knows. Downloads skips half-written downloads and counts
/// the files added since its popover was last opened.
enum FolderPreset: String, Codable, Sendable {
    case downloads
}

/// A folder on the bar, drawn like a pinned app; clicking it lists its contents.
struct DockFolder: Codable, Equatable, Identifiable, Sendable {
    var id: String
    /// May start with `~`.
    var path: String
    /// Shown instead of the folder's own name when set.
    var name: String?
    var preset: FolderPreset?
    var layout: FolderLayout = .grid
    var sort: FolderSort = .name

    var url: URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    var isDownloads: Bool { preset == .downloads }

    var displayName: String {
        if let name, !name.isBlank { return name }
        if isDownloads { return L10n.tr("Downloads") }
        return FileManager.default.displayName(atPath: url.path)
    }

    static let downloadsPath = "~/Downloads"

    static func downloads() -> DockFolder {
        DockFolder(id: FolderPreset.downloads.rawValue, path: downloadsPath, preset: .downloads, sort: .dateAdded)
    }
}

extension DockFolder {
    /// A folder chosen in an Open panel, saved with `~` for the home folder.
    /// Choosing Downloads gives the preset.
    init(chosen url: URL) {
        let path = (url.standardizedFileURL.path as NSString).abbreviatingWithTildeInPath
        self = DockFolder(id: "", path: path)
        if isSameFolder(as: .downloads()) {
            self = .downloads()
        }
    }

    func isSameFolder(as other: DockFolder) -> Bool {
        (isDownloads && other.isDownloads) || url.standardizedFileURL.path == other.url.standardizedFileURL.path
    }
}

// MARK: - Spacers

enum SpacerSize: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Half an icon.
    case small
    /// A whole icon.
    case large
    /// At least a small one; takes the bar's free width (`CapsuleRow`).
    case flexible

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: L10n.tr("Small Spacer")
        case .large: L10n.tr("Large Spacer")
        case .flexible: L10n.tr("Flexible Spacer")
        }
    }

    var symbol: String {
        switch self {
        case .small: "space"
        case .large: "rectangle.dashed"
        case .flexible: "arrow.left.and.right"
        }
    }
}

/// Empty room between two bar items.
struct DockSpacer: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var size: SpacerSize = .small
}

/// Bar items that aren't groups, pinned apps or tiles.
enum BarExtra: Identifiable {
    case folder(DockFolder)
    /// Always the last item: it's not in `DockConfig.order`.
    case trash
    case spacer(DockSpacer)

    var id: String {
        switch self {
        case .folder(let folder): DockConfig.itemID(for: folder)
        case .trash: DockConfig.trashItemID
        case .spacer(let spacer): DockConfig.itemID(for: spacer)
        }
    }
}

extension DockConfig {
    static func itemID(for folder: DockFolder) -> String { "folder:\(folder.id)" }
    static func itemID(for spacer: DockSpacer) -> String { "spacer:\(spacer.id)" }
    /// Never saved: the Trash closes the bar, as in the macOS Dock. The colon
    /// keeps it apart from group ids, which are slugs.
    static let trashItemID = "kosmodock:trash"

    /// Puts folders on the bar, at the end. A folder that's already there
    /// keeps its place, and joins the active workspace if it wasn't in it.
    mutating func addFolders(_ candidates: [DockFolder]) {
        var adding: [DockFolder] = []
        for folder in candidates {
            if let existing = folders.first(where: { $0.isSameFolder(as: folder) }) {
                showInActiveWorkspace(Self.itemID(for: existing))
            } else if !adding.contains(where: { $0.isSameFolder(as: folder) }) {
                adding.append(folder)
            }
        }
        guard !adding.isEmpty else { return }
        addToBar { $0.folders = DockConfig.normalizedFolderIDs($0.folders + adding) }
    }

    /// Unique folder ids, from the preset or the folder's name when missing.
    static func normalizedFolderIDs(_ folders: [DockFolder]) -> [DockFolder] {
        uniqueIDs(folders, id: \.id) { folder in
            folder.preset?.rawValue ?? slug((folder.path as NSString).lastPathComponent)
        }
    }

    /// Unique spacer ids, from the size when missing.
    static func normalizedSpacerIDs(_ spacers: [DockSpacer]) -> [DockSpacer] {
        uniqueIDs(spacers, id: \.id) { $0.size.rawValue }
    }

    private static func uniqueIDs<Item>(_ items: [Item], id: WritableKeyPath<Item, String>, fallback: (Item) -> String) -> [Item] {
        var seen = Set<String>()
        return items.map { item in
            var item = item
            var base = item[keyPath: id].trimmingCharacters(in: .whitespacesAndNewlines)
            if base.isEmpty { base = fallback(item) }
            var candidate = base
            var suffix = 2
            while seen.contains(candidate) {
                candidate = "\(base)-\(suffix)"
                suffix += 1
            }
            seen.insert(candidate)
            item[keyPath: id] = candidate
            return item
        }
    }
}

extension DockFolder {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(.id, or: "")
        preset = try c.decodeIfPresent(FolderPreset.self, forKey: .preset)
        if let path = try c.decodeIfPresent(String.self, forKey: .path), !path.isBlank {
            self.path = path
        } else if preset == .downloads {
            path = DockFolder.downloadsPath
        } else {
            throw DecodingError.dataCorruptedError(forKey: .path, in: c, debugDescription: "A folder needs a path.")
        }
        name = try c.decodeIfPresent(String.self, forKey: .name)
        layout = try c.decode(.layout, or: .grid)
        sort = try c.decode(.sort, or: preset == .downloads ? .dateAdded : .name)
    }
}

extension DockSpacer {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(.id, or: "")
        size = try c.decode(.size, or: .small)
    }
}

// MARK: - Folder contents

/// One file or folder inside a folder stack.
struct FolderEntry: Equatable, Identifiable, Sendable {
    var url: URL
    /// As the Finder shows it.
    var name: String
    /// "PDF document", "Folder"…
    var kind: String
    var dateAdded: Date
    var isFolder = false

    var id: String { url.path }
}

/// Reading, filtering and sorting a folder's contents. Pure apart from `read`.
enum FolderListing {
    /// What browsers write while a download is still coming in: Safari's
    /// `.download` bundles, Chrome's `.crdownload`, Firefox's `.part`.
    static let partialDownloadExtensions: Set<String> = ["download", "crdownload", "part"]

    static func isPartialDownload(_ url: URL) -> Bool {
        partialDownloadExtensions.contains(url.pathExtension.lowercased())
    }

    /// The folder's visible items, without hidden files. `skipsPartialDownloads`
    /// also leaves out downloads that haven't finished.
    static func read(_ directory: URL, skipsPartialDownloads: Bool) throws -> [FolderEntry] {
        let keys: [URLResourceKey] = [
            .addedToDirectoryDateKey, .creationDateKey, .localizedNameKey,
            .localizedTypeDescriptionKey, .isDirectoryKey, .isPackageKey,
        ]
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )
        return urls.compactMap { url in
            if skipsPartialDownloads, isPartialDownload(url) { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            return FolderEntry(
                url: url,
                name: values?.localizedName ?? url.lastPathComponent,
                kind: values?.localizedTypeDescription ?? "",
                dateAdded: values?.addedToDirectoryDate ?? values?.creationDate ?? .distantPast,
                isFolder: values?.isDirectory == true && values?.isPackage != true
            )
        }
    }

    static func sorted(_ entries: [FolderEntry], by sort: FolderSort) -> [FolderEntry] {
        func byName(_ a: FolderEntry, _ b: FolderEntry) -> Bool {
            let order = a.name.localizedStandardCompare(b.name)
            return order == .orderedSame ? a.url.path < b.url.path : order == .orderedAscending
        }
        switch sort {
        case .name:
            return entries.sorted(by: byName)
        case .kind:
            return entries.sorted { a, b in
                let order = a.kind.localizedStandardCompare(b.kind)
                return order == .orderedSame ? byName(a, b) : order == .orderedAscending
            }
        case .dateAdded:
            return entries.sorted { a, b in a.dateAdded == b.dateAdded ? byName(a, b) : a.dateAdded > b.dateAdded }
        }
    }

    /// Items added after `since`; none before the folder was ever seen.
    static func newCount(_ entries: [FolderEntry], since: Date?) -> Int {
        guard let since else { return 0 }
        return entries.filter { $0.dateAdded > since }.count
    }
}

// MARK: - Undo

/// One level of undo for bar edits: adding, removing and moving items,
/// pinning, and what workspaces show. It keeps the config from before the
/// edit and restores only the parts the edit changed, and only while nothing
/// else has changed those parts since, so a later edit is never lost.
struct DockBarUndo: Equatable {
    /// The parts of `DockConfig` that make up the bar.
    enum Part: CaseIterable {
        case groups, pinnedApps, tiles, folders, spacers, order, workspaces, activeWorkspace, trash

        func matches(_ a: DockConfig, _ b: DockConfig) -> Bool {
            switch self {
            case .groups: a.groups == b.groups
            case .pinnedApps: a.pinnedApps == b.pinnedApps
            case .tiles: a.tiles == b.tiles
            case .folders: a.folders == b.folders
            case .spacers: a.spacers == b.spacers
            case .order: a.order == b.order
            case .workspaces: a.workspaces == b.workspaces
            case .activeWorkspace: a.activeWorkspaceID == b.activeWorkspaceID
            case .trash: a.showsTrash == b.showsTrash
            }
        }

        func copy(from source: DockConfig, to target: inout DockConfig) {
            switch self {
            case .groups: target.groups = source.groups
            case .pinnedApps: target.pinnedApps = source.pinnedApps
            case .tiles: target.tiles = source.tiles
            case .folders: target.folders = source.folders
            case .spacers: target.spacers = source.spacers
            case .order: target.order = source.order
            case .workspaces: target.workspaces = source.workspaces
            case .activeWorkspace: target.activeWorkspaceID = source.activeWorkspaceID
            case .trash: target.showsTrash = source.showsTrash
            }
        }
    }

    private var before: DockConfig?
    private var after: DockConfig?
    private(set) var changedParts: [Part] = []

    /// Keeps `before` when the edit changed the bar; an edit that didn't
    /// leaves the previous one to undo.
    mutating func record(before: DockConfig, after: DockConfig) {
        let changed = Part.allCases.filter { !$0.matches(before, after) }
        guard !changed.isEmpty else { return }
        self.before = before
        self.after = after
        changedParts = changed
    }

    func canUndo(_ current: DockConfig) -> Bool {
        guard let after, !changedParts.isEmpty else { return false }
        return changedParts.allSatisfy { $0.matches(current, after) }
    }

    /// `current` with the edit's parts as they were before it.
    func undone(_ current: DockConfig) -> DockConfig? {
        guard canUndo(current), let before else { return nil }
        var result = current
        for part in changedParts { part.copy(from: before, to: &result) }
        return result
    }
}
