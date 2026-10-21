import Foundation

// Time widgets: Timer, Pomodoro, Countdown, Stopwatch, Time progress and the
// Clock's time zone. Options live on `DockTile` in config.json; running
// clocks live in `TimeWidgetState` (time-widgets.json, `TimeWidgetService`),
// stored as dates rather than countdowns, so they keep running across
// relaunches and config.json is written only when Settings change.

// MARK: - Options (config.json)

/// Clock: how the square tile draws the time.
enum ClockFace: String, Codable, CaseIterable, Identifiable, Sendable {
    case digital
    /// Hands and ticks.
    case analog

    var id: String { rawValue }

    var title: String {
        switch self {
        case .digital: L10n.tr("Digital")
        case .analog: L10n.tr("Analog")
        }
    }
}

/// Time progress: the span its bar fills.
enum TimePeriod: String, Codable, CaseIterable, Identifiable, Sendable {
    case day
    case week
    case month
    case year

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: L10n.tr("Day")
        case .week: L10n.tr("Week")
        case .month: L10n.tr("Month")
        case .year: L10n.tr("Year")
        }
    }

    var component: Calendar.Component {
        switch self {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
    }
}

struct TimerOptions: Codable, Equatable, Sendable {
    /// Minutes offered as one-click starts.
    var durations = TimerOptions.defaultDurations
    var playsSound = true

    static let defaultDurations = [5, 10, 15, 25, 45]
    static let minuteRange = 1...600
    static let maxDurations = 8

    /// "5, 10, 25" → [5, 10, 25]: whole minutes in range, without repeats,
    /// shortest first. Nil when nothing valid is left.
    static func parseDurations(_ text: String) -> [Int]? {
        let numbers = text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        let valid = Array(Set(numbers.filter(minuteRange.contains))).sorted().prefix(maxDurations)
        return valid.isEmpty ? nil : Array(valid)
    }
}

struct PomodoroOptions: Codable, Equatable, Sendable {
    var focusMinutes = 25
    var shortBreakMinutes = 5
    var longBreakMinutes = 15
    /// Focus stretches before a long break.
    var longBreakAfter = 4
    /// A break starts by itself when a focus stretch ends. The next focus
    /// always waits for you.
    var autoStartBreaks = false
    var playsSound = true

    static let minuteRange = 1...120
    static let longBreakRange = 2...8

    func minutes(for stretch: PomodoroStretch) -> Int {
        let minutes = switch stretch {
        case .focus: focusMinutes
        case .shortBreak: shortBreakMinutes
        case .longBreak: longBreakMinutes
        }
        return min(max(minutes, Self.minuteRange.lowerBound), Self.minuteRange.upperBound)
    }

    func duration(for stretch: PomodoroStretch) -> TimeInterval {
        TimeInterval(minutes(for: stretch) * 60)
    }

    /// `longBreakAfter`, kept in its range for hand-edited configs.
    var stretchesPerCycle: Int {
        min(max(longBreakAfter, Self.longBreakRange.lowerBound), Self.longBreakRange.upperBound)
    }
}

struct CountdownOptions: Codable, Equatable, Sendable {
    /// What it counts to; nil until one is picked.
    var target: Date?
    /// After the target, count the time since instead of stopping at zero.
    var countsUp = false

    enum CodingKeys: String, CodingKey {
        case target, countsUp
    }

    /// Next New Year's midnight here: a new countdown's target.
    static func defaultTarget(after now: Date, calendar: Calendar = .current) -> Date? {
        let year = calendar.component(.year, from: now)
        return calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1))
    }

    /// Written as ISO 8601 in this Mac's time zone, "2026-12-24T18:00:00-03:00",
    /// so config.json stays readable.
    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    /// ISO 8601 with or without fractions, or a day alone ("2026-12-24",
    /// midnight here).
    static func date(from text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let date = TimeWidgetState.date(from: trimmed) { return date }
        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        day.timeZone = .current
        return day.date(from: trimmed)
    }
}

extension TimerOptions {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TimerOptions()
        let durations = try c.decode(.durations, or: d.durations).filter(Self.minuteRange.contains)
        self.durations = durations.isEmpty ? d.durations : Array(durations.prefix(Self.maxDurations))
        playsSound = try c.decode(.playsSound, or: d.playsSound)
    }
}

