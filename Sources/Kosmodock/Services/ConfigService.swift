import AppKit
import Observation

/// Owns `~/.config/kosmodock/config.json`: first-launch generation, debounced
/// saving of in-app edits, and live hot-reload of external edits.
@MainActor
@Observable
final class ConfigService {
    typealias Observer = (_ old: DockConfig, _ new: DockConfig) -> Void

    private(set) var config = DockConfig()
    /// Human-readable parse/IO error; the last valid config stays active.
    private(set) var lastError: String?
    private(set) var lastLoadedAt: Date?

    let fileURL: URL

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

    func saveNow() {
        pendingSave?.cancel()
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
