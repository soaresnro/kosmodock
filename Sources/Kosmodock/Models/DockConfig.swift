import Foundation

// MARK: - Enumerations

/// How a group expands when its capsule is clicked.
enum ExpansionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case bento
    case accordion

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bento: L10n.tr("Bento Popover")
        case .accordion: L10n.tr("Inline Accordion")
        }
    }
}

/// The live widget rendered on a group's collapsed capsule.
enum WidgetType: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case cpuRam
    case podman
    case portProbe
    case customCommand

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: L10n.tr("None")
        case .cpuRam: L10n.tr("CPU & Memory")
        case .podman: L10n.tr("Podman Containers")
        case .portProbe: L10n.tr("Port Probe")
        case .customCommand: L10n.tr("Custom Command")
        }
    }

    var symbol: String {
        switch self {
        case .none: "circle.dashed"
        case .cpuRam: "cpu"
        case .podman: "shippingbox"
        case .portProbe: "network"
        case .customCommand: "terminal"
        }
    }
}

/// Window tiling presets applied through the Accessibility API.
enum TilingLayout: String, Codable, CaseIterable, Identifiable, Sendable {
    case splitHorizontal50_50
    case dev70_30Stack
    case mainPlusBottom25
    case grid2x2
    case maximizeAll

    var id: String { rawValue }

    var shortTitle: String {
        switch self {
        case .splitHorizontal50_50: "50/50"
        case .dev70_30Stack: "70/30"
        case .mainPlusBottom25: "75/25"
        case .grid2x2: L10n.tr("Grid")
        case .maximizeAll: L10n.tr("Max")
        }
    }

    var title: String {
        switch self {
        case .splitHorizontal50_50: L10n.tr("Split 50 / 50")
        case .dev70_30Stack: L10n.tr("Dev 70 / 30 Stack")
        case .mainPlusBottom25: L10n.tr("Main + Bottom 25%")
        case .grid2x2: L10n.tr("Grid 2 × 2")
        case .maximizeAll: L10n.tr("Maximize All")
        }
    }

    var symbol: String {
        switch self {
        case .splitHorizontal50_50: "rectangle.split.2x1"
        case .dev70_30Stack: "rectangle.split.3x1"
        case .mainPlusBottom25: "rectangle.split.1x2"
        case .grid2x2: "square.grid.2x2"
        case .maximizeAll: "arrow.up.left.and.arrow.down.right"
        }
    }

    /// Window slots the layout is designed for. When a group has fewer apps than
    /// slots, extra windows of the same apps fill the gaps. `nil` = every window.
    var capacity: Int? {
        switch self {
        case .splitHorizontal50_50: 2
        case .dev70_30Stack: 3
        case .mainPlusBottom25: 2
        case .grid2x2: 4
        case .maximizeAll: nil
        }
    }

    /// Window count used when drawing the layout's preview glyph.
    var previewCount: Int {
        switch self {
        case .splitHorizontal50_50: 2
        case .dev70_30Stack: 3
        case .mainPlusBottom25: 3
        case .grid2x2: 4
        case .maximizeAll: 1
        }
    }
}

enum GlassMaterial: String, Codable, CaseIterable, Identifiable, Sendable {
    case hudWindow
    case popover
    case menu
    case sidebar
    case underWindowBackground
    case fullScreenUI

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hudWindow: L10n.tr("HUD")
        case .popover: L10n.tr("Popover")
        case .menu: L10n.tr("Menu")
        case .sidebar: L10n.tr("Sidebar")
        case .underWindowBackground: L10n.tr("Under Window")
        case .fullScreenUI: L10n.tr("Full Screen UI")
        }
    }
}

enum AppearanceMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case dark
    case light

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: L10n.tr("System")
        case .dark: L10n.tr("Dark")
        case .light: L10n.tr("Light")
        }
    }
}

/// Interface language. `system` follows macOS (English when unsupported).
enum AppLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case englishUS = "en-US"
    case portugueseBR = "pt-BR"
    case spanishES = "es-ES"

    var id: String { rawValue }

    /// `.lproj` folder holding the translations.
    var lprojName: String? {
        switch self {
        case .system: nil
        case .englishUS: "en"
        case .portugueseBR: "pt-BR"
        case .spanishES: "es"
        }
    }

    var locale: Locale {
        switch self {
        case .system: .autoupdatingCurrent
        case .englishUS: Locale(identifier: "en_US")
        case .portugueseBR: Locale(identifier: "pt_BR")
        case .spanishES: Locale(identifier: "es_ES")
        }
    }

    /// Shown in each language's own name, as macOS does.
    var nativeName: String {
        switch self {
        case .system: L10n.tr("System")
        case .englishUS: "English (US)"
        case .portugueseBR: "Português (Brasil)"
        case .spanishES: "Español (España)"
        }
    }
}

enum ContainerRuntimeKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case podman
    case docker

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

