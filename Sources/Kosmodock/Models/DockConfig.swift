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

/// A ready-made look for the dock bar. Picking one copies its `surface` into
/// the theme; editing those values customizes it, and restoring the style
/// copies them back. Each style keeps its own edits (`ThemeConfig.customizations`).
enum DockStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case glass
    case midnight
    case graphite
    case neon
    case paper
    case floating
    // Looks: seasonal styles, with decorations (`SeasonalDecoration`).
    case halloween
    case hauntedNight
    case candyCorn
    case christmas
    case snowyNight
    case candyCane

    var id: String { rawValue }

    var title: String {
        switch self {
        case .glass: L10n.tr("Glass")
        case .midnight: L10n.tr("Midnight")
        case .graphite: L10n.tr("Graphite")
        case .neon: L10n.tr("Neon")
        case .paper: L10n.tr("Paper")
        case .floating: L10n.tr("Floating")
        // Looks
        case .halloween: L10n.tr("Halloween")
        case .hauntedNight: L10n.tr("Haunted Night")
        case .candyCorn: L10n.tr("Candy Corn")
        case .christmas: L10n.tr("Christmas")
        case .snowyNight: L10n.tr("Snowy Night")
        case .candyCane: L10n.tr("Candy Cane")
        }
    }

    var summary: String {
        switch self {
        case .glass: L10n.tr("The macOS glass, following light and dark mode.")
        case .midnight: L10n.tr("Dark glass with a crisp light border.")
        case .graphite: L10n.tr("Dark gradient, blue edge and a soft glow.")
        case .neon: L10n.tr("Black bar, magenta edge and a cyan glow.")
        case .paper: L10n.tr("Almost white, with a quiet border and short corners.")
        case .floating: L10n.tr("No bar: each capsule floats on its own glass.")
        // Looks
        case .halloween: L10n.tr("Purple and orange, lit pumpkins, bats and cobwebs.")
        case .hauntedNight: L10n.tr("Ghostly green, rising fog, dripping slime and little ghosts.")
        case .candyCorn: L10n.tr("Cream and orange, falling leaves and candies.")
        case .christmas: L10n.tr("Pine green and gold, snow, icicles and twinkling lights.")
        case .snowyNight: L10n.tr("Cold night blue, falling snow and warm lights.")
        case .candyCane: L10n.tr("White with a striped border, snow and red and green lights.")
        }
    }

    var surface: DockSurface {
        switch self {
        case .glass:
            DockSurface()
        case .midnight:
            DockSurface(
                fillTopHex: "#151C36", fillBottomHex: "#070B18", fillOpacity: 0.62,
                borderOpacity: 0.45, specularBorder: false, sheen: false
            )
        case .graphite:
            DockSurface(
                fillTopHex: "#3A3F4B", fillBottomHex: "#0E1014", fillOpacity: 0.86,
                borderHex: "#8FB6FF", borderOpacity: 0.55, specularBorder: false,
                glowHex: "#4C8DFF", glowOpacity: 0.55, cornerRadius: 12, reflection: true
            )
        case .neon:
            DockSurface(
                fillTopHex: "#0A0A12", fillBottomHex: "#000000", fillOpacity: 0.9,
                borderHex: "#FF2BD6", borderOpacity: 0.9, borderWidth: 1.5, specularBorder: false,
                glowHex: "#00E5FF", glowOpacity: 0.75, sheen: false, cornerRadius: 26
            )
        case .paper:
            DockSurface(
                fillTopHex: "#FFFFFF", fillBottomHex: "#F1F1EE", fillOpacity: 0.96,
                borderHex: "#C9C9C4", borderOpacity: 0.8, specularBorder: false,
                sheen: false, cornerRadius: 14
            )
        case .floating:
            DockSurface(blur: false, fillOpacity: 0, borderOpacity: 0, borderWidth: 0, sheen: false, reflection: true)
        // Looks
        case .halloween:
            DockSurface(
                fillTopHex: "#3E1660", fillBottomHex: "#B4500F", fillOpacity: 0.9,
                borderHex: "#FF9A3D", borderOpacity: 0.6, specularBorder: false,
                glowHex: "#FF7A1A", glowOpacity: 0.3, sheen: false, cornerRadius: 20, decorations: decorationOptions
            )
        case .hauntedNight:
            DockSurface(
                fillTopHex: "#123A2C", fillBottomHex: "#03110C", fillOpacity: 0.88,
                borderHex: "#9CFFC4", borderOpacity: 0.5, specularBorder: false,
                glowHex: "#5CFF9D", glowOpacity: 0.4, sheen: false, cornerRadius: 20, decorations: decorationOptions
            )
        case .candyCorn:
            DockSurface(
                fillTopHex: "#FFF3D6", fillBottomHex: "#F7A54A", fillOpacity: 0.95,
                borderHex: "#E2761B", borderOpacity: 0.75, specularBorder: false,
                cornerRadius: 18, decorations: decorationOptions
            )
        case .christmas:
            DockSurface(
                fillTopHex: "#1F5537", fillBottomHex: "#0B2A1A", fillOpacity: 0.92,
                borderHex: "#E9C46A", borderOpacity: 0.9, borderWidth: 1.5, specularBorder: false,
                glowHex: "#E9C46A", glowOpacity: 0.22, sheen: false, cornerRadius: 18, decorations: decorationOptions
            )
        case .snowyNight:
            DockSurface(
                fillTopHex: "#1C2C52", fillBottomHex: "#080F24", fillOpacity: 0.86,
                borderHex: "#C4DAFF", borderOpacity: 0.5, specularBorder: false,
                glowHex: "#9CC2FF", glowOpacity: 0.22, cornerRadius: 22, decorations: decorationOptions
            )
        case .candyCane:
            DockSurface(
                fillTopHex: "#FFFFFF", fillBottomHex: "#F4EFEF", fillOpacity: 0.96,
                borderHex: "#D7263D", borderOpacity: 0.9, borderWidth: 2, specularBorder: false,
                sheen: false, cornerRadius: 20, decorations: decorationOptions
            )
        }
    }
}