extension PomodoroOptions {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PomodoroOptions()
        focusMinutes = try c.decode(.focusMinutes, or: d.focusMinutes)
        shortBreakMinutes = try c.decode(.shortBreakMinutes, or: d.shortBreakMinutes)
        longBreakMinutes = try c.decode(.longBreakMinutes, or: d.longBreakMinutes)
        longBreakAfter = try c.decode(.longBreakAfter, or: d.longBreakAfter)
        autoStartBreaks = try c.decode(.autoStartBreaks, or: d.autoStartBreaks)
        playsSound = try c.decode(.playsSound, or: d.playsSound)
    }
}

extension CountdownOptions {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try c.decodeIfPresent(String.self, forKey: .target) {
            guard let date = Self.date(from: text) else {
                throw DecodingError.dataCorruptedError(forKey: .target, in: c, debugDescription: "Expected an ISO 8601 date, such as 2026-12-24T18:00:00-03:00.")
            }
            target = date
        }
        countsUp = try c.decode(.countsUp, or: false)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(target.map(Self.string(from:)), forKey: .target)
        try c.encode(countsUp, forKey: .countsUp)
    }
}

extension DockTile {
    /// Options a new time widget starts with; the others keep their defaults.
    mutating func applyTimeDefaults(now: Date = Date()) {
        if kind == .countdown, countdown == nil {
            countdown = CountdownOptions(target: CountdownOptions.defaultTarget(after: now))
        }
    }

    var timerOptions: TimerOptions { timer ?? TimerOptions() }
    var pomodoroOptions: PomodoroOptions { pomodoro ?? PomodoroOptions() }
    var countdownOptions: CountdownOptions { countdown ?? CountdownOptions() }
    var timePeriod: TimePeriod { period ?? .day }
    var clockFace: ClockFace { face ?? .digital }

    /// The Clock's zone: this Mac's unless `timeZone` names a known one.
    var timeZoneValue: TimeZone {
        timeZone.flatMap(TimeZone.init(identifier:)) ?? .autoupdatingCurrent
    }

    /// Whether the Clock shows another place than this Mac.
    var isWorldClock: Bool {
        timeZone.flatMap(TimeZone.init(identifier:)) != nil
    }
}

// MARK: - Running clocks

/// Elapsed time that can pause: `accumulated` before the current run, plus
/// the run since `startedAt`. Dates, not a ticking counter, so it's right
/// after sleep and relaunch.
struct RunClock: Codable, Equatable, Sendable {
    var accumulated: TimeInterval = 0
    /// Nil while paused or stopped.
    var startedAt: Date?

    var isRunning: Bool { startedAt != nil }

    func elapsed(at now: Date) -> TimeInterval {
        accumulated + (startedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    mutating func start(at now: Date) {
        guard startedAt == nil else { return }
        startedAt = now
    }

    mutating func pause(at now: Date) {
        guard startedAt != nil else { return }
        accumulated = elapsed(at: now)
        startedAt = nil
    }
}

extension RunClock {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accumulated = max(0, try c.decode(.accumulated, or: 0))
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
    }
}

struct TimerState: Codable, Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        /// Set, not started.
        case idle
        case running
        case paused
        /// Reached zero, until it's reset or started again.
        case finished
    }

    /// Seconds of the current run; kept after a reset, so Start repeats it.
    var duration: TimeInterval
    var clock = RunClock()
    var finishedAt: Date?

    init(duration: TimeInterval, clock: RunClock = RunClock(), finishedAt: Date? = nil) {
        self.duration = duration
        self.clock = clock
        self.finishedAt = finishedAt
    }

    func phase(at now: Date) -> Phase {
        if finishedAt != nil { return .finished }
        if clock.isRunning { return .running }
        return clock.accumulated > 0 ? .paused : .idle
    }

    func remaining(at now: Date) -> TimeInterval {
        finishedAt != nil ? 0 : max(0, duration - clock.elapsed(at: now))
    }

    /// What's left, as a fraction of the duration (1 when it starts).
    func fractionRemaining(at now: Date) -> Double {
        duration > 0 ? remaining(at: now) / duration : 0
    }

    /// When it reaches zero, while running.
    var endDate: Date? {
        guard let startedAt = clock.startedAt, finishedAt == nil else { return nil }
        return startedAt.addingTimeInterval(duration - clock.accumulated)
    }

    /// A fresh run of `duration`, from now.
    mutating func start(duration: TimeInterval, at now: Date) {
        self = TimerState(duration: duration, clock: RunClock(startedAt: now))
    }

    /// Start, pause, or after the end start the same duration again.
    mutating func toggle(at now: Date) {
        switch phase(at: now) {
        case .running: clock.pause(at: now)
        case .paused, .idle: clock.start(at: now)
        case .finished: start(duration: duration, at: now)
        }
    }

    mutating func reset() {
        self = TimerState(duration: duration)
    }

    /// Stops a running timer that reached zero; returns when it did, once.
    mutating func finishIfDue(at now: Date) -> Date? {
        guard let end = endDate, end <= now else { return nil }
        clock = RunClock(accumulated: duration)
        finishedAt = end
        return end
    }
}

