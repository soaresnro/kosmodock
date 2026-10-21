import AppKit
import Foundation
import Observation
import QuickLookThumbnailing

// Data behind the file and sharing widgets. Folders are watched only while a
// screenshots or files tile is on the bar (`FileWidgetService.update`), and
// entries are published only when they change.

struct FileEntry: Identifiable, Equatable, Sendable {
    var url: URL
    /// When it arrived in the folder (falling back to its creation, then
    /// modification date).
    var date: Date
    var isDirectory: Bool

    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

// MARK: - Recent files

enum RecentFiles {
    /// Downloads still in progress.
    static let partialExtensions: Set<String> = ["download", "crdownload", "part", "partial", "opdownload"]

    static let keys: [URLResourceKey] = [
        .addedToDirectoryDateKey, .creationDateKey, .contentModificationDateKey, .isDirectoryKey, .isHiddenKey,
    ]

    /// The folder's visible items that pass `include`, newest first, at most `limit`.
    static func entries(in folder: URL, limit: Int, include: (URL) -> Bool = { _ in true }) -> [FileEntry] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let entries = urls.compactMap { url -> FileEntry? in
            guard !partialExtensions.contains(url.pathExtension.lowercased()), include(url),
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isHidden != true else { return nil }
            return FileEntry(url: url, date: date(of: values), isDirectory: values.isDirectory ?? false)
        }
        return Array(sorted(entries).prefix(max(0, limit)))
    }

    static func date(of values: URLResourceValues) -> Date {
        values.addedToDirectoryDate ?? values.creationDate ?? values.contentModificationDate ?? .distantPast
    }

    /// Newest first; files from the same second by name, so the order is stable.
    static func sorted(_ entries: [FileEntry]) -> [FileEntry] {
        entries.sorted { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date > rhs.date }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// Entries that arrived after `since`; none before the folder was first seen.
    static func newCount(_ entries: [FileEntry], since: Date?) -> Int {
        guard let since else { return 0 }
        return entries.filter { $0.date > since }.count
    }
}

// MARK: - Screenshots

enum ScreenshotDetector {
    /// Formats `screencapture` saves in.
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp", "pdf"]

    /// The name macOS gives screenshots in its languages, plus common tools.
    static let namePrefixes = [
        "Screenshot", "Screen Shot", "Captura de Tela", "Captura de ecrã", "Captura de pantalla",
        "Capture d’écran", "Capture d'écran", "Bildschirmfoto", "Schermata", "Istantanea schermo",
        "Schermafbeelding", "Skärmavbild", "Skærmbillede", "Skjermbilde", "Näyttökuva", "Zrzut ekranu",
        "Snímek obrazovky", "Snímka obrazovky", "Képernyőfotó", "Ekran Resmi", "Ekran Görüntüsü",
        "Снимок экрана", "Знімок екрана", "Στιγμιότυπο οθόνης", "צילום מסך", "لقطة شاشة",
        "スクリーンショット", "截屏", "螢幕截圖", "截圖", "스크린샷", "ภาพหน้าจอ", "Ảnh màn hình",
        "Tangkapan Layar", "Cattura di schermata", "CleanShot",
    ]

    /// Set by `screencapture` on every screenshot it saves.
    static let metadataAttribute = "com.apple.metadata:kMDItemIsScreenCapture"

    static func isScreenshot(_ url: URL, customPrefix: String? = nil) -> Bool {
        guard imageExtensions.contains(url.pathExtension.lowercased()) else { return false }
        return looksLikeScreenshot(name: url.deletingPathExtension().lastPathComponent, customPrefix: customPrefix)
            || isScreenCapture(url)
    }

    /// "Screenshot 2026-10-21 at 09.41.00", but not "Screenshots guide".
    static func looksLikeScreenshot(name: String, customPrefix: String? = nil) -> Bool {
        let name = name.precomposedStringWithCanonicalMapping
        let prefixes = namePrefixes + [customPrefix].compactMap { $0 }.filter { !$0.isBlank }
        return prefixes.contains { prefix in
            guard let range = name.range(of: prefix.precomposedStringWithCanonicalMapping, options: [.anchored, .caseInsensitive]) else { return false }
            // The name goes on with a date, a number or a separator, not more of a word.
            guard let next = name[range.upperBound...].first else { return true }
            return !next.isLetter
        }
    }

