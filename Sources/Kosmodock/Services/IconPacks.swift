import AppKit
import Observation
import UniformTypeIdentifiers

// Local icon packs: folders of images in ~/.config/kosmodock/icon-packs/<pack>/
// drawn instead of the apps' own icons. Nothing here touches the apps: the
// dock only shows another picture for them.

// MARK: - Matching

/// Names match whatever their case and punctuation: "Visual-Studio-Code.png",
/// "visual studio code.png" and "VisualStudioCode.png" are the same file.
enum IconPackMatching {
    /// Lowercased letters and digits only.
    static func key(_ text: String) -> String {
        var key = ""
        for scalar in text.lowercased().unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            key.unicodeScalars.append(scalar)
        }
        return key
    }

    /// The names an app goes by, as keys, the most specific first: its bundle
    /// id, its name, the Finder's name, its bundle's file name and its slug.
    static func keys(name: String, displayName: String? = nil, bundleFileName: String? = nil, bundleID: String? = nil) -> [String] {
        var seen = Set<String>()
        return [bundleID, name, displayName, bundleFileName, DockConfig.slug(name)]
            .compactMap { $0 }
            .map(key)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

// MARK: - Packs

/// An icon pack's optional `pack.json`. Every key is optional.
struct IconPackManifest: Decodable, Equatable, Sendable {
    var name: String?
    var author: String?
    /// Share of the icon left empty around the artwork, 0…0.4.
    var padding: Double?
    /// App name, bundle id or slug → image file in the pack's folder.
    var icons: [String: String] = [:]

    private enum CodingKeys: String, CodingKey {
        case name, author, padding, icons
    }

    init(name: String? = nil, author: String? = nil, padding: Double? = nil, icons: [String: String] = [:]) {
        self.name = name
        self.author = author
        self.padding = padding
        self.icons = icons
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        padding = try c.decodeIfPresent(Double.self, forKey: .padding)
        icons = try c.decode(.icons, or: [:])
    }
}

struct IconPack: Identifiable, Equatable, Sendable {
    static let manifestName = "pack.json"
    static let maximumPadding = 0.4
    static let imageExtensions: Set<String> = ["png", "icns", "jpg", "jpeg", "tif", "tiff", "heic", "webp"]

    /// The folder's name, which `ThemeConfig.iconPack` saves.
    let id: String
    var name: String
    var author: String?
    var padding: Double
    var folder: URL
    /// From `pack.json`, by name key; these win over file names.
    var mapped: [String: URL] = [:]
    /// From the images' file names, by name key.
    var files: [String: URL] = [:]
    /// Why `pack.json` was ignored.
    var problem: String?

    static func clampedPadding(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return 0 }
        return min(maximumPadding, max(0, value))
    }

    /// The image for the first key the pack knows, `pack.json` first.
    func iconURL(forKeys keys: [String]) -> URL? {
        keys.lazy.compactMap { mapped[$0] }.first ?? keys.lazy.compactMap { files[$0] }.first
    }

    /// Up to `limit` of the pack's images, for previews.
    func sampleURLs(limit: Int) -> [URL] {
        Array(Set(mapped.values).union(files.values).sorted { $0.lastPathComponent < $1.lastPathComponent }.prefix(limit))
    }

    var iconCount: Int { Set(mapped.values).union(files.values).count }

    static func load(from folder: URL, fileManager: FileManager = .default) -> IconPack {
        var pack = IconPack(id: folder.lastPathComponent, name: folder.lastPathComponent, padding: 0, folder: folder)
        let contents = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for url in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where imageExtensions.contains(url.pathExtension.lowercased()) {
            let key = IconPackMatching.key(url.deletingPathExtension().lastPathComponent)
            if !key.isEmpty, pack.files[key] == nil { pack.files[key] = url }
        }
        let manifestURL = folder.appendingPathComponent(manifestName)
        guard fileManager.fileExists(atPath: manifestURL.path) else { return pack }
        let manifest: IconPackManifest
        do {
            manifest = try JSONDecoder().decode(IconPackManifest.self, from: Data(contentsOf: manifestURL))
        } catch {
            pack.problem = L10n.tr("pack.json was ignored: %@", ConfigService.describe(error))
            return pack
        }
        if let name = manifest.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { pack.name = name }
        pack.author = manifest.author.flatMap { $0.isBlank ? nil : $0 }
        pack.padding = clampedPadding(manifest.padding)
        let root = folder.standardizedFileURL.path + "/"
        for (appName, file) in manifest.icons {
            let url = folder.appendingPathComponent(file).standardizedFileURL
            // Only files inside the pack, and only ones that are there.
            guard url.path.hasPrefix(root), fileManager.fileExists(atPath: url.path) else { continue }
            let key = IconPackMatching.key(appName)
            if !key.isEmpty { pack.mapped[key] = url }
        }
        return pack
    }

    /// Every pack in `directory`, one per subfolder, by name.
    static func loadAll(in directory: URL, fileManager: FileManager = .default) -> [IconPack] {
        let folders = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return folders
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { load(from: $0, fileManager: fileManager) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Resolving

/// Where an app's icon comes from.
enum IconChoice: Equatable, Sendable {
    /// A custom image chosen for the app.
    case custom(URL)
    case pack(URL, padding: Double)
    /// The app's own icon.
    case app
}

enum IconResolver {
    /// A custom icon first, then the pack, then the app's own icon. An empty
    /// custom path means the app's own icon even when the pack covers it; a
    /// custom image that's gone falls through to the pack.
    static func choice(
        overrideKeys: [String], overrides: [String: String], nameKeys: [String], pack: IconPack?,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> IconChoice {
        if let path = overrideKeys.lazy.compactMap({ overrides[$0] }).first {
            if path.isBlank { return .app }
            let expanded = (path as NSString).expandingTildeInPath
            if fileExists(expanded) { return .custom(URL(fileURLWithPath: expanded)) }
        }
        if let pack, let url = pack.iconURL(forKeys: nameKeys) {
            return .pack(url, padding: pack.padding)
        }
        return .app
    }
}

// MARK: - Library

/// The icon packs on disk and the theme's choices, in front of
/// `WorkspaceService.icon(for:)`, which caches what this returns.
@MainActor
@Observable
final class IconLibrary {
    private(set) var packs: [IconPack] = []

    @ObservationIgnored let folder: URL
    @ObservationIgnored private let configService: ConfigService
    @ObservationIgnored private let workspace: WorkspaceService
    /// Pack previews in Settings.
    @ObservationIgnored private var thumbnails: [URL: NSImage] = [:]

    init(configService: ConfigService, workspace: WorkspaceService) {
        self.configService = configService
        self.workspace = workspace
        folder = configService.fileURL.deletingLastPathComponent().appendingPathComponent("icon-packs", isDirectory: true)
        packs = IconPack.loadAll(in: folder)
        workspace.iconResolver = { [weak self] app in self?.image(for: app) }
        configService.addObserver { [weak self] old, new in
            if old.theme.iconPack != new.theme.iconPack || old.theme.appIcons != new.theme.appIcons {
                self?.workspace.iconsDidChange()
            }
        }
    }

    var activePack: IconPack? {
        configService.config.theme.iconPack.flatMap { id in packs.first { $0.id == id } }
    }

    /// Reads the packs folder again, for packs added or changed in Finder.
    func reload() {
        let next = IconPack.loadAll(in: folder)
        if next != packs { packs = next }
        thumbnails.removeAll()
        workspace.iconsDidChange()
    }

    func use(_ pack: IconPack?) {
        configService.update { $0.theme.iconPack = pack?.id }
    }

    /// Every app gets its own icon back; the packs stay in their folder.
    func restoreSystemIcons() {
        configService.update { config in
            config.theme.iconPack = nil
            config.theme.appIcons = [:]
        }
    }

    func openFolder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    // MARK: Per app

    func choice(for app: DockApp) -> IconChoice {
        IconResolver.choice(
            overrideKeys: overrideKeys(for: app), overrides: configService.config.theme.appIcons,
            nameKeys: nameKeys(for: app), pack: activePack
        )
    }

    func image(for app: DockApp) -> NSImage? {
        switch choice(for: app) {
        case .app: nil
        case .custom(let url): Self.image(at: url, padding: 0)
        case .pack(let url, let padding): Self.image(at: url, padding: padding)
        }
    }

    func hasCustomIcon(_ app: DockApp) -> Bool {
        overrideKeys(for: app).contains { configService.config.theme.appIcons[$0] != nil }
    }

    /// `path` nil drops the custom icon; "" keeps the app's own icon over a pack.
    func setIcon(_ path: String?, for app: DockApp) {
        let keys = overrideKeys(for: app)
        configService.update { config in
            for key in keys { config.theme.appIcons[key] = nil }
            if let path, let key = keys.first {
                config.theme.appIcons[key] = path.isEmpty ? "" : (path as NSString).abbreviatingWithTildeInPath
            }
        }
    }

    func chooseIcon(for app: DockApp) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if FileManager.default.fileExists(atPath: folder.path) { panel.directoryURL = folder }
        panel.prompt = L10n.tr("Use Icon")
        panel.message = L10n.tr("Choose an image for %@", workspace.displayName(for: app))
        // Kosmodock is an accessory app; the panel would open behind others.
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setIcon(url.path, for: app)
    }

    /// Every app on the dock (groups and pinned apps, any workspace) once.
    var dockApps: [DockApp] {
        let config = configService.config
        var seen = Set<String>()
        return (config.groups.flatMap(\.apps) + config.pinnedApps).filter { app in
            seen.insert(workspace.bundleID(for: app) ?? app.id).inserted
        }
    }

    func packIconURL(_ pack: IconPack, for app: DockApp) -> URL? {
        pack.iconURL(forKeys: nameKeys(for: app))
    }

    func coverage(of pack: IconPack) -> (covered: Int, total: Int) {
        let apps = dockApps
        return (apps.filter { packIconURL(pack, for: $0) != nil }.count, apps.count)
    }

    func thumbnail(_ url: URL, padding: Double) -> NSImage? {
        if let cached = thumbnails[url] { return cached }
        let image = Self.image(at: url, padding: padding)
        thumbnails[url] = image
        return image
    }

    /// Custom icons are saved by bundle id, or by the entry's id without one.
    private func overrideKeys(for app: DockApp) -> [String] {
        var keys: [String] = []
        if let bundleID = workspace.bundleID(for: app) { keys.append(bundleID) }
        if !keys.contains(app.id) { keys.append(app.id) }
        return keys
    }

    private func nameKeys(for app: DockApp) -> [String] {
        IconPackMatching.keys(
            name: app.name, displayName: workspace.displayName(for: app),
            bundleFileName: workspace.url(for: app)?.deletingPathExtension().lastPathComponent,
            bundleID: workspace.bundleID(for: app)
        )
    }

    // MARK: Images

    /// The image fitted in a square, inset by `padding` (a share of the
    /// side, split between both edges). Drawn on demand, so it stays sharp.
    nonisolated static func image(at url: URL, padding: Double) -> NSImage? {
        guard let source = NSImage(contentsOf: url), source.size.width > 0, source.size.height > 0 else { return nil }
        let side: CGFloat = 256
        let box = CGRect(x: 0, y: 0, width: side, height: side).insetBy(dx: side * padding / 2, dy: side * padding / 2)
        let aspect = source.size.width / source.size.height
        let fitted = aspect >= 1
            ? CGRect(x: box.minX, y: box.midY - box.width / aspect / 2, width: box.width, height: box.width / aspect)
            : CGRect(x: box.midX - box.height * aspect / 2, y: box.minY, width: box.height * aspect, height: box.height)
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            source.draw(in: fitted, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
    }
}