extension TimerState {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        duration = max(0, try c.decode(.duration, or: TimeInterval(TimerOptions.defaultDurations[0] * 60)))
        clock = try c.decode(.clock, or: RunClock())
        finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
    }
}

enum PomodoroStretch: String, Codable, CaseIterable, Sendable {
    case focus
    case shortBreak
    case longBreak

    var title: String {
        switch self {
        case .focus: L10n.tr("Focus (pomodoro)")
        case .shortBreak: L10n.tr("Short break")
        case .longBreak: L10n.tr("Long break")
        }
    }

    var isBreak: Bool { self != .focus }
}

struct PomodoroState: Codable, Equatable, Sendable {
    /// A stretch that ended, and what comes next.
    struct End: Equatable, Sendable {
        var stretch: PomodoroStretch
        var at: Date
        var next: PomodoroStretch
    }

    var stretch: PomodoroStretch = .focus
    var clock = RunClock()
    /// Focus stretches finished since the last long break.
    var cycleCount = 0
    /// When each focus stretch finished (recent ones only).
    var completions: [Date] = []

    func remaining(options: PomodoroOptions, at now: Date) -> TimeInterval {
        max(0, options.duration(for: stretch) - clock.elapsed(at: now))
    }

    func fractionRemaining(options: PomodoroOptions, at now: Date) -> Double {
        remaining(options: options, at: now) / options.duration(for: stretch)
    }

    func endDate(options: PomodoroOptions) -> Date? {
        clock.startedAt.map { $0.addingTimeInterval(options.duration(for: stretch) - clock.accumulated) }
    }

    /// The stretch after the current one ends.
    func nextStretch(options: PomodoroOptions) -> PomodoroStretch {
        switch stretch {
        case .focus: cycleCount + 1 >= options.stretchesPerCycle ? .longBreak : .shortBreak
        case .shortBreak, .longBreak: .focus
        }
    }

    func completedToday(at now: Date, calendar: Calendar = .current) -> Int {
        completions.filter { calendar.isDate($0, inSameDayAs: now) }.count
    }

    mutating func toggle(at now: Date) {
        if clock.isRunning { clock.pause(at: now) } else { clock.start(at: now) }
    }

    /// Moves past every stretch that ended by `now`, in order. A finished
    /// focus counts; a break starts at the moment the focus ended when
    /// `autoStartBreaks` is on; the next focus waits.
    mutating func advance(to now: Date, options: PomodoroOptions) -> [End] {
        var ends: [End] = []
        while let end = endDate(options: options), end <= now {
            let finished = stretch
            let next = nextStretch(options: options)
            switch finished {
            case .focus:
                completions.append(end)
                cycleCount += 1
            case .longBreak:
                cycleCount = 0
            case .shortBreak:
                break
            }
            stretch = next
            clock = next.isBreak && options.autoStartBreaks ? RunClock(startedAt: end) : RunClock()
            ends.append(End(stretch: finished, at: end, next: next))
        }
        return ends
    }

    /// Ends the stretch now without counting it, and waits on the next one.
    mutating func skip(options: PomodoroOptions) {
        switch stretch {
        case .focus: stretch = cycleCount >= options.stretchesPerCycle ? .longBreak : .shortBreak
        case .shortBreak: stretch = .focus
        case .longBreak:
            cycleCount = 0
            stretch = .focus
        }
        clock = RunClock()
    }

    /// Back to the first focus of a cycle; today's sessions stay.
    mutating func reset() {
        stretch = .focus
        clock = RunClock()
        cycleCount = 0
    }

    /// Drops completions before yesterday, so the file stays small.
    mutating func pruneCompletions(before now: Date, calendar: Calendar = .current) {
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) else { return }
        completions.removeAll { $0 < yesterday }
    }
}

extension PomodoroState {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stretch = try c.decode(.stretch, or: .focus)
        clock = try c.decode(.clock, or: RunClock())
        cycleCount = max(0, try c.decode(.cycleCount, or: 0))
        completions = try c.decode(.completions, or: [])
    }
}

struct StopwatchState: Codable, Equatable, Sendable {
    var clock = RunClock()
    /// Elapsed time at each lap, oldest first.
    var laps: [TimeInterval] = []

    func elapsed(at now: Date) -> TimeInterval { clock.elapsed(at: now) }

