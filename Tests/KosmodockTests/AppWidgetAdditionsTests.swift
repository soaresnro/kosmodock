import AppKit
import Foundation
import XCTest
@testable import Kosmodock

/// Codex, Reminders and Music's album artwork: parsing and ordering only, with
/// no network, permissions or real apps.
final class AppWidgetAdditionsTests: XCTestCase {
    // MARK: Codex

    private static func stamp(_ date: Date) -> String {
        ISO8601DateFormatter.string(from: date, timeZone: TimeZone(identifier: "UTC")!, formatOptions: [.withInternetDateTime, .withFractionalSeconds])
    }

    private static func usage(input: Int, cached: Int = 0, output: Int, reasoning: Int = 0) -> String {
        #"{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"cache_write_input_tokens":0,"output_tokens":\#(output),"reasoning_output_tokens":\#(reasoning),"total_tokens":\#(input + output)}"#
    }

    /// A `token_count` event as Codex writes it; `last` nil leaves it out.
    private static func tokenCount(at date: Date, last: (input: Int, output: Int)?, total: (input: Int, output: Int), limits: String = "null") -> String {
        let lastJSON = last.map { #""last_token_usage":\#(usage(input: $0.input, cached: $0.input / 2, output: $0.output, reasoning: $0.output / 4)),"# } ?? ""
        return #"{"timestamp":"\#(stamp(date))","ordinal":1,"type":"event_msg","payload":{"type":"token_count","info":{\#(lastJSON)"total_token_usage":\#(usage(input: total.input, output: total.output)),"model_context_window":258400},"rate_limits":\#(limits)}}"#
    }

    private static func turnContext(at date: Date, model: String) -> String {
        #"{"timestamp":"\#(stamp(date))","ordinal":1,"type":"turn_context","payload":{"turn_id":"t","cwd":"/tmp","model":"\#(model)","effort":"high"}}"#
    }

    private func line(_ text: String) -> CodexSessionReader.Line? {
        CodexSessionReader.line(from: Data(text.utf8))
    }

    func testCodexTokenCountLines() throws {
        let date = Date(timeIntervalSince1970: 2_000_000_000)
        // As on a Mac today: one weekly window, as `primary`, with an epoch reset.
        let weeklyOnly = #"{"limit_id":"codex","limit_name":null,"primary":{"used_percent":12.5,"window_minutes":10080,"resets_at":2000300000},"secondary":null,"credits":{"has_credits":false,"unlimited":false,"balance":"0"},"plan_type":"plus","rate_limit_reached_type":null}"#
        guard case .tokenCount(let parsedDate, let last, let total, let limits) = line(Self.tokenCount(at: date, last: (1_000, 200), total: (5_000, 900), limits: weeklyOnly)) else {
            return XCTFail("a token_count line")
        }
        XCTAssertEqual(parsedDate, date)
        XCTAssertEqual(last, CodexTokens(input: 1_000, cachedInput: 500, output: 200, reasoningOutput: 50, total: 1_200))
        XCTAssertEqual(total?.total, 5_900)
        XCTAssertNil(limits?.fiveHour)
        XCTAssertEqual(limits?.weekly, ClaudeLimit(usedPercent: 12.5, resetsAt: Date(timeIntervalSince1970: 2_000_300_000)))
        XCTAssertEqual(limits?.id, "codex")

        // Older versions: both windows, resets relative to the line, no lengths.
        let relative = #"{"primary":{"used_percent":40,"resets_in_seconds":3600},"secondary":{"used_percent":7.5,"resets_in_seconds":86400}}"#
        guard case .tokenCount(_, _, _, let older) = line(Self.tokenCount(at: date, last: (1, 1), total: (1, 1), limits: relative)) else {
            return XCTFail("a token_count line")
        }
        XCTAssertEqual(older?.fiveHour, ClaudeLimit(usedPercent: 40, resetsAt: date.addingTimeInterval(3600)), "primary is the 5-hour window by default")
        XCTAssertEqual(older?.weekly, ClaudeLimit(usedPercent: 7.5, resetsAt: date.addingTimeInterval(86_400)))

        // Lengths win over the position.
        let swapped = #"{"primary":{"used_percent":3,"window_minutes":10080,"resets_at":2000300000},"secondary":{"used_percent":60,"window_minutes":300,"resets_at":2000010000}}"#
        let both = CodexSessionReader.rateLimits(from: try JSONSerialization.jsonObject(with: Data(swapped.utf8)), at: date)
        XCTAssertEqual(both?.fiveHour?.usedPercent, 60)
        XCTAssertEqual(both?.weekly?.usedPercent, 3)

        // Before the first response `info` is null; the limits still count.
        let noInfo = #"{"timestamp":"2033-05-18T03:33:20Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":\#(weeklyOnly)}}"#
        guard case .tokenCount(let wholeSeconds, nil, nil, let onlyLimits) = line(noInfo) else { return XCTFail("info can be null") }
        XCTAssertEqual(wholeSeconds, date, "timestamps without fractions read too")
        XCTAssertNotNil(onlyLimits?.weekly)

        XCTAssertEqual(line(Self.turnContext(at: date, model: "gpt-5.5-codex")), .turnContext(model: "gpt-5.5-codex"))
        XCTAssertNil(line(#"{"timestamp":"2033-05-18T03:33:20.000Z","type":"response_item","payload":{"type":"message","content":[{"text":"what's a \"token_count\"?"}]}}"#), "messages are skipped even when they mention it")
        XCTAssertNil(line(#"{"type":"event_msg","payload":{"type":"token_count","info":null}}"#), "no timestamp")
        XCTAssertNil(line(#"{"type":"event_msg","payload":{"type":"token_count""#), "half-written")
        XCTAssertNil(CodexSessionReader.rateLimits(from: NSNull(), at: date))
        XCTAssertNil(CodexSessionReader.rateLimits(from: ["primary": NSNull(), "secondary": NSNull()], at: date), "no windows, no limits")
    }

    func testCodexSessionsCountEachTurnOnceAndReadIncrementally() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("codex-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let reader = CodexSessionReader(home: home)
        let empty = await reader.read()
        XCTAssertFalse(empty.hasSessions, "Codex hasn't run")
        XCTAssertEqual(empty.lastSevenDays.total, 0)

        let day = home.appendingPathComponent("sessions/2026/10/21")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        // Noon today, so "today" and "5 hours" don't depend on when the test runs.
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3600)
        func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }
        let limits = #"{"limit_id":"codex","primary":{"used_percent":20,"window_minutes":300,"resets_at":\#(Int(now.timeIntervalSince1970) + 3600)},"secondary":{"used_percent":55,"window_minutes":10080,"resets_at":\#(Int(now.timeIntervalSince1970) - 60)}}"#
        let lines = [
            Self.turnContext(at: ago(8 * 24), model: "gpt-5-codex"),
            Self.tokenCount(at: ago(8 * 24), last: (100, 10), total: (100, 10)),               // 110, a week ago: out
            Self.tokenCount(at: ago(3 * 24), last: (1_000, 100), total: (1_100, 110)),         // 1,100: 7 days
            Self.turnContext(at: ago(7), model: "gpt-5.5-codex"),
            Self.tokenCount(at: ago(7), last: (2_000, 200), total: (3_100, 310)),              // 2,200: today
            Self.tokenCount(at: ago(0.5), last: (400, 40), total: (3_500, 350)),               // 440: 5 hours
            Self.tokenCount(at: ago(0.49), last: (400, 40), total: (3_500, 350), limits: limits), // repeated: nothing new
            Self.tokenCount(at: ago(0.4), last: nil, total: (3_600, 360)),                     // 110 from the totals
            #"{"type":"response_item","payload":{"type":"reasoning"}}"#,
        ]
        let file = day.appendingPathComponent("rollout-2026-10-21T10-00-00-a.jsonl")
        let partial = Self.tokenCount(at: ago(0.2), last: (50, 5), total: (3_650, 365))
        try (lines.joined(separator: "\n") + "\n" + partial.prefix(60)).write(to: file, atomically: true, encoding: .utf8)
        // A forked session that copied the last turn verbatim.
        try (Self.tokenCount(at: ago(0.5), last: (400, 40), total: (3_500, 350)) + "\n").write(to: day.appendingPathComponent("rollout-2026-10-21T11-00-00-b.jsonl"), atomically: true, encoding: .utf8)

        var usage = await reader.read(now: now)
        XCTAssertTrue(usage.hasSessions)
        XCTAssertEqual(usage.lastFiveHours.total, 440 + 110, "the repeated event and the copy count once")
        XCTAssertEqual(usage.today.total, 2_200 + 440 + 110)
        XCTAssertEqual(usage.lastSevenDays.total, 1_100 + 2_200 + 440 + 110)
        XCTAssertEqual(usage.lastSevenDays.cachedInput, 500 + 1_000 + 200, "half of `last` input, none from the totals")
        XCTAssertEqual(usage.lastActivity, ago(0.4))
        XCTAssertEqual(usage.model, "gpt-5.5-codex", "from the turn's context line")
        XCTAssertEqual(usage.fiveHourLimit, ClaudeLimit(usedPercent: 20, resetsAt: Date(timeIntervalSince1970: (now.timeIntervalSince1970 + 3600).rounded(.down))))
        XCTAssertNil(usage.weeklyLimit, "a window that reset is unknown, not 55%")
        XCTAssertEqual(usage.limitsUpdatedAt, ago(0.49))

        // The rest of the last line arrives, then a new turn.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((partial.dropFirst(60) + "\n" + Self.tokenCount(at: ago(0.1), last: (10, 1), total: (3_660, 366)) + "\n").utf8))
        try handle.close()
        usage = await reader.read(now: now)
        XCTAssertEqual(usage.lastFiveHours.total, 440 + 110 + 55 + 11, "only the new lines, each once")
        XCTAssertEqual(usage.model, "gpt-5.5-codex", "the file's model carries over between reads")
        usage = await reader.read(now: now)
        XCTAssertEqual(usage.lastFiveHours.total, 440 + 110 + 55 + 11, "reading again changes nothing")
    }

    // MARK: Reminders

    func testRemindersOrderByDueDateWithUndatedLast() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let items = [
            ReminderItem(id: "undated-b", title: "Water plants"),
            ReminderItem(id: "next-week", title: "Renew passport", due: today.addingTimeInterval(7 * 86_400)),
            ReminderItem(id: "undated-a", title: "Call mom"),
            ReminderItem(id: "in-an-hour", title: "Standup notes", due: now.addingTimeInterval(3600), hasDueTime: true),
            ReminderItem(id: "overdue", title: "Pay rent", due: now.addingTimeInterval(-3 * 86_400), hasDueTime: true),
            ReminderItem(id: "today", title: "Groceries", due: today),
        ]
        XCTAssertEqual(RemindersService.sorted(items).map(\.id), ["overdue", "today", "in-an-hour", "next-week", "undated-a", "undated-b"])
        XCTAssertEqual(RemindersService.dueCount(in: items, at: now), 3, "overdue, today's and the one later today")
        XCTAssertTrue(RemindersService.isOverdue(items[4], at: now))
        XCTAssertFalse(RemindersService.isOverdue(items[5], at: now), "a day without a time is due until the day ends")
        XCTAssertFalse(RemindersService.isOverdue(items[0], at: now))
        XCTAssertNil(RemindersDetails.due(items[0], now: now), "no due date, no text")
        XCTAssertNotNil(RemindersDetails.due(items[3], now: now))
    }

    // MARK: Album artwork

    /// A 2×2 red PNG.
    private static let png = "89504E470D0A1A0A0000000D494844520000000200000002080600000072B60D24000000114944415478DA63F8CFC0F01F8419600C0047CA07F91AB6F1A90000000049454E44AE426082"

    func testArtworkFromOsascriptData() throws {
        let data = try XCTUnwrap(NowPlayingService.artworkData(fromOutput: "«data PNGf\(Self.png)»\n"))
        XCTAssertEqual(data.count, 74)
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        let image = try XCTUnwrap(NowPlayingService.thumbnail(from: data))
        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(NowPlayingService.artworkData(fromOutput: "«data tdta\(Self.png.lowercased())»"), data, "any type code, any case")

        XCTAssertNil(NowPlayingService.artworkData(fromOutput: "«data PNGf89504G»"), "not hex")
        XCTAssertNil(NowPlayingService.artworkData(fromOutput: "«data PNGf89504»"), "half a byte")
        XCTAssertNil(NowPlayingService.artworkData(fromOutput: "«data PNGf»"), "no bytes")
        XCTAssertNil(NowPlayingService.artworkData(fromOutput: "missing value"))
        XCTAssertNil(NowPlayingService.artworkData(fromOutput: ""))
        XCTAssertNil(NowPlayingService.artworkData(fromOutput: "«class PNGf»"))
        let notAnImage = try XCTUnwrap(NowPlayingService.artworkData(fromOutput: "«data JPEGDEADBEEF»"))
        XCTAssertNil(NowPlayingService.thumbnail(from: notAnImage), "hex that isn't an image")
    }

    func testArtworkIsCachedPerTrack() {
        let track = NowPlaying(player: .music, isPlaying: true, title: "So What", artist: "Miles Davis", album: "Kind of Blue", duration: 562, position: 0, sampledAt: Date())
        var later = track
        later.position = 120
        later.isPlaying = false
        XCTAssertEqual(track.artworkKey, later.artworkKey, "the same track keeps its art")
        var next = track
        next.title = "Freddie Freeloader"
        XCTAssertNotEqual(track.artworkKey, next.artworkKey)
    }
}