    /// Whether the file carries `screencapture`'s marker, whatever its name.
    static func isScreenCapture(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            let size = getxattr(path, metadataAttribute, nil, 0, 0, 0)
            guard size > 0, size < 4096 else { return false }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { getxattr(path, metadataAttribute, $0.baseAddress, size, 0, 0) }
            guard read == size else { return false }
            let value = try? PropertyListSerialization.propertyList(from: data, format: nil)
            return (value as? Bool) ?? (value as? NSNumber)?.boolValue ?? false
        }
    }

    /// The screenshot folder chosen in the Screenshot app (⇧⌘5 › Options),
    /// when it still exists; otherwise the Desktop, the default.
    static func folder(preference: String?, home: URL, isDirectory: (URL) -> Bool) -> URL {
        if let path = preference?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            let url: URL = if path == "~" || path.hasPrefix("~/") {
                home.appendingPathComponent(String(path.dropFirst(2)), isDirectory: true)
            } else if path.hasPrefix("/") {
                URL(fileURLWithPath: path, isDirectory: true)
            } else {
                home.appendingPathComponent(path, isDirectory: true)
            }
            if isDirectory(url) { return url.standardizedFileURL }
        }
        return home.appendingPathComponent("Desktop", isDirectory: true)
    }

    /// Reads `defaults read com.apple.screencapture location` fresh each time.
    static func currentFolder() -> URL {
        let domain = "com.apple.screencapture" as CFString
        CFPreferencesAppSynchronize(domain)
        let location = CFPreferencesCopyAppValue("location" as CFString, domain) as? String
        return folder(preference: location, home: FileManager.default.homeDirectoryForCurrentUser) { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    /// A custom name set with `defaults write com.apple.screencapture name`.
    static func customPrefix() -> String? {
        CFPreferencesCopyAppValue("name" as CFString, "com.apple.screencapture" as CFString) as? String
    }
}

// MARK: - Folder watching

/// Calls back when a folder's entries change. Reopens the folder when it is
/// replaced or comes back after being deleted.
@MainActor
final class FolderWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var url: URL?
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func watch(_ url: URL) {
        guard url != self.url || source == nil else { return }
        stop()
        self.url = url
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let event = self.source?.data, event.contains(.delete) || event.contains(.rename) {
                    // The folder itself went away; the next scan reopens it.
                    self.source?.cancel()
                    self.source = nil
                }
                self.onChange()
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
        url = nil
    }
}

/// The newest entries of one folder: the screenshot folder or a chosen one.
@MainActor
@Observable
final class FolderFeed {
    enum Source: Equatable {
        case screenshots
        case folder(URL)
    }

    let source: Source
    private(set) var folder: URL
    private(set) var entries: [FileEntry] = []
    /// False when the folder is missing or macOS denied access to it.
    private(set) var isReadable = true

    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var pendingScan: Task<Void, Never>?
    @ObservationIgnored private var scanning = false
    @ObservationIgnored private var rescanAfter = false
    @ObservationIgnored var onEntries: (([FileEntry]) -> Void)?

    /// Enough for the largest grid, whatever the tile shows.
    static let limit = DockTile.fileCountRange.upperBound

    init(source: Source) {
        self.source = source
        switch source {
        case .screenshots: folder = ScreenshotDetector.currentFolder()
        case .folder(let url): folder = url
        }
    }

    func start() {
        guard poll == nil else { return }
        watcher = FolderWatcher { [weak self] in self?.scheduleScan() }
        // Catches a new screenshot location and changes the watcher missed.
        poll = Task { [weak self] in
            while !Task.isCancelled {
                self?.scan()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func stop() {
        poll?.cancel()
        poll = nil
        pendingScan?.cancel()
        watcher?.stop()
        watcher = nil
    }

    /// Screenshots are written under a temporary name and then renamed, so
    /// events are gathered for a moment.
    func scheduleScan() {
        pendingScan?.cancel()
        pendingScan = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.scan()
        }
    }

    func scan() {
        guard !scanning else {
            rescanAfter = true
            return
        }
        scanning = true
        if source == .screenshots {
            let current = ScreenshotDetector.currentFolder()
            if current != folder { folder = current }
        }
        let folder = folder
        let isScreenshots = source == .screenshots
        let limit = Self.limit
        watcher?.watch(folder)
        Task.detached(priority: .utility) { [weak self] in
            let readable = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) != nil
            let prefix = isScreenshots ? ScreenshotDetector.customPrefix() : nil
            let entries = RecentFiles.entries(in: folder, limit: limit) { url in
                !isScreenshots || ScreenshotDetector.isScreenshot(url, customPrefix: prefix)
            }
            await self?.publish(entries, readable: readable, for: folder)
        }
    }

    private func publish(_ next: [FileEntry], readable: Bool, for scanned: URL) {
        scanning = false
        if scanned == folder {
            if next != entries { entries = next }
            if readable != isReadable { isReadable = readable }
            onEntries?(next)
        }
        if rescanAfter {
            rescanAfter = false
            scan()
        }
    }
}

// MARK: - Service

/// Folder feeds of the screenshots and files tiles, by tile id, and the
/// shortcut runs. Files that arrived since the details were last opened count
/// as new; that moment is kept in UserDefaults, not in config.json.
@MainActor
@Observable
final class FileWidgetService {
    private(set) var feeds: [String: FolderFeed] = [:]
    /// When each files tile's details were last opened.
    private(set) var seenDates: [String: Date] = [:]
    /// While a tile's details are open: the previous `seenDates`, so the new
    /// files stay marked until they close.
    private(set) var highlightSince: [String: Date] = [:]
    let shortcuts = ShortcutsRunner()

