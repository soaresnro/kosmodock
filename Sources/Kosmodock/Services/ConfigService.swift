import AppKit
import Observation

/// Owns `~/.config/kosmodock/config.json`: first-launch generation, debounced
/// saving of in-app edits, live hot-reload of external edits, and backups.
@MainActor
@Observable
final class ConfigService {
    typealias Observer = (_ old: DockConfig, _ new: DockConfig) -> Void

    private(set) var config = DockConfig()
    /// Human-readable parse/IO error; the last valid config stays active.
    private(set) var lastError: String?
    private(set) var lastLoadedAt: Date?
    /// Copies of config.json in `backups/` next to it, newest first.
    private(set) var backups: [ConfigBackup] = []

    let fileURL: URL
    let backupStore: ConfigBackupStore

    @ObservationIgnored private var observers: [Observer] = []
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    /// Bytes most recently read or written, used to ignore our own writes.
    @ObservationIgnored private var lastSyncedData: Data?

    nonisolated static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/kosmodock/config.json")
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return encoder
    }()

    init(fileURL: URL = ConfigService.defaultFileURL) {
        self.fileURL = fileURL
        backupStore = ConfigBackupStore(directory: fileURL.deletingLastPathComponent().appendingPathComponent("backups"))
    }

    func bootstrap() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            lastError = L10n.tr("Could not create %@: %@", fileURL.deletingLastPathComponent().path, error.localizedDescription)
        }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            reloadFromDisk(force: true)
        } else {
            apply(AppDiscovery.makeDefaultConfig())
            writeToDisk()
        }
        let watcher = FileWatcher(url: fileURL) { [weak self] in self?.reloadFromDisk() }
        watcher.start()
        self.watcher = watcher
    }

    func addObserver(_ observer: @escaping Observer) {
        observers.append(observer)
    }

    /// Applies an in-app edit immediately and persists it shortly after.
    func update(_ mutate: (inout DockConfig) -> Void) {
        var next = config
        mutate(&next)
        guard next != config else { return }
        apply(next)
        scheduleSave()
    }

    #if DEBUG
    /// Debug snapshots only: applies a change in memory and never saves it.
    func preview(_ mutate: (inout DockConfig) -> Void) {
        var next = config
        mutate(&next)
        apply(next)
    }
    #endif

    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        writeToDisk()
    }

    func reloadFromDisk(force: Bool = false) {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            lastError = L10n.tr("Could not read config.json: %@", error.localizedDescription)
            return
        }
        if !force, data == lastSyncedData { return }
        do {
            let decoded = try JSONDecoder().decode(DockConfig.self, from: data)
            lastSyncedData = data
            lastError = nil
            lastLoadedAt = Date()
            if decoded != config { apply(decoded) }
        } catch {
            lastError = Self.describe(error)
        }
    }

    func resetToDefaults() {
        apply(AppDiscovery.makeDefaultConfig())
        saveNow()
    }

    func openInEditor() {
        NSWorkspace.shared.open(fileURL)
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    // MARK: Backups

    /// Copies config.json as it is on disk into `backups/`, unless it equals
    /// the newest copy. An in-app edit still waiting to be saved is saved first.
    /// Backups live in another file, so the watcher never sees these writes.
    @discardableResult
    func backUp() -> Bool {
        if pendingSave != nil { saveNow() }
        defer { refreshBackups() }
        do {
            try backupStore.save(Data(contentsOf: fileURL))
            return true
        } catch {
            lastError = L10n.tr("Could not back up config.json: %@", error.localizedDescription)
            return false
        }
    }

    /// Replaces the config with `backup`'s, after backing up the current one.
    /// A backup that doesn't decode changes nothing and is reported in `lastError`.
    @discardableResult
    func restore(_ backup: ConfigBackup) -> Bool {
        let restored: DockConfig
        do {
            restored = try JSONDecoder().decode(DockConfig.self, from: Data(contentsOf: backup.url))
        } catch {
            lastError = L10n.tr("Could not restore %@: %@", backup.url.lastPathComponent, Self.describe(error))
            return false
        }
        guard backUp() else { return false }
        apply(restored)
        // Records the written bytes, so the watcher ignores this save.
        saveNow()
        return lastError == nil
    }

    func refreshBackups() {
        let current = backupStore.list()
        if current != backups { backups = current }
    }

    func revealInFinder(_ backup: ConfigBackup) {
        NSWorkspace.shared.activateFileViewerSelecting([backup.url])
    }

    // MARK: Private

    private func apply(_ next: DockConfig) {
        let old = config
        config = next
        for observer in observers { observer(old, next) }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.pendingSave = nil
            self?.writeToDisk()
        }
    }

    private func writeToDisk() {
        do {
            let data = try Self.encoder.encode(config)
            try data.write(to: fileURL, options: .atomic)
            lastSyncedData = data
            lastError = nil
        } catch {
            lastError = L10n.tr("Could not save config.json: %@", error.localizedDescription)
        }
    }

    nonisolated static func describe(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else { return error.localizedDescription }
        func path(_ context: DecodingError.Context) -> String {
            let joined = context.codingPath.map { key in
                key.intValue.map { "[\($0)]" } ?? ".\(key.stringValue)"
            }.joined()
            return joined.isEmpty ? "" : L10n.tr(" at %@", joined.hasPrefix(".") ? String(joined.dropFirst()) : joined)
        }
        switch decodingError {
        case .dataCorrupted(let context):
            let underlying = (context.underlyingError as NSError?)?.userInfo["NSDebugDescription"] as? String
            return L10n.tr("Invalid JSON%@: %@", path(context), underlying ?? context.debugDescription)
        case .keyNotFound(let key, let context):
            return L10n.tr("Missing key '%@'%@", key.stringValue, path(context))
        case .typeMismatch(let type, let context):
            return L10n.tr("Type mismatch%@: expected %@. %@", path(context), String(describing: type), context.debugDescription)
        case .valueNotFound(let type, let context):
            return L10n.tr("Missing value%@: expected %@", path(context), String(describing: type))
        @unknown default:
            return error.localizedDescription
        }
    }
}