/// What draws the bar: the values a `DockStyle` sets and Settings fine-tunes.
struct DockSurface: Codable, Equatable, Sendable {
    /// Behind-window vibrancy under the fill.
    var blur = true
    var material: GlassMaterial = .hudWindow
    /// Fill from top to bottom. Without colors it's the window background,
    /// which follows light and dark mode.
    var fillTopHex: String?
    var fillBottomHex: String?
    /// Turns the fill's direction clockwise, in degrees; 0 runs top to bottom.
    var fillAngle = 0.0
    /// Opacity of the fill over the blur (0 = pure glass, 1 = solid).
    var fillOpacity = 0.35
    var borderHex = "#FFFFFF"
    var borderOpacity = 0.6
    var borderWidth = 1.0
    /// Brighter at the top, like light on glass, instead of an even line.
    var specularBorder = true
    var glowHex = "#FFFFFF"
    /// Colored halo around the bar; 0 turns it off.
    var glowOpacity = 0.0
    /// Soft highlight across the top half.
    var sheen = true
    var cornerRadius = 22.0
    /// A faded mirror image under each app icon on the dock.
    var reflection = false
    /// Looks: drawn over and around the bar, in `SeasonalDecoration` order.
    var decorations: [SeasonalDecoration] = []

    // Declared because both coding directions are hand-written (see the extension).
    enum CodingKeys: String, CodingKey {
        case blur, material, fillTopHex, fillBottomHex, fillAngle, fillOpacity, borderHex, borderOpacity
        case borderWidth, specularBorder, glowHex, glowOpacity, sheen, cornerRadius, reflection
        case decorations
    }

    /// Whether there's a bar at all. Without one, capsules get their own glass.
    var isVisible: Bool {
        blur || fillOpacity > 0 || (borderOpacity > 0 && borderWidth > 0)
    }
}

/// What grows under the pointer.
enum HoverEffect: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    /// A capsule, icon or tile grows slightly.
    case scale
    /// Icons grow with their neighbors, like the macOS Dock's magnification.
    case magnify

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: L10n.tr("None")
        case .scale: L10n.tr("Scale")
        case .magnify: L10n.tr("Magnify")
        }
    }
}