    @ObservationIgnored private let defaults: UserDefaults
    /// Off for snapshots and tests: seen dates then live in memory only.
    @ObservationIgnored var persistsSeenDates = true

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private static func seenKey(_ tileID: String) -> String { "Kosmodock.filesSeen.\(tileID)" }

    /// Starts feeds for the tiles that need one and stops the others.
    func update(tiles: [DockTile]) {
        var wanted: [String: FolderFeed.Source] = [:]
        for tile in tiles {
            switch tile.kind {
            case .screenshots: wanted[tile.id] = .screenshots
            case .files: wanted[tile.id] = .folder(tile.folderURL)
            default: break
            }
        }
        for (id, feed) in feeds where wanted[id] != feed.source {
            feed.stop()
            feeds[id] = nil
        }
        for (id, source) in wanted where feeds[id] == nil {
            let feed = FolderFeed(source: source)
            if source != .screenshots { prepareSeenDate(for: id, feed: feed) }
            feeds[id] = feed
            feed.start()
        }
    }

    func stopAll() {
        feeds.values.forEach { $0.stop() }
        feeds = [:]
    }

    func entries(for tile: DockTile) -> [FileEntry] {
        Array((feeds[tile.id]?.entries ?? []).prefix(tile.shownFileCount))
    }

    func newCount(for tile: DockTile) -> Int {
        RecentFiles.newCount(feeds[tile.id]?.entries ?? [], since: seenDates[tile.id])
    }

    func isNew(_ entry: FileEntry, in tile: DockTile) -> Bool {
        guard let since = highlightSince[tile.id] ?? seenDates[tile.id] else { return false }
        return entry.date > since
    }

    func rescan(tileID: String) {
        feeds[tileID]?.scan()
    }

    /// The details opened: everything there now has been seen.
    func markSeen(tileID: String, at date: Date = Date()) {
        highlightSince[tileID] = seenDates[tileID] ?? date
        seenDates[tileID] = date
        if persistsSeenDates { defaults.set(date, forKey: Self.seenKey(tileID)) }
    }

    func detailsClosed(tileID: String) {
        highlightSince[tileID] = nil
    }

    /// A folder seen for the first time starts with nothing new.
    private func prepareSeenDate(for tileID: String, feed: FolderFeed) {
        if persistsSeenDates, let saved = defaults.object(forKey: Self.seenKey(tileID)) as? Date {
            seenDates[tileID] = saved
        } else {
            let now = Date()
            seenDates[tileID] = now
            if persistsSeenDates { defaults.set(now, forKey: Self.seenKey(tileID)) }
        }
    }
}

// MARK: - Shortcuts

/// Runs shortcuts from the Shortcuts app with its command-line tool.
@MainActor
@Observable
final class ShortcutsRunner {
    enum RunState: Equatable, Sendable {
        case idle
        case running
        case succeeded
        case failed(String)
    }

    static let tool = "/usr/bin/shortcuts"

    /// By tile id.
    private(set) var states: [String: RunState] = [:]
    /// The library's shortcut names, once `loadNames()` ran.
    private(set) var names: [String] = []
    private(set) var isLoadingNames = false

    @ObservationIgnored private var resets: [String: Task<Void, Never>] = [:]

    func state(for tileID: String) -> RunState { states[tileID] ?? .idle }

    func loadNames() async {
        guard !isLoadingNames else { return }
        isLoadingNames = true
        let result = await ShellRunner.run(Self.tool, ["list"], timeout: 15)
        isLoadingNames = false
        let parsed = result.succeeded ? Self.parseList(result.stdout) : []
        if parsed != names { names = parsed }
    }

