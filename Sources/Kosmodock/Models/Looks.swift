import Foundation

// Looks: seasonal styles' decorations and the pet tile's options and
// behavior. Drawing lives in `Views/SeasonalDecorations.swift` and
// `Views/PetTile.swift`; this is the part that's saved and tested.

// MARK: - Seasonal decorations

/// Something a seasonal style draws over and around the bar. A style's
/// preset turns all of its own on (`DockStyle.decorationOptions`), and each
/// has its own toggle, so turning one off customizes the style.
enum SeasonalDecoration: String, Codable, CaseIterable, Identifiable, Sendable {
    // Halloween
    case pumpkins
    case bats
    case cobwebs
    // Haunted Night
    case fog
    case slime
    case ghosts
    // Candy Corn
    case leaves
    case leafPile
    case candies
    // Winter
    case snow
    case snowCap
    case icicles
    case twinkleLights
    case warmLights
    case candyLights
    case candyStripes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pumpkins: L10n.tr("Lit pumpkins")
        case .bats: L10n.tr("Bats")
        case .cobwebs: L10n.tr("Cobwebs and spider")
        case .fog: L10n.tr("Rising fog")
        case .slime: L10n.tr("Dripping slime")
        case .ghosts: L10n.tr("Little ghosts")
        case .leaves: L10n.tr("Falling leaves")
        case .leafPile: L10n.tr("Leaves on the edge")
        case .candies: L10n.tr("Candies")
        case .snow: L10n.tr("Falling snow")
        case .snowCap: L10n.tr("Snow on the edge")
        case .icicles: L10n.tr("Icicles")
        case .twinkleLights: L10n.tr("Twinkling lights")
        case .warmLights: L10n.tr("Warm lights")
        case .candyLights: L10n.tr("Red and green lights")
        case .candyStripes: L10n.tr("Striped border")
        }
    }

    /// Moves over time. A bar with only still decorations draws one frame.
    var isAnimated: Bool {
        switch self {
        case .leafPile, .candies, .snowCap, .icicles, .candyStripes: false
        default: true
        }
    }

    /// Each decoration once, in declaration order, so the same choice always
    /// compares equal and saves the same.
    static func normalized(_ decorations: [SeasonalDecoration]) -> [SeasonalDecoration] {
        allCases.filter(decorations.contains)
    }
}

extension DockStyle {
    /// The sections of the style picker.
    enum Family: CaseIterable, Sendable {
        case classic
        case seasonal

        var title: String {
            switch self {
            case .classic: L10n.tr("Styles")
            case .seasonal: L10n.tr("Seasonal")
            }
        }
    }

    var family: Family {
        decorationOptions.isEmpty ? .classic : .seasonal
    }

    /// The decorations the style comes with, each with its own toggle.
    var decorationOptions: [SeasonalDecoration] {
        switch self {
        case .glass, .midnight, .graphite, .neon, .paper, .floating: []
        case .halloween: [.pumpkins, .bats, .cobwebs]
        case .hauntedNight: [.fog, .slime, .ghosts]
        case .candyCorn: [.leaves, .leafPile, .candies]
        case .christmas: [.snow, .snowCap, .icicles, .twinkleLights]
        case .snowyNight: [.snow, .warmLights]
        case .candyCane: [.snowCap, .candyLights, .candyStripes]
        }
    }
}

// MARK: - Pet options