/// How an app's icon moves while the app launches.
enum LaunchAnimation: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case bounce
    case pulse
    case shake

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: L10n.tr("No animation")
        case .bounce: L10n.tr("Bounce")
        case .pulse: L10n.tr("Pulse")
        case .shake: L10n.tr("Shake")
        }
    }
}

/// The mark under a running app's icon.
enum IndicatorStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case dot
    case line
    case hidden

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dot: L10n.tr("Dot")
        case .line: L10n.tr("Line")
        case .hidden: L10n.tr("Hidden")
        }
    }
}

enum IndicatorColor: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The accent for the frontmost app, a neutral mark for the others.
    case accent
    /// The app's group tint.
    case group

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accent: L10n.tr("Accent")
        case .group: L10n.tr("Group color")
        }
    }
}

/// What a widget tile on the bar shows.
enum TileKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case clock
    case battery
    case activity
    case network
    case claudeCode
    case nowPlaying
    case calendar
    case github
    case codex
    case reminders
    // Time widgets
    case timer
    case pomodoro
    case countdown
    case stopwatch
    case timeProgress
    // File and sharing widgets
    case screenshots
    case shelf
    case files
    case bookmarks
    case appCollection
    case shortcut
    case airDrop
    // Looks
    case pet
    // Utility widgets
    case note
    case water
    case converter
    case emoji
    case colorPicker
    case clipboard
    case weather
    case command

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clock: L10n.tr("Clock")
        case .battery: L10n.tr("Battery")
        case .activity: L10n.tr("CPU & Memory")
        case .network: L10n.tr("Network")
        case .claudeCode: "Claude Code"
        case .nowPlaying: L10n.tr("Now Playing")
        case .calendar: L10n.tr("Calendar")
        case .github: "GitHub"
        case .codex: "Codex"
        case .reminders: L10n.tr("Reminders")
        // Time widgets
        case .timer: L10n.tr("Timer")
        case .pomodoro: L10n.tr("Pomodoro")
        case .countdown: L10n.tr("Countdown")
        case .stopwatch: L10n.tr("Stopwatch")
        case .timeProgress: L10n.tr("Time Progress")
        case .screenshots: L10n.tr("Screenshots")
        case .shelf: L10n.tr("Shelf")
        case .files: L10n.tr("Recent Files")
        case .bookmarks: L10n.tr("Bookmarks")
        case .appCollection: L10n.tr("App Collection")
        case .shortcut: L10n.tr("Shortcut")
        case .airDrop: "AirDrop"
        case .pet: L10n.tr("Pet")
        case .note, .water, .converter, .emoji, .colorPicker, .clipboard, .weather: utilityTitle
        case .command: L10n.tr("Command")
        }
    }

    var symbol: String {
        switch self {
        case .clock: "clock"
        case .battery: "battery.75percent"
        case .activity: "cpu"
        case .network: "arrow.up.arrow.down"
        case .claudeCode: "sparkle"
        case .nowPlaying: "music.note"
        case .calendar: "calendar"
        case .github: "arrow.triangle.pull"
        case .codex: "curlybraces"
        case .reminders: "checklist"
        // Time widgets
        case .timer: "timer"
        case .pomodoro: "brain.head.profile"
        case .countdown: "hourglass"
        case .stopwatch: "stopwatch"
        case .timeProgress: "calendar.day.timeline.left"
        case .screenshots: "camera.viewfinder"
        case .shelf: "tray.full"
        case .files: "folder"
        case .bookmarks: "bookmark"
        case .appCollection: "square.grid.2x2"
        case .shortcut: "square.3.layers.3d"
        case .airDrop: "dot.radiowaves.left.and.right"
        case .pet: "pawprint.fill"
        case .note, .water, .converter, .emoji, .colorPicker, .clipboard, .weather: utilitySymbol
        case .command: "terminal"
        }
    }

    enum Category: CaseIterable {
        /// The Mac's own readings.
        case system
        /// Clocks, timers and counters.
        case time
        /// Data from other apps.
        case apps
        /// Files on this Mac, and sending them.
        case files
        /// Small tools: notes, converters, pickers.
        case utilities
        /// Your own: a script, links, apps or a shortcut.
        case custom

        var title: String {
            switch self {
            case .system: L10n.tr("System")
            case .time: L10n.tr("Time")
            case .apps: L10n.tr("Apps")
            case .files: L10n.tr("Files & Sharing")
            case .utilities: L10n.tr("Utilities")
            case .custom: L10n.tr("Custom")
            }
        }
    }

    var category: Category {
        switch self {
        case .battery, .activity, .network: .system
        case .clock, .timer, .pomodoro, .countdown, .stopwatch, .timeProgress: .time
        // Looks
        case .pet: .system
        case .claudeCode, .nowPlaying, .calendar, .github, .codex, .reminders: .apps
        case .screenshots, .shelf, .files, .airDrop: .files
        case .bookmarks, .appCollection, .shortcut: .custom
        case .note, .water, .converter, .emoji, .colorPicker, .clipboard, .weather: .utilities
        case .command: .custom
        }
    }
}

