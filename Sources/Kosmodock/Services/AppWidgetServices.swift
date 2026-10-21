import AppKit
import EventKit
import Foundation
import Observation

// Data behind the app widget tiles. Each service works only while a tile of
// its kind is on the bar (`setEnabled`), and publishes values only when they
// change.

// MARK: - Now playing (Music, Spotify)

enum MediaPlayer: String, Sendable, CaseIterable {
    case music = "com.apple.Music"
    case spotify = "com.spotify.client"

    var bundleID: String { rawValue }
    /// AppleScript's name for the app.
    var scriptName: String { self == .music ? "Music" : "Spotify" }
}

struct NowPlaying: Equatable, Sendable {
    var player: MediaPlayer
    var isPlaying: Bool
    var title: String
    var artist: String
    var album: String
    /// Seconds.
    var duration: Double
    var position: Double
    /// When `position` was read, to advance it while playing.
    var sampledAt: Date

    func position(at date: Date) -> Double {
        guard isPlaying else { return position }
        return min(duration > 0 ? duration : .infinity, position + date.timeIntervalSince(sampledAt))
    }
}

/// Reads and controls Music or Spotify through AppleScript. It never launches
/// them: a player is asked only while it's running.
@MainActor
@Observable
final class NowPlayingService {
    enum State: Equatable, Sendable {
        case idle
        case playing(NowPlaying)
        /// macOS denied the Automation permission for the player.
        case denied(MediaPlayer)
    }

    private(set) var state: State = .idle

    @ObservationIgnored private var loop: Task<Void, Never>?

    func setEnabled(_ enabled: Bool) {
        guard enabled != (loop != nil) else { return }
        loop?.cancel()
        loop = nil
        if enabled {
            loop = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refresh()
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        } else if state != .idle {
            state = .idle
        }
    }

    func refresh() async {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        var paused: State?
        for player in MediaPlayer.allCases where running.contains(player.bundleID) {
            let result = await ShellRunner.run("/usr/bin/osascript", ["-e", Self.readScript(for: player)], timeout: 4)
            let next = Self.state(from: result, player: player)
            if case .playing(let track) = next, track.isPlaying {
                publish(next)
                return
            }
            if paused == nil, next != .idle { paused = next }
        }
        publish(paused ?? .idle)
    }

    func send(_ command: Command, to player: MediaPlayer) {
        Task {
            _ = await ShellRunner.run("/usr/bin/osascript", ["-e", "tell application \"\(player.scriptName)\" to \(command.rawValue)"], timeout: 4)
            try? await Task.sleep(for: .milliseconds(250))
            await refresh()
        }
    }

    enum Command: String {
        case playPause = "playpause"
        case next = "next track"
        case previous = "previous track"
    }

    private func publish(_ next: State) {
        if next != state { state = next }
    }

    /// Tab-separated state, title, artist, album, duration (s) and position (s).
    static func readScript(for player: MediaPlayer) -> String {
        let duration = player == .spotify ? "((duration of current track) / 1000)" : "(duration of current track)"
        return """
        tell application "\(player.scriptName)"
            if player state is stopped then return "stopped"
            return (player state as text) & tab & (name of current track) & tab & (artist of current track) & tab & (album of current track) & tab & \(duration) & tab & player position
        end tell
        """
    }

    /// Separate from `osascript` so the parsing can be tested.
    static func state(from result: ShellResult, player: MediaPlayer, now: Date = Date()) -> State {
        // -1743: the user didn't allow Kosmodock to control the player.
        if result.stderr.contains("-1743") { return .denied(player) }
        guard result.succeeded else { return .idle }
        let fields = result.stdout.trimmingCharacters(in: .newlines).components(separatedBy: "\t")
        guard fields.count >= 6, fields[0] != "stopped" else { return .idle }
        func number(_ text: String) -> Double { Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0 }
        return .playing(NowPlaying(
            player: player, isPlaying: fields[0] == "playing",
            title: fields[1], artist: fields[2], album: fields[3],
            duration: number(fields[4]), position: number(fields[5]), sampledAt: now
        ))
    }
}