    func run(_ tile: DockTile) {
        guard let name = tile.shortcutName, !name.isBlank, state(for: tile.id) != .running else { return }
        resets[tile.id]?.cancel()
        states[tile.id] = .running
        let id = tile.id
        Task { [weak self] in
            // Arguments, not a shell line, so any name is safe.
            let result = await ShellRunner.run(Self.tool, ["run", name], timeout: 600)
            self?.finish(id, with: result.succeeded ? .succeeded : .failed(Self.failure(from: result)))
        }
    }

    /// Shows how the run went for a moment, then the tile's own symbol again.
    private func finish(_ id: String, with state: RunState) {
        states[id] = state
        resets[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(state == .succeeded ? 2 : 6))
            guard !Task.isCancelled else { return }
            self?.states[id] = .idle
        }
    }

    /// One name per line, as `shortcuts list` prints them: trimmed, without
    /// blanks or repeats, sorted as the Finder sorts.
    nonisolated static func parseList(_ output: String) -> [String] {
        var seen = Set<String>()
        return output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    nonisolated static func failure(from result: ShellResult) -> String {
        if result.exitCode == 127 { return L10n.tr("The shortcuts command isn't available.") }
        if result.stderr.isBlank, result.stdout.isBlank, !result.timedOut { return L10n.tr("The shortcut stopped with an error.") }
        return result.errorSummary
    }

    /// Opens the shortcut in the Shortcuts app.
    static func edit(_ name: String) {
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "open-shortcut"
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }
}

// MARK: - Actions

/// Opening, revealing, copying and sending files, and opening bookmarks.
@MainActor
enum FileActions {
    static func perform(_ action: FileClickAction, on url: URL) {
        switch action {
        case .open: NSWorkspace.shared.open(url)
        case .reveal: reveal([url])
        case .copy: if !copyImage(at: url) { NSWorkspace.shared.open(url) }
        }
    }

    static func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// The image, for apps that paste pictures, and the file, for the Finder.
    @discardableResult
    static func copyImage(at url: URL) -> Bool {
        guard let image = NSImage(contentsOf: url) else { return false }
        let item = NSPasteboardItem()
        if url.pathExtension.lowercased() == "png", let data = try? Data(contentsOf: url) {
            item.setData(data, forType: .png)
        } else if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            item.setData(png, forType: .png)
        }
        if let tiff = image.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        item.setString(url.absoluteString, forType: .fileURL)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    static let airDropApp = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app/Contents/Applications/AirDrop.app")

    /// The AirDrop window of the Finder.
    static func openAirDrop() {
        let target = FileManager.default.fileExists(atPath: airDropApp.path)
            ? airDropApp
            : URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        NSWorkspace.shared.openApplication(at: target, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Shows the AirDrop sheet for `urls`. Kosmodock comes to the front first,
    /// or the sheet could open behind the frontmost app.
    @discardableResult
    static func sendViaAirDrop(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else { return false }
        NSApp.activate()
        service.perform(withItems: urls)
        return true
    }

    /// In the chosen browser, or the default one when it's unset or gone.
    static func open(_ bookmark: Bookmark, browser bundleID: String?) {
        guard let url = bookmark.resolvedURL else { return }
        if let bundleID, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    struct Browser: Identifiable, Hashable {
        var id: String
        var name: String
    }

    /// Apps that open web pages, by name.
    static func browsers() -> [Browser] {
        guard let probe = URL(string: "https://example.com") else { return [] }
        var seen = Set<String>()
        return NSWorkspace.shared.urlsForApplications(toOpen: probe).compactMap { url -> Browser? in
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, seen.insert(id).inserted else { return nil }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            return Browser(id: id, name: name)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Thumbnails

/// Quick Look thumbnails, cached by path, modification date and size.
@MainActor
final class ThumbnailLoader {
    static let shared = ThumbnailLoader()
    private let cache = NSCache<NSString, NSImage>()

    private func key(_ url: URL, side: CGFloat) -> NSString {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
        return "\(url.path)|\(modified)|\(Int(side))" as NSString
    }

    func cached(_ url: URL, side: CGFloat) -> NSImage? {
        cache.object(forKey: key(url, side: side))
    }

    func thumbnail(for url: URL, side: CGFloat, scale: CGFloat = 2) async -> NSImage? {
        let key = key(url, side: side)
        if let image = cache.object(forKey: key) { return image }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side), scale: scale, representationTypes: .thumbnail)
        let image: NSImage? = await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: representation?.nsImage)
            }
        }
        if let image { cache.setObject(image, forKey: key) }
        return image
    }
}