    /// Each lap's own length, oldest first.
    var lapDurations: [TimeInterval] {
        zip(laps, [0] + laps).map { $0 - $1 }
    }

    /// The lap in progress: since the last lap.
    func currentLap(at now: Date) -> TimeInterval {
        elapsed(at: now) - (laps.last ?? 0)
    }

    mutating func toggle(at now: Date) {
        if clock.isRunning { clock.pause(at: now) } else { clock.start(at: now) }
    }

    mutating func lap(at now: Date) {
        guard clock.isRunning else { return }
        laps.append(elapsed(at: now))
    }

    mutating func reset() {
        self = StopwatchState()
    }

    static let maxLaps = 99
}

extension StopwatchState {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clock = try c.decode(.clock, or: RunClock())
        laps = try c.decode(.laps, or: [])
    }
}

/// Every running time widget, by tile id: time-widgets.json next to config.json.
struct TimeWidgetState: Codable, Equatable, Sendable {
    var version = 1
    var timers: [String: TimerState] = [:]
    var pomodoros: [String: PomodoroState] = [:]
    var stopwatches: [String: StopwatchState] = [:]

    /// Only the entries of these tiles, by kind.
    func keeping(_ tiles: [DockTile]) -> TimeWidgetState {
        func ids(_ kind: TileKind) -> Set<String> { Set(tiles.filter { $0.kind == kind }.map(\.id)) }
        var kept = self
        let timerIDs = ids(.timer), pomodoroIDs = ids(.pomodoro), stopwatchIDs = ids(.stopwatch)
        kept.timers = timers.filter { timerIDs.contains($0.key) }
        kept.pomodoros = pomodoros.filter { pomodoroIDs.contains($0.key) }
        kept.stopwatches = stopwatches.filter { stopwatchIDs.contains($0.key) }
        return kept
    }

    // Dates as ISO 8601 with milliseconds: readable, and exact enough that a
    // relaunch doesn't shift a timer.
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let whole = ISO8601DateFormatter()

    static func date(from text: String) -> Date? {
        fractional.date(from: text) ?? whole.date(from: text)
    }

    static func encoded(_ state: TimeWidgetState) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(fractional.string(from: date))
        }
        return try encoder.encode(state)
    }

    static func decoded(from data: Data) throws -> TimeWidgetState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = date(from: text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected an ISO 8601 date.")
            }
            return date
        }
        return try decoder.decode(TimeWidgetState.self, from: data)
    }
}

extension TimeWidgetState {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(.version, or: 1)
        timers = try c.decode(.timers, or: [:])
        pomodoros = try c.decode(.pomodoros, or: [:])
        stopwatches = try c.decode(.stopwatches, or: [:])
    }
}

// MARK: - Readings

/// How far a target date is, in calendar days, hours and minutes.
struct CountdownReading: Equatable, Sendable {
    /// The target is behind.
    var isPast: Bool
    /// Before it, what's left (minutes rounded up, so the last minute reads
    /// 1 min); after it, the time since, or zero when it doesn't count up.
    var days: Int
    var hours: Int
    var minutes: Int

    var isZero: Bool { days == 0 && hours == 0 && minutes == 0 }

    static func at(_ now: Date, target: Date, countsUp: Bool, calendar: Calendar = .current) -> CountdownReading {
        guard target > now else {
            guard countsUp else { return CountdownReading(isPast: true, days: 0, hours: 0, minutes: 0) }
            let parts = calendar.dateComponents([.day, .hour, .minute], from: target, to: now)
            return CountdownReading(isPast: true, days: parts.day ?? 0, hours: parts.hour ?? 0, minutes: parts.minute ?? 0)
        }
        // Up to the next whole minute: 30 seconds left reads "1 min".
        let minutesLeft = (target.timeIntervalSince(now) / 60).rounded(.up)
        let parts = calendar.dateComponents([.day, .hour, .minute], from: target.addingTimeInterval(-minutesLeft * 60), to: target)
        return CountdownReading(isPast: false, days: parts.day ?? 0, hours: parts.hour ?? 0, minutes: parts.minute ?? 0)
    }

    /// The two largest units: "12d 5h", "5h 42m", "42m".
    func text(locale: Locale, calendar: Calendar = .current) -> String {
        var components = DateComponents()
        if days > 0 {
            components.day = days
            components.hour = hours
        } else if hours > 0 {
            components.hour = hours
            components.minute = minutes
        } else {
            components.minute = minutes
        }
        return Self.format(components, units: [.day, .hour, .minute], maximum: 2, locale: locale, calendar: calendar)
    }