// MARK: - Calendar

struct CalendarEvent: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var colorHex: String?
}

/// Today's and tomorrow's events from the Calendar app, read-only.
@MainActor
@Observable
final class CalendarService {
    enum Access: Equatable, Sendable {
        case unknown
        case granted
        case denied
        /// A build without the usage description (debug), which must not ask.
        case unavailable
    }

    private(set) var access: Access = .unknown
    private(set) var events: [CalendarEvent] = []

    @ObservationIgnored private var store: EKEventStore?
    @ObservationIgnored private var token: NSObjectProtocol?
    @ObservationIgnored private var timer: Task<Void, Never>?

    func setEnabled(_ enabled: Bool) {
        guard enabled != (store != nil) else { return }
        if enabled {
            let store = EKEventStore()
            self.store = store
            token = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            }
            // The day rolls over, and "in 5 min" moves on.
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(300))
                    self?.reload()
                }
            }
            Task { await requestAccessIfNeeded() }
        } else {
            if let token { NotificationCenter.default.removeObserver(token) }
            token = nil
            timer?.cancel()
            timer = nil
            store = nil
            if !events.isEmpty { events = [] }
        }
    }

    func requestAccessIfNeeded() async {
        guard let store else { return }
        // The raw Info.plist: `object(forInfoDictionaryKey:)` also finds the
        // key in InfoPlist.strings, which doesn't count for macOS.
        guard Bundle.main.infoDictionary?["NSCalendarsFullAccessUsageDescription"] != nil else {
            access = .unavailable
            return
        }
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            access = .granted
        case .notDetermined:
            access = (try? await store.requestFullAccessToEvents()) == true ? .granted : .denied
        default:
            access = .denied
        }
        reload()
    }

    private func reload() {
        guard access == .granted, let store else { return }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        guard let end = calendar.date(byAdding: .day, value: 2, to: start) else { return }
        let next = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .sorted { $0.startDate < $1.startDate }
            .map { event in
                CalendarEvent(
                    id: event.eventIdentifier ?? UUID().uuidString,
                    title: event.title ?? "",
                    start: event.startDate, end: event.endDate, isAllDay: event.isAllDay,
                    colorHex: event.calendar.flatMap { NSColor(cgColor: $0.cgColor) }.map(HexColor.of)
                )
            }
        if next != events { events = next }
    }

    /// The event under way or the next one, preferring timed events.
    static func next(in events: [CalendarEvent], at date: Date = Date()) -> CalendarEvent? {
        let upcoming = events.filter { $0.end > date }
        return upcoming.first { !$0.isAllDay } ?? upcoming.first
    }
}

private enum HexColor {
    static func of(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "#8E8E93" }
        func component(_ value: CGFloat) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", component(rgb.redComponent), component(rgb.greenComponent), component(rgb.blueComponent))
    }
}

// MARK: - GitHub

struct PullRequest: Identifiable, Equatable, Sendable, Decodable {
    struct Repository: Equatable, Sendable, Decodable {
        var nameWithOwner: String
    }

    var number: Int
    var title: String
    var url: String
    var isDraft: Bool
    var repository: Repository
    var updatedAt: Date?

    var id: String { url }
}

/// Your open pull requests and the ones waiting for your review, through the
/// `gh` CLI and its login. Kosmodock holds no token.
@MainActor
@Observable
final class GitHubService {
    enum Status: Equatable, Sendable {
        case loading
        case ready
        case notInstalled
        case signedOut
        case failed(String)
    }

    private(set) var status: Status = .loading
    private(set) var mine: [PullRequest] = []
    private(set) var reviewRequests: [PullRequest] = []
    private(set) var updatedAt: Date?