enum PetAnimal: String, Codable, CaseIterable, Identifiable, Sendable {
    case cat
    case dog
    case bird
    case hare
    case tortoise
    case lizard
    case fish
    case ladybug

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cat: L10n.tr("Cat")
        case .dog: L10n.tr("Dog")
        case .bird: L10n.tr("Bird")
        case .hare: L10n.tr("Hare")
        case .tortoise: L10n.tr("Tortoise")
        case .lizard: L10n.tr("Lizard")
        case .fish: L10n.tr("Fish")
        case .ladybug: L10n.tr("Ladybug")
        }
    }

    var symbol: String { "\(rawValue).fill" }

    /// The coat when none is chosen.
    var naturalHex: String {
        switch self {
        case .cat: "#E8913A"
        case .dog: "#A8743F"
        case .bird: "#4FA3E0"
        case .hare: "#C9B79C"
        case .tortoise: "#5E9C4C"
        case .lizard: "#6CBF4A"
        case .fish: "#F2994A"
        case .ladybug: "#E0393E"
        }
    }

    /// Degrees that turn the symbol's head to the right: the ladybug's
    /// points up and the lizard's up and right.
    var heading: Double {
        switch self {
        case .ladybug: 90
        case .lizard: 35
        default: 0
        }
    }
}

/// Ready-made coats; any other color is a custom one.
enum PetCoat: String, CaseIterable, Identifiable, Sendable {
    case natural
    case ginger
    case black
    case white
    case gray
    case brown
    case golden

    var id: String { rawValue }

    var title: String {
        switch self {
        case .natural: L10n.tr("Natural")
        case .ginger: L10n.tr("Ginger")
        case .black: L10n.tr("Black")
        case .white: L10n.tr("White")
        case .gray: L10n.tr("Gray")
        case .brown: L10n.tr("Brown")
        case .golden: L10n.tr("Golden")
        }
    }

    /// `nil` is the animal's own color.
    var hex: String? {
        switch self {
        case .natural: nil
        case .ginger: "#E07B2E"
        case .black: "#26262B"
        case .white: "#F4F2EC"
        case .gray: "#8E8E96"
        case .brown: "#7A4A26"
        case .golden: "#E3B448"
        }
    }

    init?(hex: String?) {
        guard let match = Self.allCases.first(where: { $0.hex?.uppercased() == hex?.uppercased() }) else { return nil }
        self = match
    }
}

enum PetSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case small
    case medium
    case large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: L10n.tr("Small")
        case .medium: L10n.tr("Medium")
        case .large: L10n.tr("Large")
        }
    }

    /// Symbol size as a share of the tile's height.
    var tileFactor: Double {
        switch self {
        case .small: 0.36
        case .medium: 0.46
        case .large: 0.58
        }
    }

    /// Symbol size on top of the bar, in points: it has to fit, hopping, in
    /// the panel's inset above the bar (`DockMetrics.shadowInset`).
    var barPoints: Double {
        switch self {
        case .small: 11
        case .medium: 14
        case .large: 18
        }
    }
}

/// The reading the pet follows.
enum PetMetric: String, Codable, CaseIterable, Identifiable, Sendable {
    case cpu
    case memory

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: L10n.tr("CPU")
        case .memory: L10n.tr("Memory")
        }
    }
}

struct PetOptions: Codable, Equatable, Sendable {
    var animal: PetAnimal = .cat
    /// `#RRGGBB`; `nil` is the animal's own color.
    var coatHex: String?
    var size: PetSize = .medium
    var follows: PetMetric = .cpu
    /// Walks along the top of the whole bar instead of in its tile.
    var roams = false
    /// Keeps walking along the bottom of the screen while Intellihide hides the dock.
    var staysVisible = false

    var coat: String { coatHex ?? animal.naturalHex }
}

extension PetOptions {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PetOptions()
        animal = try c.decode(.animal, or: d.animal)
        coatHex = try c.decodeIfPresent(String.self, forKey: .coatHex)
        size = try c.decode(.size, or: d.size)
        follows = try c.decode(.follows, or: d.follows)
        roams = try c.decode(.roams, or: d.roams)
        staysVisible = try c.decode(.staysVisible, or: d.staysVisible)
    }
}

extension DockTile {
    var petOptions: PetOptions { pet ?? PetOptions() }
}

// MARK: - Pet behavior

/// How hard the Mac works, as the pet shows it.
enum PetActivity: Int, Comparable, Sendable {
    case sitting
    case walking
    case running

