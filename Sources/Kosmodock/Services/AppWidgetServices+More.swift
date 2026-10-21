import AppKit
import EventKit
import Foundation
import ImageIO
import Observation

// More app widgets: Codex and Reminders, and Music's album artwork for Now
// Playing. Like the others, each service works only while its tile is on the
// bar (`setEnabled`) and publishes values only when they change.

// MARK: - Codex

/// OpenAI's token counts: `input` includes `cachedInput`, and `output`
/// includes `reasoningOutput`.
struct CodexTokens: Equatable, Sendable {
    var input = 0
    var cachedInput = 0
    var output = 0
    var reasoningOutput = 0
    var total = 0

    init(input: Int = 0, cachedInput: Int = 0, output: Int = 0, reasoningOutput: Int = 0, total: Int? = nil) {
        self.input = input
        self.cachedInput = cachedInput
        self.output = output
        self.reasoningOutput = reasoningOutput
        self.total = total ?? input + output
    }

    /// A usage object from a session line, such as `last_token_usage`.
    init?(json: Any?) {
        guard let object = json as? [String: Any] else { return nil }
        func count(_ key: String) -> Int? { object[key] as? Int }
        guard let input = count("input_tokens"), let output = count("output_tokens") else { return nil }
        self.init(
            input: input, cachedInput: count("cached_input_tokens") ?? 0,
            output: output, reasoningOutput: count("reasoning_output_tokens") ?? 0,
            total: count("total_tokens")
        )
    }

    static func + (lhs: CodexTokens, rhs: CodexTokens) -> CodexTokens {
        CodexTokens(
            input: lhs.input + rhs.input, cachedInput: lhs.cachedInput + rhs.cachedInput,
            output: lhs.output + rhs.output, reasoningOutput: lhs.reasoningOutput + rhs.reasoningOutput,
            total: lhs.total + rhs.total
        )
    }

    static func - (lhs: CodexTokens, rhs: CodexTokens) -> CodexTokens {
        CodexTokens(
            input: max(0, lhs.input - rhs.input), cachedInput: max(0, lhs.cachedInput - rhs.cachedInput),
            output: max(0, lhs.output - rhs.output), reasoningOutput: max(0, lhs.reasoningOutput - rhs.reasoningOutput),
            total: max(0, lhs.total - rhs.total)
        )
    }
}

/// The plan windows in one session line. The same shape as Claude Code's
/// (`ClaudeLimit`), so the widgets share their meters.
struct CodexRateLimits: Equatable, Sendable {
    /// `limit_id`; "codex" is the plan's own limit.
    var id = CodexRateLimits.planID
    var fiveHour: ClaudeLimit?
    var weekly: ClaudeLimit?

    static let planID = "codex"
}

struct CodexUsage: Equatable, Sendable {
    /// False while ~/.codex/sessions doesn't exist: Codex hasn't run here.
    var hasSessions = false
    var lastFiveHours = CodexTokens()
    var today = CodexTokens()
    var lastSevenDays = CodexTokens()
    var lastActivity: Date?
    var model: String?
    /// From the most recent session line that had them, without any window
    /// that reset since.
    var fiveHourLimit: ClaudeLimit?
    var weeklyLimit: ClaudeLimit?
    var limitsUpdatedAt: Date?
}