    @ObservationIgnored private var loop: Task<Void, Never>?

    func setEnabled(_ enabled: Bool) {
        guard enabled != (loop != nil) else { return }
        loop?.cancel()
        loop = nil
        if enabled {
            loop = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refresh()
                    try? await Task.sleep(for: .seconds(120))
                }
            }
        }
    }

    func refresh() async {
        let fields = "number,title,url,isDraft,repository,updatedAt"
        async let own = ShellRunner.shell("gh search prs --author=@me --state=open --json \(fields) --limit 25", timeout: 20)
        async let review = ShellRunner.shell("gh search prs --review-requested=@me --state=open --json \(fields) --limit 25", timeout: 20)
        let (ownResult, reviewResult) = await (own, review)
        switch (Self.parse(ownResult), Self.parse(reviewResult)) {
        case (.success(let ownPRs), .success(let reviewPRs)):
            if ownPRs != mine { mine = ownPRs }
            if reviewPRs != reviewRequests { reviewRequests = reviewPRs }
            updatedAt = Date()
            if status != .ready { status = .ready }
        case (.failure(let failure), _), (_, .failure(let failure)):
            if status != failure.status { status = failure.status }
        }
    }

    struct StatusError: Error, Equatable {
        var status: Status
    }

    /// Separate from `gh` so the parsing can be tested.
    static func parse(_ result: ShellResult) -> Result<[PullRequest], StatusError> {
        if result.exitCode == 127 { return .failure(StatusError(status: .notInstalled)) }
        // gh exits with 4 when it needs a login.
        if result.exitCode == 4 || result.stderr.contains("gh auth login") { return .failure(StatusError(status: .signedOut)) }
        guard result.succeeded else { return .failure(StatusError(status: .failed(result.errorSummary))) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let pulls = try? decoder.decode([PullRequest].self, from: Data(result.stdout.utf8)) else {
            return .failure(StatusError(status: .failed(L10n.tr("Unexpected output from gh"))))
        }
        return .success(pulls)
    }
}

// MARK: - Claude Code

struct TokenCount: Equatable, Sendable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheCreation = 0

    var total: Int { input + output + cacheRead + cacheCreation }

    static func + (lhs: TokenCount, rhs: TokenCount) -> TokenCount {
        TokenCount(
            input: lhs.input + rhs.input, output: lhs.output + rhs.output,
            cacheRead: lhs.cacheRead + rhs.cacheRead, cacheCreation: lhs.cacheCreation + rhs.cacheCreation
        )
    }
}

/// A plan window from Claude Code's status line data.
struct ClaudeLimit: Equatable, Sendable {
    var usedPercent: Double
    var resetsAt: Date
}

struct ClaudeUsage: Equatable, Sendable {
    var lastFiveHours = TokenCount()
    var today = TokenCount()
    var lastSevenDays = TokenCount()
    var lastActivity: Date?
    var model: String?
    /// Only with the status line set up (`ClaudeStatusLine`), and only while a
    /// window hasn't reset since Claude Code last wrote it.
    var fiveHourLimit: ClaudeLimit?
    var weeklyLimit: ClaudeLimit?
    var limitsUpdatedAt: Date?
}

