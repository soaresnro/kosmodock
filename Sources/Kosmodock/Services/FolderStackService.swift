import AppKit
import Observation
import OSLog

extension Logger {
    static let dockItems = Logger(subsystem: "dev.kosmodock.Kosmodock", category: "dock-items")
}

// MARK: - Folder stacks

/// When each folder's popover was last opened: Downloads counts the files
/// added after that. Kept in UserDefaults, or only in memory (tests, snapshots).
final class FolderSeenStore {
    private let defaults: UserDefaults?
    private var memory: [String: Date] = [:]

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
    }

    private func key(_ folderID: String) -> String { "Kosmodock.folderSeen.\(folderID)" }

    func date(for folderID: String) -> Date? {
        guard let defaults else { return memory[folderID] }
        return defaults.object(forKey: key(folderID)) as? Date
    }

    func markSeen(_ folderID: String, at date: Date = Date()) {
        if let defaults {
            defaults.set(date, forKey: key(folderID))
        } else {
            memory[folderID] = date
        }
    }
}

/// Lists the folders on the bar and keeps them current: each readable folder
/// is watched with a dispatch source on its descriptor (`FileWatcher`), and
/// re-read when it changes. Reading happens off the main thread.
@MainActor
@Observable
final class FolderStackService {
    struct Stack: Equatable {
        var entries: [FolderEntry] = []
        var isLoaded = false
        /// False when the folder is missing or macOS denies access to it.
        var isReadable = true
        /// Downloads only: files added since its popover was last opened.
        var newCount = 0
    }

    private(set) var stacks: [String: Stack] = [:]

    /// Whether a folder's popover is open: what arrives meanwhile counts as seen.
    @ObservationIgnored var isShowing: (String) -> Bool = { _ in false }
    @ObservationIgnored var seen: FolderSeenStore
    @ObservationIgnored private var folders: [String: DockFolder] = [:]
    @ObservationIgnored private var watchers: [String: FileWatcher] = [:]
    @ObservationIgnored private var loads: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var retries: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let icons = NSCache<NSString, NSImage>()

    /// A folder that can't be read is tried again this often, in case access is granted.
    static let retryInterval: Duration = .seconds(30)

    init(seen: FolderSeenStore = FolderSeenStore()) {
        self.seen = seen
    }

    func stack(for folderID: String) -> Stack {
        stacks[folderID] ?? Stack()
    }

    func newCount(for folderID: String) -> Int {
        stacks[folderID]?.newCount ?? 0
    }

    /// Starts watching new folders, re-reads moved ones and forgets removed ones.
    func update(folders list: [DockFolder]) {
        var next: [String: DockFolder] = [:]
        for folder in list where next[folder.id] == nil { next[folder.id] = folder }
        for id in folders.keys where next[id] == nil {
            stop(id)
            stacks[id] = nil
        }
        let previous = folders
        folders = next
        for (id, folder) in next {
            let old = previous[id]
            guard old?.url != folder.url || old?.isDownloads != folder.isDownloads else { continue }
            stop(id)
            reload(id)
        }
    }

    func stopAll() {
        for id in Array(folders.keys) { stop(id) }
    }