    static func < (lhs: PetActivity, rhs: PetActivity) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Loads (0…1) at which the pet starts walking and running.
    static func thresholds(for metric: PetMetric) -> (walk: Double, run: Double) {
        switch metric {
        case .cpu: (0.15, 0.5)
        // macOS keeps memory busy, so only a fuller one makes the pet move.
        case .memory: (0.6, 0.8)
        }
    }

    /// How far past a threshold the load must go before the pet changes pace,
    /// so a reading that hovers on it doesn't make it stop and go.
    static let hysteresis = 0.03

    static func level(load: Double, metric: PetMetric) -> PetActivity {
        let limits = thresholds(for: metric)
        if load >= limits.run { return .running }
        return load >= limits.walk ? .walking : .sitting
    }

    /// The activity after `previous` for a new reading.
    static func next(after previous: PetActivity?, load: Double, metric: PetMetric) -> PetActivity {
        let raw = level(load: load, metric: metric)
        guard let previous, raw != previous else { return raw }
        let short = level(load: raw > previous ? load - hysteresis : load + hysteresis, metric: metric)
        return short == previous ? previous : raw
    }
}

/// What the pet is doing right now.
enum PetMood: String, Sendable {
    case sitting
    case walking
    case running
    case sleeping
    case eating

    init(_ activity: PetActivity) {
        switch activity {
        case .sitting: self = .sitting
        case .walking: self = .walking
        case .running: self = .running
        }
    }

    var title: String {
        switch self {
        case .sitting: L10n.tr("Sitting")
        case .walking: L10n.tr("Walking")
        // Not "Running", which is an app's state.
        case .running: L10n.tr("Running around")
        case .sleeping: L10n.tr("Napping")
        case .eating: L10n.tr("Eating")
        }
    }

    var isMoving: Bool { self == .walking || self == .running }
}

/// One pet's recent past: its pace, since when the Mac is quiet, its last meal.
struct PetMemory: Equatable, Sendable {
    /// Quiet this long and the pet falls asleep.
    static let sleepAfter: TimeInterval = 120
    /// How long a meal lasts.
    static let mealLength: TimeInterval = 6

    var activity: PetActivity?
    /// When the Mac went quiet; `nil` while it works.
    var quietSince: Date?
    var fedAt: Date?

    mutating func record(load: Double, metric: PetMetric, at now: Date) {
        let next = PetActivity.next(after: activity, load: load, metric: metric)
        activity = next
        if next == .sitting {
            if quietSince == nil { quietSince = now }
        } else {
            quietSince = nil
        }
    }

    /// Wakes the pet and keeps it up for another `sleepAfter`.
    mutating func feed(at now: Date) {
        fedAt = now
        if quietSince != nil { quietSince = now }
    }

    func mood(at now: Date) -> PetMood {
        if let fedAt, now >= fedAt, now.timeIntervalSince(fedAt) < Self.mealLength { return .eating }
        if let quietSince, now.timeIntervalSince(quietSince) >= Self.sleepAfter { return .sleeping }
        return PetMood(activity ?? .sitting)
    }
}

/// Walking back and forth between 0 and a range's width, turning at the ends.
/// The pet starts at `startX` at `startTime`, so changing pace (a new path
/// from where it is) never makes it jump.
struct PetPath: Equatable, Sendable {
    var startX: Double
    var startTime: TimeInterval
    var facingRight = true

    func position(at time: TimeInterval, speed: Double, range: Double) -> (x: Double, facingRight: Bool) {
        let start = min(max(0, startX), max(0, range))
        guard range > 0, speed > 0 else { return (start, facingRight) }
        // Unfolded, the walk is a straight line over a loop of twice the range.
        let loop = range * 2
        let unfolded = (facingRight ? start : loop - start) + max(0, time - startTime) * speed
        let u = unfolded.truncatingRemainder(dividingBy: loop)
        return u <= range ? (u, true) : (loop - u, false)
    }
}