/// Token counts from Claude Code's transcripts, read incrementally. The
/// format is internal to Claude Code, so anything unexpected is skipped.
actor ClaudeTranscriptReader {
    struct Entry: Equatable, Sendable {
        var date: Date
        var tokens: TokenCount
        var model: String?
    }

    private let root: URL
    private var offsets: [String: UInt64] = [:]
    /// By message id: one response is written as several lines with the same usage.
    private var entries: [String: Entry] = [:]

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")) {
        self.root = root
    }

    func read(now: Date = Date()) -> ClaudeUsage {
        let weekAgo = now.addingTimeInterval(-7 * 86_400)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        // The enumerator doesn't follow a symlinked ~/.claude or projects folder.
        if let files = FileManager.default.enumerator(at: root.resolvingSymlinksInPath(), includingPropertiesForKeys: keys) {
            for case let url as URL in files where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      let modified = values.contentModificationDate, modified >= weekAgo,
                      let size = values.fileSize
                else { continue }
                ingest(url, size: UInt64(size))
            }
        }
        entries = entries.filter { $0.value.date >= weekAgo }
        return Self.usage(of: Array(entries.values), now: now)
    }

    private func ingest(_ url: URL, size: UInt64) {
        var offset = offsets[url.path] ?? 0
        if size < offset { offset = 0 }  // rewritten
        guard size > offset, let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), let lastNewline = data.lastIndex(of: 0x0A) else { return }
        // Only complete lines; a line still being written is read next time.
        let complete = data[data.startIndex...lastNewline]
        for line in complete.split(separator: 0x0A) {
            if let (id, entry) = Self.entry(fromLine: Data(line)) { entries[id] = entry }
        }
        offsets[url.path] = offset + UInt64(complete.count)
    }

    private static let usageMarker = Data("\"usage\"".utf8)
    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// An assistant response's id and usage, from one transcript line.
    static func entry(fromLine line: Data) -> (String, Entry)? {
        guard line.range(of: usageMarker) != nil,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any],
              let id = message["id"] as? String,
              let usage = message["usage"] as? [String: Any],
              let stamp = object["timestamp"] as? String,
              let date = dateFormatter.date(from: stamp)
        else { return nil }
        let tokens = TokenCount(
            input: usage["input_tokens"] as? Int ?? 0,
            output: usage["output_tokens"] as? Int ?? 0,
            cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0,
            cacheCreation: usage["cache_creation_input_tokens"] as? Int ?? 0
        )
        return (id, Entry(date: date, tokens: tokens, model: message["model"] as? String))
    }

    static func usage(of entries: [Entry], now: Date) -> ClaudeUsage {
        let fiveHoursAgo = now.addingTimeInterval(-5 * 3600)
        let startOfDay = Calendar.current.startOfDay(for: now)
        var usage = ClaudeUsage()
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

/// Claude Code hands plan usage only to its status line command, so the
/// Claude Code widget can install one that saves what it gets (`statusFile`).
enum ClaudeStatusLine: Equatable, Sendable {
    case notSet
    case kosmodock
    /// The user's own; Kosmodock leaves it alone.
    case other(command: String)

    static let settingsFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    /// Kosmodock's config folder, where the script and its data live.
    static let directory = ConfigService.defaultFileURL.deletingLastPathComponent()
    static let scriptFile = directory.appendingPathComponent("claude-statusline.sh")
    /// The status line's whole input; Kosmodock reads `rate_limits` from it.
    static let statusFile = directory.appendingPathComponent("claude-status.json")

    static var current: ClaudeStatusLine {
        guard let data = try? Data(contentsOf: settingsFile),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let statusLine = settings["statusLine"] as? [String: Any]
        else { return .notSet }
        let command = statusLine["command"] as? String ?? ""
        return command.contains(scriptFile.lastPathComponent) ? .kosmodock : .other(command: command)
    }

    /// Saves its input for the dock and prints a short line in Claude Code.
    /// No JSON tools: `plutil` can't read JSON from stdin before macOS 26,
    /// and `jq` isn't installed by default. The line is best effort; the
    /// file is what the widget reads.
    static let script = #"""
    #!/bin/sh
    # Kosmodock: saves Claude Code's status data, which includes your plan's
    # usage, for the dock's Claude Code widget, and shows the usage here.
    # Remove it in Kosmodock's Settings › Widgets.
    input=$(cat)
    dir="$HOME/.config/kosmodock"
    flat=$(printf '%s' "$input" | tr -d '\n')
    # Sessions start without rate_limits; keep the last ones until they come.
    case "$flat" in
      *'"rate_limits"'*) printf '%s' "$input" > "$dir/.claude-status.tmp" && mv -f "$dir/.claude-status.tmp" "$dir/claude-status.json" ;;
    esac
    model=$(printf '%s' "$flat" | sed -n 's/.*"model" *: *{[^}]*"display_name" *: *"\([^"]*\)".*/\1/p')
    percent() { printf '%s' "$flat" | sed -n "s/.*\"$1\" *: *{[^}]*\"used_percentage\" *: *\([0-9]*\).*/\1/p"; }
    five=$(percent five_hour)
    week=$(percent seven_day)
    line="${model:-Claude}"
    [ -n "$five" ] && line="$line · 5h $five%"
    [ -n "$week" ] && line="$line · 7d $week%"
    printf '%s\n' "$line"
    """#

    /// Adds Kosmodock's status line to Claude Code's settings, keeping a copy
    /// of them. Does nothing when another status line is set.
    static func install() throws {
        var settings = try readSettings()
        guard settings["statusLine"] == nil else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try script.write(to: scriptFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptFile.path)
        settings["statusLine"] = ["type": "command", "command": scriptFile.path, "refreshInterval": 60]
        try writeSettings(settings)
    }

    static func remove() throws {
        var settings = try readSettings()
        guard case .kosmodock = current else { return }
        settings["statusLine"] = nil
        try writeSettings(settings)
        try? FileManager.default.removeItem(at: statusFile)
    }

    private static func readSettings() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsFile), !data.isEmpty else { return [:] }
        guard let settings = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return settings
    }

    private static func writeSettings(_ settings: [String: Any]) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: settingsFile.path) {
            let backup = settingsFile.appendingPathExtension("kosmodock-backup")
            try? manager.removeItem(at: backup)
            try manager.copyItem(at: settingsFile, to: backup)
        } else {
            try manager.createDirectory(at: settingsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsFile, options: .atomic)
    }

    /// The windows in `statusFile`, without any that reset since it was written.
    static func limits(from data: Data, now: Date = Date()) -> (fiveHour: ClaudeLimit?, weekly: ClaudeLimit?) {
        guard let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let object = status["rate_limits"] as? [String: Any]
        else { return (nil, nil) }
        func limit(_ key: String) -> ClaudeLimit? {
            guard let window = object[key] as? [String: Any],
                  let used = (window["used_percentage"] as? NSNumber)?.doubleValue,
                  let resets = (window["resets_at"] as? NSNumber)?.doubleValue
            else { return nil }
            let date = Date(timeIntervalSince1970: resets)
            return date > now ? ClaudeLimit(usedPercent: used, resetsAt: date) : nil
        }
        return (limit("five_hour"), limit("seven_day"))
    }
}

@MainActor
@Observable
final class ClaudeUsageService {
    private(set) var usage = ClaudeUsage()
    private(set) var statusLine: ClaudeStatusLine = .notSet
    private(set) var lastError: String?

    @ObservationIgnored private let reader = ClaudeTranscriptReader()
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
        var next = await reader.read()
        let statusFile = ClaudeStatusLine.statusFile
        if let data = try? Data(contentsOf: statusFile) {
            let limits = ClaudeStatusLine.limits(from: data)
            next.fiveHourLimit = limits.fiveHour
            next.weeklyLimit = limits.weekly
            next.limitsUpdatedAt = (try? statusFile.resourceValues(forKeys: [URLResourceKey.contentModificationDateKey]))?.contentModificationDate
        }
        if next != usage { usage = next }
        let line = ClaudeStatusLine.current
        if line != statusLine { statusLine = line }
    }

    func installStatusLine() {
        perform { try ClaudeStatusLine.install() }
    }

    func removeStatusLine() {
        perform { try ClaudeStatusLine.remove() }
    }

    private func perform(_ change: () throws -> Void) {
        do {
            try change()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        Task { await refresh() }
    }
}