// MARK: - Configuration

struct DockConfig: Codable, Equatable, Sendable {
    var version: Int = 1
    var theme = ThemeConfig()
    var behavior = BehaviorConfig()
    var telemetry = TelemetryConfig()
    var groups: [DockGroup] = []
}

struct ThemeConfig: Codable, Equatable, Sendable {
    var cornerRadius: Double = 22
    /// Opacity of the tint laid over the vibrancy blur (0 = pure glass, 1 = solid).
    var glassOpacity: Double = 0.35
    var borderOpacity: Double = 0.6
    var iconSize: Double = 34
    /// Distance between the bottom of the screen's visible frame and the dock.
    var dockMargin: Double = 10
    /// Spring response in seconds — lower is stiffer and snappier.
    var springResponse: Double = 0.32
    var springDamping: Double = 0.78
    var tileGap: Double = 8
    /// Space between the top of the dock and windows kept above it.
    var dockClearance: Double = 5
    var accentHex: String = "#8B7CFF"
    var material: GlassMaterial = .hudWindow
    var appearance: AppearanceMode = .system
    var showGroupLabels: Bool = true
}

struct BehaviorConfig: Codable, Equatable, Sendable {
    var expansionMode: ExpansionMode = .bento
    var suppressNativeDock: Bool = false
    /// "Launch & Tile" hides every app outside the group.
    var focusMode: Bool = false
    var showMenuBarIcon: Bool = true
    /// Keep windows above the dock (Accessibility enforcer). When off, the
    /// dock uses Intellihide: it slides away while a window overlaps it.
    var reserveScreenSpace: Bool = true
    /// Animate minimized windows into their group's capsule and list them there.
    var minimizeToGroups: Bool = true
    /// Clicking the icon of the frontmost app minimizes its focused window.
    var clickActiveAppToMinimize: Bool = true
    /// Bundle identifiers the screen-space enforcer never resizes or moves.
    var screenSpaceExclusions: [String] = []
    var language: AppLanguage = .system
}

struct TelemetryConfig: Codable, Equatable, Sendable {
    var pollInterval: Double = 3
    var containerRuntime: ContainerRuntimeKind = .podman
    /// Explicit path to the podman/docker binary; auto-detected when empty.
    var runtimePath: String? = nil
    var fallbackToDocker: Bool = true
    var commandTimeout: Double = 10
}

struct DockGroup: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var symbol: String = "square.stack.3d.up.fill"
    var tintHex: String? = nil
    var apps: [DockApp] = []
    var widget = WidgetConfig()
    var layout: TilingLayout = .splitHorizontal50_50
    /// Overrides `behavior.expansionMode` for this group when set.
    var expansionMode: ExpansionMode? = nil
}

struct DockApp: Codable, Equatable, Hashable, Identifiable, Sendable {
    var name: String
    var bundleId: String? = nil
    var path: String? = nil

    var id: String { bundleId ?? path ?? name }

    var expandedPath: String? {
        path.map { ($0 as NSString).expandingTildeInPath }
    }
}

struct WidgetConfig: Codable, Equatable, Sendable {
    var type: WidgetType = .none
    /// Ports checked by the `portProbe` widget.
    var ports: [Int] = []
    /// Shell snippet run by the `customCommand` widget. Exit 0 = 🟢, 1 = 🟡, else 🔴;
    /// the first line of stdout becomes the badge label.
    var command: String? = nil
    var label: String? = nil
    /// Seconds between command runs; defaults to `telemetry.pollInterval`.
    var interval: Double? = nil
    /// Extra health checks folded into the capsule's status dot (any widget type).
    var probes: [HealthProbe] = []
}

struct HealthProbe: Codable, Equatable, Hashable, Identifiable, Sendable {
    var name: String
    var port: Int? = nil
    var command: String? = nil

    var id: String { "\(name)#\(port.map(String.init) ?? "")#\(command ?? "")" }
}

// MARK: - Lenient decoding
//
// Every key is optional so a hand-edited config.json with missing fields still
// hot-reloads. Wrong types and unknown enum values still fail loudly, and the
// error is surfaced in Settings instead of silently reverting.

extension KeyedDecodingContainer {
    func decode<T: Decodable>(_ key: Key, or fallback: @autoclosure () -> T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback()
    }
}