/// Token counts and plan limits from Codex's session files
/// (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`), read incrementally. The
/// format is internal to Codex, so anything unexpected is skipped.
///
/// Codex writes a `token_count` event after each response, with that turn's
/// usage (`last_token_usage`) and the session's running total
/// (`total_token_usage`). It repeats the event without new usage now and then,
/// so a line whose total equals the previous one counts nothing.
actor CodexSessionReader {
    struct Entry: Equatable, Sendable {
        var date: Date
        var tokens: CodexTokens
        var model: String?
    }

    enum Line: Equatable, Sendable {
        /// The settings of a turn, which name its model.
        case turnContext(model: String?)
        case tokenCount(date: Date, last: CodexTokens?, total: CodexTokens?, limits: CodexRateLimits?)
    }

    /// Where a file was read up to, and what the lines before it said.
    private struct FileState {
        var offset: UInt64 = 0
        var lastTotal: CodexTokens?
        var model: String?
    }

    /// The same turn copied into another file (a forked session, an archived
    /// one) has the same time and counts, so it's counted once.
    private struct EntryKey: Hashable {
        var date: Date
        var total: Int
        var turn: Int
    }

    private let sessions: URL
    private let roots: [URL]
    private var files: [String: FileState] = [:]
    private var entries: [EntryKey: Entry] = [:]
    /// The latest limits by `limit_id`, with their line's time.
    private var limits: [String: (date: Date, limits: CodexRateLimits)] = [:]

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")) {
        sessions = home.appendingPathComponent("sessions")
        roots = [sessions, home.appendingPathComponent("archived_sessions")]
    }

    func read(now: Date = Date()) -> CodexUsage {
        let weekAgo = now.addingTimeInterval(-7 * 86_400)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        for root in roots {
            // The enumerator doesn't follow a symlinked folder.
            guard let files = FileManager.default.enumerator(at: root.resolvingSymlinksInPath(), includingPropertiesForKeys: keys) else { continue }
            for case let url as URL in files where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      let modified = values.contentModificationDate, modified >= weekAgo,
                      let size = values.fileSize
                else { continue }
                ingest(url, size: UInt64(size))
            }
        }
        entries = entries.filter { $0.value.date >= weekAgo }
        var usage = Self.usage(of: Array(entries.values), now: now)
        usage.hasSessions = FileManager.default.fileExists(atPath: sessions.resolvingSymlinksInPath().path)
        if let latest = limits[CodexRateLimits.planID] ?? limits.values.max(by: { $0.date < $1.date }) {
            usage.fiveHourLimit = latest.limits.fiveHour.flatMap { $0.resetsAt > now ? $0 : nil }
            usage.weeklyLimit = latest.limits.weekly.flatMap { $0.resetsAt > now ? $0 : nil }
            usage.limitsUpdatedAt = latest.date
        }
        return usage
    }

    private func ingest(_ url: URL, size: UInt64) {
        var state = files[url.path] ?? FileState()
        if size < state.offset { state = FileState() }  // rewritten
        guard size > state.offset, let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: state.offset)
        guard let data = try? handle.readToEnd(), let lastNewline = data.lastIndex(of: 0x0A) else { return }
        // Only complete lines; a line still being written is read next time.
        let complete = data[data.startIndex...lastNewline]
        for line in complete.split(separator: 0x0A) {
            switch Self.line(from: Data(line)) {
            case .turnContext(let model):
                if let model { state.model = model }
            case .tokenCount(let date, let last, let total, let lineLimits):
                if let lineLimits, limits[lineLimits.id].map({ date >= $0.date }) ?? true {
                    limits[lineLimits.id] = (date, lineLimits)
                }
                if let total, total == state.lastTotal { continue }  // repeated, no new usage
                let turn = last ?? total.map { total in
                    state.lastTotal.flatMap { total.total >= $0.total ? total - $0 : nil } ?? total
                }
                if let total { state.lastTotal = total }
                if let turn, turn.total > 0 {
                    entries[EntryKey(date: date, total: total?.total ?? -1, turn: turn.total)] = Entry(date: date, tokens: turn, model: state.model)
                }
            case nil:
                continue
            }
        }
        state.offset += UInt64(complete.count)
        files[url.path] = state
    }

    private static let markers = [Data("\"token_count\"".utf8), Data("\"turn_context\"".utf8)]
    private static let dateFormatters: [ISO8601DateFormatter] = ([[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] as [ISO8601DateFormatter.Options]).map { options in
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = options
        return formatter
    }

    static func date(from stamp: String) -> Date? {
        for formatter in dateFormatters {
            if let date = formatter.date(from: stamp) { return date }
        }
        return nil
    }

    /// What one session line says about usage, or nil for everything else.
    static func line(from data: Data) -> Line? {
        guard markers.contains(where: { data.range(of: $0) != nil }),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["payload"] as? [String: Any]
        else { return nil }
        if object["type"] as? String == "turn_context" {
            return .turnContext(model: payload["model"] as? String)
        }
        guard object["type"] as? String == "event_msg",
              payload["type"] as? String == "token_count",
              let stamp = object["timestamp"] as? String,
              let date = date(from: stamp)
        else { return nil }
        // `info` is null before the first response; `rate_limits` can be too.
        let info = payload["info"] as? [String: Any]
        return .tokenCount(
            date: date,
            last: CodexTokens(json: info?["last_token_usage"]),
            total: CodexTokens(json: info?["total_token_usage"]),
            limits: rateLimits(from: payload["rate_limits"], at: date)
        )
    }

    /// `primary` and `secondary` by their length (`window_minutes`): a plan
    /// can have only the weekly window, as `primary`. Without a length,
    /// `primary` is the 5-hour one. A reset is an epoch time (`resets_at`) or,
    /// in older versions, seconds after the line (`resets_in_seconds`).
    static func rateLimits(from json: Any?, at date: Date) -> CodexRateLimits? {
        guard let object = json as? [String: Any] else { return nil }
        var result = CodexRateLimits(id: object["limit_id"] as? String ?? CodexRateLimits.planID)
        for (key, isWeeklyByDefault) in [("primary", false), ("secondary", true)] {
            guard let window = object[key] as? [String: Any],
                  let used = (window["used_percent"] as? NSNumber)?.doubleValue
            else { continue }
            let resets: Date
            if let epoch = (window["resets_at"] as? NSNumber)?.doubleValue {
                resets = Date(timeIntervalSince1970: epoch)
            } else if let seconds = (window["resets_in_seconds"] as? NSNumber)?.doubleValue {
                resets = date.addingTimeInterval(seconds)
            } else {
                continue
            }
            let limit = ClaudeLimit(usedPercent: used, resetsAt: resets)
            let isWeekly = (window["window_minutes"] as? NSNumber).map { $0.intValue > 24 * 60 } ?? isWeeklyByDefault
            if isWeekly {
                result.weekly = result.weekly ?? limit
            } else {
                result.fiveHour = result.fiveHour ?? limit
            }
        }
        return result.fiveHour == nil && result.weekly == nil ? nil : result
    }

    static func usage(of entries: [Entry], now: Date) -> CodexUsage {
        let fiveHoursAgo = now.addingTimeInterval(-5 * 3600)
        let startOfDay = Calendar.current.startOfDay(for: now)
        var usage = CodexUsage()
        for entry in entries {
            usage.lastSevenDays = usage.lastSevenDays + entry.tokens
            if entry.date >= startOfDay { usage.today = usage.today + entry.tokens }
            if entry.date >= fiveHoursAgo { usage.lastFiveHours = usage.lastFiveHours + entry.tokens }
            if usage.lastActivity.map({ entry.date > $0 }) ?? true {
                usage.lastActivity = entry.date
                usage.model = entry.model
            }
        }
        return usage
    }
}