enum TileWidth: String, Codable, CaseIterable, Identifiable, Sendable {
    /// One icon wide, for a single reading.
    case square
    /// Room for a reading and its details.
    case wide

    var id: String { rawValue }

    var title: String {
        switch self {
        case .square: L10n.tr("Square")
        case .wide: L10n.tr("Wide")
        }
    }
}

/// A widget on the bar on its own, after the group capsules. Its width comes
/// from `width`, never from what it shows, so readings don't resize the dock.
struct DockTile: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var kind: TileKind
    var width: TileWidth = .wide
    /// Clock: show seconds in the wide tile and the details.
    var showsSeconds = false
    /// Command: what to run and its label.
    var command: String?
    var label: String?
    /// Command: seconds between runs; `telemetry.pollInterval` when unset.
    var interval: Double?
    // Time widgets (`TimeWidgets.swift`); unset options use their defaults.
    /// Clock: a `TimeZone` identifier ("Asia/Tokyo"); this Mac's when unset.
    var timeZone: String?
    /// Clock: the square tile's face.
    var face: ClockFace?
    var timer: TimerOptions?
    var pomodoro: PomodoroOptions?
    /// Countdown: its date; `label` names it.
    var countdown: CountdownOptions?
    /// Time progress: day, week, month or year.
    var period: TimePeriod?
    /// The tiles stacked under this one, in order (`WidgetStacks.swift`).
    var stack: [String]?
    // File and sharing widgets (Models/FileWidgets.swift). Unset is the default.
    /// Screenshots, files: how many the details show (6–60).
    var fileCount: Int?
    /// Screenshots, files: what clicking one does.
    var fileAction: FileClickAction?
    /// Files: the folder shown; Downloads when unset.
    var filesFolder: String?
    /// Shelf: paths of the parked files, newest first.
    var shelfItems: [String]?
    /// Shelf: a file dragged out leaves the shelf.
    var removesOnDragOut: Bool?
    var bookmarks: [Bookmark]?
    /// Bookmarks: the browser's bundle id; the default browser when unset.
    var bookmarkBrowser: String?
    var collectionApps: [DockApp]?
    var collectionLayout: CollectionLayout?
    /// Shortcut: the name in the Shortcuts app, and the tile's symbol and color.
    var shortcutName: String?
    var shortcutSymbol: String?
    var shortcutTintHex: String?
    /// Pet: its animal and how it behaves (`petOptions`).
    var pet: PetOptions?
    // Utility widgets' options (UtilityWidgetServices.swift); nil means the defaults.
    var note: NoteOptions?
    var water: WaterOptions?
    var emoji: EmojiOptions?
    var colors: ColorPickerOptions?
    var clipboard: ClipboardOptions?
    var weather: WeatherOptions?
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
    var tiles: [DockTile] = []
    /// Apps on the bar on their own, as plain icons.
    var pinnedApps: [DockApp] = []
    /// Item ids in bar order (see `barOrder`).
    var order: [String] = []
    /// Bars to switch between (`Workspaces.swift`); none is a single bar.
    var workspaces: [Workspace] = []
    var activeWorkspaceID: String?
    /// Folder stacks and spacers on the bar (`DockItems.swift`).
    var folders: [DockFolder] = []
    var spacers: [DockSpacer] = []
    /// The Trash at the end of the bar.
    var showsTrash = false
}