    /// Only the largest unit, for a square tile: "12d", "5h", "42m".
    func shortText(locale: Locale, calendar: Calendar = .current) -> String {
        var components = DateComponents()
        if days > 0 { components.day = days } else if hours > 0 { components.hour = hours } else { components.minute = minutes }
        return Self.format(components, units: [.day, .hour, .minute], maximum: 1, locale: locale, calendar: calendar)
    }

    static func format(_ components: DateComponents, units: NSCalendar.Unit, maximum: Int, locale: Locale, calendar: Calendar) -> String {
        let formatter = DateComponentsFormatter()
        var calendar = calendar
        calendar.locale = locale
        formatter.calendar = calendar
        formatter.allowedUnits = units
        formatter.maximumUnitCount = maximum
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: components) ?? ""
    }
}

enum TimeProgress {
    /// How much of the day, week, month or year holding `date` has passed,
    /// from 0 to 1, and that span. Weeks start on the calendar's first weekday.
    static func of(_ period: TimePeriod, at date: Date, calendar: Calendar = .current) -> (fraction: Double, interval: DateInterval)? {
        guard let interval = calendar.dateInterval(of: period.component, for: date), interval.duration > 0 else { return nil }
        let fraction = date.timeIntervalSince(interval.start) / interval.duration
        return (min(1, max(0, fraction)), interval)
    }
}

/// Times as the tiles print them; digits only, so they need no translation.
enum TimeText {
    /// Whole seconds, rounded up for countdowns: "4:59", "1:04:59".
    static func clock(_ seconds: TimeInterval, roundingUp: Bool = true) -> String {
        let total = max(0, Int(roundingUp ? (seconds - 0.001).rounded(.up) : seconds.rounded(.down)))
        let hours = total / 3600, minutes = total / 60 % 60, rest = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }

    /// Short enough for a square tile: "4:59", or "1h05" from an hour.
    static func compact(_ seconds: TimeInterval, roundingUp: Bool = true) -> String {
        let total = max(0, Int(roundingUp ? (seconds - 0.001).rounded(.up) : seconds.rounded(.down)))
        guard total >= 3600 else { return clock(TimeInterval(total), roundingUp: false) }
        // Whole minutes, rounded the same way as the seconds.
        let minutes = roundingUp ? (total + 59) / 60 : total / 60
        return String(format: "%dh%02d", minutes / 60, minutes % 60)
    }

    /// A stopwatch with hundredths: "0:42.07", "1:02:42.07".
    static func stopwatch(_ seconds: TimeInterval) -> String {
        // A hair up, so 42.07 s isn't printed as 42.06 from binary rounding.
        let hundredths = max(0, Int((seconds * 100 + 1e-6).rounded(.down)))
        let total = hundredths / 100
        let hours = total / 3600, minutes = total / 60 % 60, rest = total % 60
        let fraction = hundredths % 100
        return hours > 0
            ? String(format: "%d:%02d:%02d.%02d", hours, minutes, rest, fraction)
            : String(format: "%d:%02d.%02d", minutes, rest, fraction)
    }
}

/// Time zones for the Clock's picker.
enum TimeZoneCatalog {
    /// "America/Argentina/Buenos_Aires" → "Buenos Aires".
    static func city(of identifier: String) -> String {
        (identifier.split(separator: "/").last.map(String.init) ?? identifier).replacingOccurrences(of: "_", with: " ")
    }

    /// "America/Argentina/Buenos_Aires" → "America · Argentina".
    static func region(of identifier: String) -> String {
        identifier.split(separator: "/").dropLast().map { $0.replacingOccurrences(of: "_", with: " ") }.joined(separator: " · ")
    }

    /// Zones whose city, identifier or localized name has every word of
    /// `query`, ignoring case and accents; every zone for an empty one, by city.
    static func search(_ query: String, in identifiers: [String] = TimeZone.knownTimeZoneIdentifiers, locale: Locale) -> [String] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let matches = identifiers.filter { identifier in
            guard !words.isEmpty else { return true }
            let name = TimeZone(identifier: identifier)?.localizedName(for: .generic, locale: locale) ?? ""
            let haystack = [city(of: identifier), identifier, name].joined(separator: " ")
            return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        return matches.sorted { city(of: $0).localizedStandardCompare(city(of: $1)) == .orderedAscending }
    }

    /// Seconds `zone` is ahead of `reference` at `date` (negative behind).
    static func offset(of zone: TimeZone, from reference: TimeZone = .current, at date: Date) -> Int {
        zone.secondsFromGMT(for: date) - reference.secondsFromGMT(for: date)
    }
}