@MainActor
@Observable
final class CodexUsageService {
    private(set) var usage = CodexUsage()

    @ObservationIgnored private let reader = CodexSessionReader()
    @ObservationIgnored private var loop: Task<Void, Never>?

    func setEnabled(_ enabled: Bool) {
        guard enabled != (loop != nil) else { return }
        loop?.cancel()
        loop = nil
        guard enabled else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func refresh() async {
        let next = await reader.read()
        if next != usage { usage = next }
    }
}

// MARK: - Reminders

struct ReminderItem: Identifiable, Equatable, Sendable {
    /// `calendarItemIdentifier`.
    var id: String
    var title: String
    var due: Date?
    /// False for a reminder due on a day, without a time.
    var hasDueTime = false
    var listTitle = ""
    var colorHex: String?
}

/// Incomplete reminders from every list. Kosmodock changes one only when you
/// complete it from the widget.
@MainActor
@Observable
final class RemindersService {
    typealias Access = CalendarService.Access

    private(set) var access: Access = .unknown
    private(set) var reminders: [ReminderItem] = []
    private(set) var lastError: String?

    @ObservationIgnored private var store: EKEventStore?
    @ObservationIgnored private var token: NSObjectProtocol?
    @ObservationIgnored private var timer: Task<Void, Never>?
    /// Only the latest fetch is applied.
    @ObservationIgnored private var generation = 0