extension DockConfig {
    /// A pinned app's id wherever group ids are used: bar order, frames,
    /// minimized windows. Group ids are slugs, so they never contain a colon.
    static func itemID(forPinned app: DockApp) -> String { "app:\(app.id)" }
    static func itemID(for tile: DockTile) -> String { "tile:\(tile.id)" }

    /// The bar's item ids in order: `order` first, without unknown or repeated
    /// ids, then whatever it leaves out, as pinned apps, groups, tiles, folders,
    /// spacers. The Trash is never in it: it's always last. An
    /// empty `order` (configs from before it) gives exactly that default.
    /// With workspaces, the active one's items, and only those.
    var barOrder: [String] {
        let defaults = pinnedApps.map(Self.itemID(forPinned:)) + groups.map(\.id) + barTiles.map(Self.itemID(for:))
            + folders.map(Self.itemID(for:)) + spacers.map(Self.itemID(for:))
        let known = Set(defaults)
        var seen = Set<String>()
        var result = activeOrder.filter { known.contains($0) && seen.insert($0).inserted }
        if activeWorkspace == nil { result += defaults.filter { !seen.contains($0) } }
        return result
    }

    /// Fixes the current bar order in `activeOrder`, so an item added
    /// afterwards lands at the end instead of in its default place.
    mutating func settleOrder() {
        activeOrder = barOrder
    }

    mutating func moveBarItems(fromOffsets source: IndexSet, toOffset destination: Int) {
        activeOrder = barOrder.moved(fromOffsets: source, toOffset: destination)
    }

    mutating func moveBarItem(_ id: String, by offset: Int) {
        var ids = barOrder
        guard let index = ids.firstIndex(of: id) else { return }
        let target = min(max(0, index + offset), ids.count - 1)
        guard target != index else { return }
        ids.swapAt(index, target)
        activeOrder = ids
    }

    /// Reorders groups among the places groups take on the bar, so moving one
    /// in the sidebar leaves pinned apps and tiles where they are. Offsets are
    /// in `sidebarGroupIDs`, which ends with groups the workspace hides.
    mutating func moveGroups(fromOffsets source: IndexSet, toOffset destination: Int) {
        let sidebar = sidebarGroupIDs.moved(fromOffsets: source, toOffset: destination)
        let ids = barOrder
        let shown = Set(ids).intersection(groups.map(\.id))
        var moved = sidebar.filter(shown.contains).makeIterator()
        activeOrder = ids.map { shown.contains($0) ? (moved.next() ?? $0) : $0 }
        let position = Dictionary(uniqueKeysWithValues: sidebar.enumerated().map { ($0.element, $0.offset) })
        groups.sort { (position[$0.id] ?? 0) < (position[$1.id] ?? 0) }
    }
}

extension Array {
    /// SwiftUI's `move(fromOffsets:toOffset:)`, for the model, which doesn't import SwiftUI.
    func moved(fromOffsets source: IndexSet, toOffset destination: Int) -> [Element] {
        let moving = source.filter(indices.contains).map { self[$0] }
        var rest = enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertion = destination - source.filter { $0 < destination }.count
        rest.insert(contentsOf: moving, at: Swift.max(0, Swift.min(insertion, rest.count)))
        return rest
    }
}

struct ThemeConfig: Codable, Equatable, Sendable {
    /// The style `surface` started from; restoring copies its values back.
    var style: DockStyle = .glass
    var surface = DockStyle.glass.surface
    /// Edited surfaces of the other styles, by `DockStyle.rawValue`, so picking
    /// one again brings its edits back. The selected style's live in `surface`.
    var customizations: [String: DockSurface] = [:]
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
    var appearance: AppearanceMode = .system
    var showGroupLabels: Bool = true
    /// Every collapsed group takes the widest one's width, instead of its own.
    var equalGroupWidths: Bool = false
    var hoverEffect: HoverEffect = .scale
    var launchAnimation: LaunchAnimation = .bounce
    var indicatorStyle: IndicatorStyle = .dot
    var indicatorColor: IndicatorColor = .accent
    // Looks
    /// Folder name of the icon pack in `icon-packs/` drawn for every app it covers.
    var iconPack: String?
    /// Custom icons by bundle id (or `DockApp.id`): an image path, or "" for
    /// the app's own icon even when a pack covers it.
    var appIcons: [String: String] = [:]