extension DockConfig {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DockConfig()
        version = try c.decode(.version, or: d.version)
        theme = try c.decode(.theme, or: d.theme)
        behavior = try c.decode(.behavior, or: d.behavior)
        telemetry = try c.decode(.telemetry, or: d.telemetry)
        groups = DockConfig.normalizedIDs(try c.decode(.groups, or: []))
    }

    /// Gives every group a unique, stable id (derived from its name when missing)
    /// so UI state survives hot reloads of configs written without ids.
    static func normalizedIDs(_ groups: [DockGroup]) -> [DockGroup] {
        var seen = Set<String>()
        return groups.map { group in
            var group = group
            var base = group.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if base.isEmpty { base = slug(group.name) }
            var candidate = base
            var suffix = 2
            while seen.contains(candidate) {
                candidate = "\(base)-\(suffix)"
                suffix += 1
            }
            seen.insert(candidate)
            group.id = candidate
            return group
        }
    }

    static func slug(_ text: String) -> String {
        let lowered = text.lowercased()
        var result = ""
        var lastWasDash = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                result.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash, !result.isEmpty {
                result.append("-")
                lastWasDash = true
            }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return result.isEmpty ? "group" : result
    }
}

extension ThemeConfig {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ThemeConfig()
        cornerRadius = try c.decode(.cornerRadius, or: d.cornerRadius)
        glassOpacity = try c.decode(.glassOpacity, or: d.glassOpacity)
        borderOpacity = try c.decode(.borderOpacity, or: d.borderOpacity)
        iconSize = try c.decode(.iconSize, or: d.iconSize)
        dockMargin = try c.decode(.dockMargin, or: d.dockMargin)
        springResponse = try c.decode(.springResponse, or: d.springResponse)
        springDamping = try c.decode(.springDamping, or: d.springDamping)
        tileGap = try c.decode(.tileGap, or: d.tileGap)
        dockClearance = try c.decode(.dockClearance, or: d.dockClearance)
        accentHex = try c.decode(.accentHex, or: d.accentHex)
        material = try c.decode(.material, or: d.material)
        appearance = try c.decode(.appearance, or: d.appearance)
        showGroupLabels = try c.decode(.showGroupLabels, or: d.showGroupLabels)
    }
}

extension BehaviorConfig {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BehaviorConfig()
        expansionMode = try c.decode(.expansionMode, or: d.expansionMode)
        suppressNativeDock = try c.decode(.suppressNativeDock, or: d.suppressNativeDock)
        focusMode = try c.decode(.focusMode, or: d.focusMode)
        showMenuBarIcon = try c.decode(.showMenuBarIcon, or: d.showMenuBarIcon)
        reserveScreenSpace = try c.decode(.reserveScreenSpace, or: d.reserveScreenSpace)
        minimizeToGroups = try c.decode(.minimizeToGroups, or: d.minimizeToGroups)
        clickActiveAppToMinimize = try c.decode(.clickActiveAppToMinimize, or: d.clickActiveAppToMinimize)
        screenSpaceExclusions = try c.decode(.screenSpaceExclusions, or: d.screenSpaceExclusions)
        language = try c.decode(.language, or: d.language)
    }
}

extension TelemetryConfig {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TelemetryConfig()
        pollInterval = try c.decode(.pollInterval, or: d.pollInterval)
        containerRuntime = try c.decode(.containerRuntime, or: d.containerRuntime)
        runtimePath = try c.decodeIfPresent(String.self, forKey: .runtimePath)
        fallbackToDocker = try c.decode(.fallbackToDocker, or: d.fallbackToDocker)
        commandTimeout = try c.decode(.commandTimeout, or: d.commandTimeout)
    }
}

extension DockGroup {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(.id, or: "")
        name = try c.decode(.name, or: "Group")
        symbol = try c.decode(.symbol, or: "square.stack.3d.up.fill")
        tintHex = try c.decodeIfPresent(String.self, forKey: .tintHex)
        apps = try c.decode(.apps, or: [])
        widget = try c.decode(.widget, or: WidgetConfig())
        layout = try c.decode(.layout, or: .splitHorizontal50_50)
        expansionMode = try c.decodeIfPresent(ExpansionMode.self, forKey: .expansionMode)
    }
}

extension DockApp {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleId = try c.decodeIfPresent(String.self, forKey: .bundleId)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        if let name = try c.decodeIfPresent(String.self, forKey: .name), !name.isEmpty {
            self.name = name
        } else if let path {
            self.name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        } else if let bundleId {
            self.name = bundleId.split(separator: ".").last.map(String.init) ?? bundleId
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .name, in: c,
                debugDescription: "An app needs at least a name, bundleId or path."
            )
        }
    }

    /// Builds an entry from an `.app` bundle on disk.
    init(url: URL) {
        name = url.deletingPathExtension().lastPathComponent
        bundleId = Bundle(url: url)?.bundleIdentifier
        path = url.path
    }
}

extension WidgetConfig {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(.type, or: .none)
        ports = try c.decode(.ports, or: [])
        command = try c.decodeIfPresent(String.self, forKey: .command)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        interval = try c.decodeIfPresent(Double.self, forKey: .interval)
        probes = try c.decode(.probes, or: [])
    }
}

extension HealthProbe {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        command = try c.decodeIfPresent(String.self, forKey: .command)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? port.map { ":\($0)" } ?? "Check"
    }
}