    func reload(_ folderID: String) {
        guard let folder = folders[folderID] else { return }
        let url = folder.url
        let skipsPartial = folder.isDownloads
        loads[folderID]?.cancel()
        loads[folderID] = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Result { try FolderListing.read(url, skipsPartialDownloads: skipsPartial) }
            }.value
            guard !Task.isCancelled else { return }
            self?.finishLoad(folderID, url: url, result: result)
        }
    }

    /// The popover opened: everything in it now has been seen.
    func didOpen(_ folderID: String) {
        markSeen(folderID)
        reload(folderID)
    }

    func markSeen(_ folderID: String) {
        guard folders[folderID]?.isDownloads == true else { return }
        seen.markSeen(folderID)
        if var stack = stacks[folderID], stack.newCount != 0 {
            stack.newCount = 0
            stacks[folderID] = stack
        }
    }

    // MARK: Icons

    func icon(for folder: DockFolder) -> NSImage {
        icon(forPath: folder.url.path)
    }

    func icon(for entry: FolderEntry) -> NSImage {
        icon(forPath: entry.url.path, version: entry.dateAdded.timeIntervalSinceReferenceDate)
    }

    private func icon(forPath path: String, version: Double = 0) -> NSImage {
        let key = "\(path)#\(version)" as NSString
        if let cached = icons.object(forKey: key) { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        icons.setObject(image, forKey: key)
        return image
    }

    // MARK: Private

    private func finishLoad(_ folderID: String, url: URL, result: Result<[FolderEntry], Error>) {
        guard let folder = folders[folderID], folder.url == url else { return }
        var stack = stacks[folderID] ?? Stack()
        stack.isLoaded = true
        switch result {
        case .success(let entries):
            stack.isReadable = true
            stack.entries = entries
            retries[folderID]?.cancel()
            retries[folderID] = nil
            if watchers[folderID] == nil {
                let watcher = FileWatcher(url: url) { [weak self] in self?.reload(folderID) }
                watcher.start()
                watchers[folderID] = watcher
            }
            if folder.isDownloads {
                // Files already there the first time aren't new.
                if seen.date(for: folderID) == nil || isShowing(folderID) { seen.markSeen(folderID) }
                stack.newCount = FolderListing.newCount(entries, since: seen.date(for: folderID))
            }
        case .failure(let error):
            Logger.dockItems.notice("Can't read folder \(folderID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            stack.isReadable = false
            stack.entries = []
            stack.newCount = 0
            watchers[folderID]?.stop()
            watchers[folderID] = nil
            scheduleRetry(folderID)
        }
        if stacks[folderID] != stack { stacks[folderID] = stack }
    }

    private func scheduleRetry(_ folderID: String) {
        retries[folderID]?.cancel()
        retries[folderID] = Task { [weak self] in
            try? await Task.sleep(for: Self.retryInterval)
            guard !Task.isCancelled else { return }
            self?.reload(folderID)
        }
    }

    private func stop(_ folderID: String) {
        watchers[folderID]?.stop()
        watchers[folderID] = nil
        loads[folderID]?.cancel()
        loads[folderID] = nil
        retries[folderID]?.cancel()
        retries[folderID] = nil
    }
}

// MARK: - Trash

enum TrashState: Equatable, Sendable {
    case empty
    case full
    /// Reading ~/.Trash needs Full Disk Access.
    case unreadable
}

enum TrashReader {
    /// Files the Finder keeps in an empty Trash.
    static let bookkeeping: Set<String> = [".DS_Store", ".localized"]

    static func state(of directory: URL) -> TrashState {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return .unreadable }
        return names.contains { !bookkeeping.contains($0) } ? .full : .empty
    }
}

/// The Trash item: whether it's full, opening it, and emptying it through the
/// Finder. It's watched only while it can be read; otherwise it's checked
/// again now and then, in case Full Disk Access is granted.
@MainActor
@Observable
final class TrashService {
    private(set) var state: TrashState = .empty
    private(set) var isEmptying = false

    let url: URL
    @ObservationIgnored private var isEnabled = false
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var poll: Task<Void, Never>?

    init(url: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash", isDirectory: true)) {
        self.url = url
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            refresh()
        } else {
            watcher?.stop()
            watcher = nil
            poll?.cancel()
            poll = nil
        }
    }

    func refresh() {
        let url = url
        Task { [weak self] in
            let next = await Task.detached(priority: .utility) { TrashReader.state(of: url) }.value
            self?.apply(next)
        }
    }

    func open() {
        NSWorkspace.shared.open(url)
    }

    /// Asks the Finder to empty the Trash, as its own command does, so the
    /// Finder's sound and the Trash on other volumes are handled as usual.
    func empty() async throws {
        isEmptying = true
        defer {
            isEmptying = false
            refresh()
        }
        try await Task.detached(priority: .userInitiated) { try FinderTrash.empty() }.value
    }

    private func apply(_ next: TrashState) {
        guard isEnabled else { return }
        if state != next { state = next }
        if next == .unreadable {
            watcher?.stop()
            watcher = nil
            schedulePoll()
        } else if watcher == nil {
            poll?.cancel()
            poll = nil
            let watcher = FileWatcher(url: url) { [weak self] in self?.refresh() }
            watcher.start()
            self.watcher = watcher
        }
    }

    private func schedulePoll() {
        guard poll == nil else { return }
        poll = Task { [weak self] in
            try? await Task.sleep(for: FolderStackService.retryInterval)
            guard !Task.isCancelled else { return }
            self?.poll = nil
            self?.refresh()
        }
    }
}

/// The Finder's `empty` command (`fndr`/`empt` in its scripting dictionary),
/// sent as a plain Apple Event. The first time, macOS asks to let Kosmodock
/// control the Finder.
enum FinderTrash {
    /// errAEEventNotPermitted: Automation was denied.
    static let notPermitted = -1743

    static func empty() throws {
        let finder = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
        let event = NSAppleEventDescriptor(
            eventClass: code("fndr"), eventID: code("empt"), targetDescriptor: finder,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID)
        )
        let reply = try event.sendEvent(options: [.waitForReply, .canInteract], timeout: 300)
        if let number = reply.paramDescriptor(forKeyword: code("errn"))?.int32Value, number != 0 {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(number))
        }
    }

    static func code(_ text: String) -> FourCharCode {
        text.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }
}