    /// The surface was edited after its style was picked.
    var isCustomized: Bool { surface != style.surface }

    /// What `style` draws with: the live surface when it's selected, otherwise
    /// its kept edits or its preset.
    func surface(for style: DockStyle) -> DockSurface {
        style == self.style ? surface : customizations[style.rawValue] ?? style.surface
    }

    func isCustomized(_ style: DockStyle) -> Bool { surface(for: style) != style.surface }

    /// Switches styles, keeping the current one's edits for when it's picked again.
    mutating func apply(_ next: DockStyle) {
        customizations[style.rawValue] = isCustomized ? surface : nil
        style = next
        surface = customizations.removeValue(forKey: next.rawValue) ?? next.surface
    }

    /// Throws away the selected style's edits.
    mutating func restore() {
        customizations[style.rawValue] = nil
        surface = style.surface
    }

    /// Popovers stay on glass: a neon or paper popover would be hard to read.
    /// With the glass style they follow its edits.
    var popoverSurface: DockSurface { style == .glass ? surface : DockStyle.glass.surface }
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
    /// App badges ("3", "•") read from the native Dock through Accessibility.
    var showsNotificationBadges: Bool = true
    /// Right-clicking an app adds the items of its own Dock menu, read from
    /// the native Dock through Accessibility.
    var showsAppDockMenu: Bool = true
    /// Resting the pointer on a running app's icon shows its windows.
    var showsWindowPreviews: Bool = true
    /// Seconds the pointer rests before the previews show (0…2).
    var windowPreviewDelay: Double = 0.4
    var windowPreviewsNeedTwoWindows: Bool = false
    /// ⌃⌥D puts keyboard focus on the dock.
    var dockFocusHotKey: Bool = true
    /// While files are dragged anywhere, a tray takes them to the shelf.
    var dropZone: Bool = false
    var dropZonePlacement: DropZonePlacement = .bottomLeft
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
        tiles = DockConfig.normalizedTileIDs(try c.decode(.tiles, or: []))
        var pinnedIDs = Set<String>()
        pinnedApps = try c.decode(.pinnedApps, or: [DockApp]()).filter { pinnedIDs.insert($0.id).inserted }
        order = try c.decode(.order, or: [])
        workspaces = DockConfig.normalizedWorkspaceIDs(try c.decode(.workspaces, or: []))
        activeWorkspaceID = try c.decodeIfPresent(String.self, forKey: .activeWorkspaceID)
        folders = DockConfig.normalizedFolderIDs(try c.decode(.folders, or: []))
        spacers = DockConfig.normalizedSpacerIDs(try c.decode(.spacers, or: []))
        showsTrash = try c.decode(.showsTrash, or: false)
    }

    /// Unique tile ids, derived from the kind when missing.
    static func normalizedTileIDs(_ tiles: [DockTile]) -> [DockTile] {
        var seen = Set<String>()
        return tiles.map { tile in
            var tile = tile
            var base = tile.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if base.isEmpty { base = tile.kind.rawValue }
            var candidate = base
            var suffix = 2
            while seen.contains(candidate) {
                candidate = "\(base)-\(suffix)"
                suffix += 1
            }
            seen.insert(candidate)
            tile.id = candidate
            return tile
        }
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
    /// Before styles, the glass look's values sat on the theme itself.
    private enum LegacyKeys: String, CodingKey {
        case cornerRadius, glassOpacity, borderOpacity, material
    }

    private struct StyleKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ThemeConfig()
        style = try c.decode(.style, or: d.style)
        if c.contains(.surface) {
            // Missing surface keys fall back to the style's own values.
            surface = try DockSurface(from: c.superDecoder(forKey: .surface), defaults: style.surface)
        } else if c.contains(.style) {
            surface = style.surface
        } else {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            surface = style.surface
            surface.cornerRadius = try legacy.decode(.cornerRadius, or: surface.cornerRadius)
            surface.fillOpacity = try legacy.decode(.glassOpacity, or: surface.fillOpacity)
            surface.borderOpacity = try legacy.decode(.borderOpacity, or: surface.borderOpacity)
            surface.material = try legacy.decode(.material, or: surface.material)
        }
        if c.contains(.customizations), try !c.decodeNil(forKey: .customizations) {
            let kept = try c.nestedContainer(keyedBy: StyleKey.self, forKey: .customizations)
            for key in kept.allKeys {
                // Missing keys fall back to that style's values, as in `surface`. A style
                // this version doesn't know (from a newer one) is kept as it is.
                let defaults = DockStyle(rawValue: key.stringValue)?.surface ?? DockSurface()
                customizations[key.stringValue] = try DockSurface(from: kept.superDecoder(forKey: key), defaults: defaults)
            }
        }
        iconSize = try c.decode(.iconSize, or: d.iconSize)
        dockMargin = try c.decode(.dockMargin, or: d.dockMargin)
        springResponse = try c.decode(.springResponse, or: d.springResponse)
        springDamping = try c.decode(.springDamping, or: d.springDamping)
        tileGap = try c.decode(.tileGap, or: d.tileGap)
        dockClearance = try c.decode(.dockClearance, or: d.dockClearance)
        accentHex = try c.decode(.accentHex, or: d.accentHex)
        appearance = try c.decode(.appearance, or: d.appearance)
        showGroupLabels = try c.decode(.showGroupLabels, or: d.showGroupLabels)
        equalGroupWidths = try c.decode(.equalGroupWidths, or: d.equalGroupWidths)
        hoverEffect = try c.decode(.hoverEffect, or: d.hoverEffect)
        launchAnimation = try c.decode(.launchAnimation, or: d.launchAnimation)
        indicatorStyle = try c.decode(.indicatorStyle, or: d.indicatorStyle)
        indicatorColor = try c.decode(.indicatorColor, or: d.indicatorColor)
        iconPack = try c.decodeIfPresent(String.self, forKey: .iconPack)
        appIcons = try c.decode(.appIcons, or: d.appIcons)
    }
}