    func setEnabled(_ enabled: Bool) {
        guard enabled != (store != nil) else { return }
        if enabled {
            let store = EKEventStore()
            self.store = store
            token = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            // "Due in 5 min" moves on, and today's count changes at midnight.
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(300))
                    self?.refresh()
                }
            }
            Task { await requestAccessIfNeeded() }
        } else {
            if let token { NotificationCenter.default.removeObserver(token) }
            token = nil
            timer?.cancel()
            timer = nil
            store = nil
            generation += 1
            if !reminders.isEmpty { reminders = [] }
        }
    }

    func requestAccessIfNeeded() async {
        guard let store else { return }
        // The raw Info.plist: `object(forInfoDictionaryKey:)` also finds the
        // key in InfoPlist.strings, and asking without it crashes the app.
        guard Bundle.main.infoDictionary?["NSRemindersFullAccessUsageDescription"] != nil else {
            access = .unavailable
            return
        }
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess:
            access = .granted
        case .notDetermined:
            access = (try? await store.requestFullAccessToReminders()) == true ? .granted : .denied
        default:
            access = .denied
        }
        refresh()
    }

    /// Marks the reminder complete in Reminders.
    func complete(_ item: ReminderItem) {
        guard access == .granted, let store,
              let reminder = store.calendarItem(withIdentifier: item.id) as? EKReminder
        else { return }
        reminder.isCompleted = true
        do {
            try store.save(reminder, commit: true)
            reminders.removeAll { $0.id == item.id }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Fetches the reminders again; EventKit's change notification also does.
    func refresh() {
        guard access == .granted, let store else { return }
        generation += 1
        let current = generation
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        Task {
            let next = await Self.fetch(predicate, from: store)
            guard current == generation else { return }
            if next != reminders { reminders = next }
        }
    }

    /// EventKit calls back on its own queue; the items are copied out there.
    private nonisolated static func fetch(_ predicate: NSPredicate, from store: EKEventStore) async -> [ReminderItem] {
        await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { found in
                let items = (found ?? []).map { reminder in
                    let components = reminder.dueDateComponents
                    return ReminderItem(
                        id: reminder.calendarItemIdentifier,
                        title: reminder.title ?? "",
                        due: components.flatMap { ($0.calendar ?? Calendar.current).date(from: $0) },
                        hasDueTime: components?.hour != nil,
                        listTitle: reminder.calendar?.title ?? "",
                        colorHex: reminder.calendar.flatMap { NSColor(cgColor: $0.cgColor) }.map(HexColor.of)
                    )
                }
                continuation.resume(returning: sorted(items))
            }
        }
    }

    /// By due date, overdue first and undated last; then by title.
    nonisolated static func sorted(_ items: [ReminderItem]) -> [ReminderItem] {
        items.sorted { lhs, rhs in
            switch (lhs.due, rhs.due) {
            case let (left?, right?) where left != right: return left < right
            case (nil, _?): return false
            case (_?, nil): return true
            default:
                let order = lhs.title.localizedStandardCompare(rhs.title)
                return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
            }
        }
    }

    /// Past its time, or past its day when it has no time.
    nonisolated static func isOverdue(_ item: ReminderItem, at date: Date = Date()) -> Bool {
        guard let due = item.due else { return false }
        return item.hasDueTime ? due < date : due < Calendar.current.startOfDay(for: date)
    }

    /// Reminders due today or overdue.
    nonisolated static func dueCount(in items: [ReminderItem], at date: Date = Date()) -> Int {
        let calendar = Calendar.current
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) else { return 0 }
        return items.filter { $0.due.map { $0 < tomorrow } ?? false }.count
    }
}

// MARK: - Album artwork (Music)

extension NowPlaying {
    /// One artwork per track: Music is asked again only when this changes.
    var artworkKey: String { [title, artist, album].joined(separator: "\u{1F}") }
}

extension NowPlayingService {
    static let artworkScript = #"tell application "Music" to get data of artwork 1 of current track"#

    /// Music's art for its current track, scaled down for the dock; nil when
    /// Music isn't running or the track has none.
    static func fetchArtwork() async -> CGImage? {
        // `tell application` would launch Music.
        guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == MediaPlayer.music.bundleID }) else { return nil }
        let result = await ShellRunner.run("/usr/bin/osascript", ["-e", artworkScript], timeout: 6)
        guard result.succeeded else { return nil }
        let output = result.stdout
        // Big covers are megabytes of hex: decode them off the main thread.
        return await Task.detached(priority: .utility) {
            artworkData(fromOutput: output).flatMap { thumbnail(from: $0) }
        }.value
    }

    /// The bytes osascript prints for raw data, `«data PNGf89504E47…»`: a
    /// four-character type code (PNGf, JPEG, tdta…), then hex.
    nonisolated static func artworkData(fromOutput output: String) -> Data? {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("«data "), text.hasSuffix("»") else { return nil }
        let hex = text.utf8.dropFirst("«data ".utf8.count + 4).dropLast("»".utf8.count)
        guard !hex.isEmpty, hex.count.isMultiple(of: 2) else { return nil }
        func nibble(_ byte: UInt8) -> UInt8? {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
            case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
            case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
            default: nil
            }
        }
        var data = Data(capacity: hex.count / 2)
        var high: UInt8?
        for byte in hex {
            guard let value = nibble(byte) else { return nil }
            if let first = high {
                data.append(first << 4 | value)
                high = nil
            } else {
                high = value
            }
        }
        return data
    }

    /// An image small enough for the dock and the details, from any format
    /// ImageIO reads.
    nonisolated static func thumbnail(from data: Data, maxPixelSize: Int = 256) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