extension DockSurface {
    init(from decoder: Decoder) throws {
        try self.init(from: decoder, defaults: DockSurface())
    }

    init(from decoder: Decoder, defaults d: DockSurface) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        blur = try c.decode(.blur, or: d.blur)
        material = try c.decode(.material, or: d.material)
        // A key that's present but null means "window background", not "missing".
        fillTopHex = c.contains(.fillTopHex) ? try c.decodeIfPresent(String.self, forKey: .fillTopHex) : d.fillTopHex
        fillBottomHex = c.contains(.fillBottomHex) ? try c.decodeIfPresent(String.self, forKey: .fillBottomHex) : d.fillBottomHex
        fillAngle = try c.decode(.fillAngle, or: d.fillAngle)
        fillOpacity = try c.decode(.fillOpacity, or: d.fillOpacity)
        borderHex = try c.decode(.borderHex, or: d.borderHex)
        borderOpacity = try c.decode(.borderOpacity, or: d.borderOpacity)
        borderWidth = try c.decode(.borderWidth, or: d.borderWidth)
        specularBorder = try c.decode(.specularBorder, or: d.specularBorder)
        glowHex = try c.decode(.glowHex, or: d.glowHex)
        glowOpacity = try c.decode(.glowOpacity, or: d.glowOpacity)
        sheen = try c.decode(.sheen, or: d.sheen)
        cornerRadius = try c.decode(.cornerRadius, or: d.cornerRadius)
        reflection = try c.decode(.reflection, or: d.reflection)
        decorations = SeasonalDecoration.normalized(try c.decode(.decorations, or: d.decorations))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(blur, forKey: .blur)
        try c.encode(material, forKey: .material)
        // Written as null when unset, or loading would bring back the style's colors.
        try c.encode(fillTopHex, forKey: .fillTopHex)
        try c.encode(fillBottomHex, forKey: .fillBottomHex)
        try c.encode(fillAngle, forKey: .fillAngle)
        try c.encode(fillOpacity, forKey: .fillOpacity)
        try c.encode(borderHex, forKey: .borderHex)
        try c.encode(borderOpacity, forKey: .borderOpacity)
        try c.encode(borderWidth, forKey: .borderWidth)
        try c.encode(specularBorder, forKey: .specularBorder)
        try c.encode(glowHex, forKey: .glowHex)
        try c.encode(glowOpacity, forKey: .glowOpacity)
        try c.encode(sheen, forKey: .sheen)
        try c.encode(cornerRadius, forKey: .cornerRadius)
        try c.encode(reflection, forKey: .reflection)
        try c.encode(decorations, forKey: .decorations)
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
        showsNotificationBadges = try c.decode(.showsNotificationBadges, or: d.showsNotificationBadges)
        showsAppDockMenu = try c.decode(.showsAppDockMenu, or: d.showsAppDockMenu)
        showsWindowPreviews = try c.decode(.showsWindowPreviews, or: d.showsWindowPreviews)
        windowPreviewDelay = try c.decode(.windowPreviewDelay, or: d.windowPreviewDelay)
        windowPreviewsNeedTwoWindows = try c.decode(.windowPreviewsNeedTwoWindows, or: d.windowPreviewsNeedTwoWindows)
        dockFocusHotKey = try c.decode(.dockFocusHotKey, or: d.dockFocusHotKey)
        dropZone = try c.decode(.dropZone, or: d.dropZone)
        dropZonePlacement = try c.decode(.dropZonePlacement, or: d.dropZonePlacement)
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

extension DockTile {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(.id, or: "")
        // No sensible default: a tile without a kind is reported.
        kind = try c.decode(TileKind.self, forKey: .kind)
        width = try c.decode(.width, or: .wide)
        showsSeconds = try c.decode(.showsSeconds, or: false)
        command = try c.decodeIfPresent(String.self, forKey: .command)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        interval = try c.decodeIfPresent(Double.self, forKey: .interval)
        // Time widgets
        timeZone = try c.decodeIfPresent(String.self, forKey: .timeZone)
        face = try c.decodeIfPresent(ClockFace.self, forKey: .face)
        timer = try c.decodeIfPresent(TimerOptions.self, forKey: .timer)
        pomodoro = try c.decodeIfPresent(PomodoroOptions.self, forKey: .pomodoro)
        countdown = try c.decodeIfPresent(CountdownOptions.self, forKey: .countdown)
        period = try c.decodeIfPresent(TimePeriod.self, forKey: .period)
        stack = try c.decodeIfPresent([String].self, forKey: .stack)
        // File and sharing widgets
        fileCount = try c.decodeIfPresent(Int.self, forKey: .fileCount)
        fileAction = try c.decodeIfPresent(FileClickAction.self, forKey: .fileAction)
        filesFolder = try c.decodeIfPresent(String.self, forKey: .filesFolder)
        shelfItems = try c.decodeIfPresent([String].self, forKey: .shelfItems)
        removesOnDragOut = try c.decodeIfPresent(Bool.self, forKey: .removesOnDragOut)
        bookmarks = try c.decodeIfPresent([Bookmark].self, forKey: .bookmarks)
        bookmarkBrowser = try c.decodeIfPresent(String.self, forKey: .bookmarkBrowser)
        collectionApps = try c.decodeIfPresent([DockApp].self, forKey: .collectionApps)
        collectionLayout = try c.decodeIfPresent(CollectionLayout.self, forKey: .collectionLayout)
        shortcutName = try c.decodeIfPresent(String.self, forKey: .shortcutName)
        shortcutSymbol = try c.decodeIfPresent(String.self, forKey: .shortcutSymbol)
        shortcutTintHex = try c.decodeIfPresent(String.self, forKey: .shortcutTintHex)
        pet = try c.decodeIfPresent(PetOptions.self, forKey: .pet)
        note = try c.decodeIfPresent(NoteOptions.self, forKey: .note)
        water = try c.decodeIfPresent(WaterOptions.self, forKey: .water)
        emoji = try c.decodeIfPresent(EmojiOptions.self, forKey: .emoji)
        colors = try c.decodeIfPresent(ColorPickerOptions.self, forKey: .colors)
        clipboard = try c.decodeIfPresent(ClipboardOptions.self, forKey: .clipboard)
        weather = try c.decodeIfPresent(WeatherOptions.self, forKey: .weather)
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
