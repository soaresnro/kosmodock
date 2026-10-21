import Foundation
import SwiftUI
import XCTest
@testable import Kosmodock

/// Timer, Pomodoro, Countdown, Stopwatch, Time progress and the world clock:
/// fixed dates and calendars, a scratch directory for the state file, and an
/// alert closure instead of real notifications or sounds.
final class TimeWidgetTests: XCTestCase {
    /// 2033-05-18 03:33:20 UTC.
    private let t0 = Date(timeIntervalSince1970: 2_000_000_000)

    private func minutes(_ value: Double) -> TimeInterval { value * 60 }

    private static func calendar(_ zone: String = "UTC", firstWeekday: Int = 2) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    private static func date(_ text: String, zone: String = "UTC") -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: zone)!
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
        return formatter.date(from: text)!
    }

    private func scratchDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("time-widgets-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: Timer

    func testTimerRemainingAcrossPauseAndResume() {
        var timer = TimerState(duration: minutes(10))
        XCTAssertEqual(timer.phase(at: t0), .idle)
        XCTAssertEqual(timer.remaining(at: t0), minutes(10))
        XCTAssertNil(timer.endDate, "no end while it isn't running")

        timer.toggle(at: t0)
        XCTAssertEqual(timer.phase(at: t0), .running)
        XCTAssertEqual(timer.endDate, t0.addingTimeInterval(minutes(10)))
        XCTAssertEqual(timer.remaining(at: t0.addingTimeInterval(minutes(3))), minutes(7))

        timer.toggle(at: t0.addingTimeInterval(minutes(3)))
        XCTAssertEqual(timer.phase(at: t0.addingTimeInterval(minutes(3))), .paused)
        XCTAssertEqual(timer.remaining(at: t0.addingTimeInterval(minutes(50))), minutes(7), "paused time doesn't count")
        XCTAssertNil(timer.endDate)

        timer.toggle(at: t0.addingTimeInterval(minutes(10)))
        XCTAssertEqual(timer.remaining(at: t0.addingTimeInterval(minutes(15))), minutes(2))
        XCTAssertEqual(timer.endDate, t0.addingTimeInterval(minutes(17)), "10 minutes of running, 7 of pause")
        XCTAssertEqual(timer.fractionRemaining(at: t0.addingTimeInterval(minutes(15))), 0.2, accuracy: 1e-9)

        XCTAssertNil(timer.finishIfDue(at: t0.addingTimeInterval(minutes(16))))
        XCTAssertEqual(timer.finishIfDue(at: t0.addingTimeInterval(minutes(18))), t0.addingTimeInterval(minutes(17)), "the end, not when it was noticed")
        XCTAssertNil(timer.finishIfDue(at: t0.addingTimeInterval(minutes(19))), "it ends once")
        XCTAssertEqual(timer.phase(at: t0.addingTimeInterval(minutes(19))), .finished)
        XCTAssertEqual(timer.remaining(at: t0.addingTimeInterval(minutes(19))), 0)

        // After the end, Start runs the same length again; Reset keeps it too.
        timer.toggle(at: t0.addingTimeInterval(minutes(20)))
        XCTAssertEqual(timer.phase(at: t0.addingTimeInterval(minutes(20))), .running)
        XCTAssertEqual(timer.remaining(at: t0.addingTimeInterval(minutes(21))), minutes(9))
        timer.reset()
        XCTAssertEqual(timer, TimerState(duration: minutes(10)))

        timer.start(duration: minutes(25), at: t0)
        XCTAssertEqual(timer.remaining(at: t0.addingTimeInterval(minutes(5))), minutes(20))
    }

    func testTimeTexts() {
        XCTAssertEqual(TimeText.clock(minutes(5)), "5:00", "a fresh 5-minute timer")
        XCTAssertEqual(TimeText.clock(299.2), "5:00", "rounded up while it counts down")
        XCTAssertEqual(TimeText.clock(299), "4:59")
        XCTAssertEqual(TimeText.clock(0.4), "0:01", "the last second still shows")
        XCTAssertEqual(TimeText.clock(0), "0:00")
        XCTAssertEqual(TimeText.clock(3725), "1:02:05")
        XCTAssertEqual(TimeText.clock(59.9, roundingUp: false), "0:59", "a stopwatch rounds down")
        XCTAssertEqual(TimeText.compact(1499.5), "25:00")
        XCTAssertEqual(TimeText.compact(3725), "1h03", "rounded up to the minute shown")
        XCTAssertEqual(TimeText.compact(3725, roundingUp: false), "1h02")
        XCTAssertEqual(TimeText.stopwatch(42.07), "0:42.07")
        XCTAssertEqual(TimeText.stopwatch(3762.5), "1:02:42.50")
    }

    func testQuickDurationsParse() {
        XCTAssertEqual(TimerOptions.parseDurations("5, 10, 15, 25, 45"), [5, 10, 15, 25, 45])
        XCTAssertEqual(TimerOptions.parseDurations("45 5;5 700 0"), [5, 45], "repeats and out-of-range minutes are dropped")
        XCTAssertEqual(TimerOptions.parseDurations("1, 2, 3, 4, 5, 6, 7, 8, 9, 10")?.count, TimerOptions.maxDurations)
        XCTAssertNil(TimerOptions.parseDurations(""))
        XCTAssertNil(TimerOptions.parseDurations("abc, 0"))
    }

    // MARK: Pomodoro

    func testPomodoroCycleSequence() {
        let options = PomodoroOptions(focusMinutes: 25, shortBreakMinutes: 5, longBreakMinutes: 15, longBreakAfter: 3, autoStartBreaks: true)
        var pomodoro = PomodoroState()
        XCTAssertNil(pomodoro.endDate(options: options), "it waits to be started")
        XCTAssertEqual(pomodoro.advance(to: t0.addingTimeInterval(minutes(100)), options: options), [])

        var now = t0
        var sequence: [PomodoroStretch] = []
        for _ in 0..<3 {
            // Each focus waits for a click; its break starts on its own.
            XCTAssertEqual(pomodoro.stretch, .focus)
            XCTAssertFalse(pomodoro.clock.isRunning)
            pomodoro.toggle(at: now)
            let focusEnd = now.addingTimeInterval(minutes(25))
            let ends = pomodoro.advance(to: focusEnd.addingTimeInterval(1), options: options)
            XCTAssertEqual(ends.map(\.stretch), [.focus])
            XCTAssertEqual(ends.first?.at, focusEnd)
            XCTAssertEqual(pomodoro.clock.startedAt, focusEnd, "the break starts when the focus ended, not when it was noticed")
            sequence.append(pomodoro.stretch)
            let breakEnd = focusEnd.addingTimeInterval(options.duration(for: pomodoro.stretch))
            // The break ends while nobody looks: the next focus is ready, not running.
            XCTAssertEqual(pomodoro.advance(to: breakEnd.addingTimeInterval(minutes(30)), options: options).map(\.at), [breakEnd])
            now = breakEnd.addingTimeInterval(minutes(31))
        }
        XCTAssertEqual(sequence, [.shortBreak, .shortBreak, .longBreak], "a long break after three focus stretches")
        XCTAssertEqual(pomodoro.cycleCount, 0, "the long break starts a new cycle")
        XCTAssertEqual(pomodoro.stretch, .focus)
        XCTAssertFalse(pomodoro.clock.isRunning)
        XCTAssertEqual(pomodoro.completions.count, 3)
    }

    func testPomodoroWaitsForBreaksAndSkips() {
        let options = PomodoroOptions(focusMinutes: 20, longBreakAfter: 2)
        var pomodoro = PomodoroState()
        pomodoro.toggle(at: t0)
        // Paused for five minutes in the middle.
        pomodoro.toggle(at: t0.addingTimeInterval(minutes(10)))
        pomodoro.toggle(at: t0.addingTimeInterval(minutes(15)))
        XCTAssertEqual(pomodoro.remaining(options: options, at: t0.addingTimeInterval(minutes(20))), minutes(5))
        let ends = pomodoro.advance(to: t0.addingTimeInterval(minutes(60)), options: options)
        XCTAssertEqual(ends, [PomodoroState.End(stretch: .focus, at: t0.addingTimeInterval(minutes(25)), next: .shortBreak)])
        XCTAssertEqual(pomodoro.stretch, .shortBreak)
        XCTAssertFalse(pomodoro.clock.isRunning, "without auto-start the break waits too")
        XCTAssertEqual(pomodoro.remaining(options: options, at: t0.addingTimeInterval(minutes(60))), minutes(5))

        // Skipping counts nothing.
        pomodoro.skip(options: options)
        XCTAssertEqual(pomodoro.stretch, .focus)
        XCTAssertEqual(pomodoro.nextStretch(options: options), .longBreak, "the second focus of two leads to the long break")
        pomodoro.skip(options: options)
        XCTAssertEqual(pomodoro.stretch, .shortBreak, "a skipped focus isn't a finished one")
        XCTAssertEqual(pomodoro.cycleCount, 1)
        XCTAssertEqual(pomodoro.completions.count, 1)

        pomodoro.reset()
        XCTAssertEqual(pomodoro.stretch, .focus)
        XCTAssertEqual(pomodoro.cycleCount, 0)
        XCTAssertEqual(pomodoro.completions.count, 1, "reset keeps today's sessions")
    }

    func testPomodoroCountsTodaysSessions() {
        let calendar = Self.calendar()
        let morning = Self.date("2026-10-21T09:00:00")
        var pomodoro = PomodoroState()
        pomodoro.completions = [
            Self.date("2026-10-19T10:00:00"),
            Self.date("2026-10-20T23:59:00"),
            Self.date("2026-10-21T00:01:00"),
            Self.date("2026-10-21T08:30:00"),
        ]
        XCTAssertEqual(pomodoro.completedToday(at: morning, calendar: calendar), 2)
        pomodoro.pruneCompletions(before: morning, calendar: calendar)
        XCTAssertEqual(pomodoro.completions.count, 3, "yesterday's stay, older ones go")
        XCTAssertEqual(PomodoroOptions(longBreakAfter: 40).stretchesPerCycle, 8, "kept in range for hand-edited configs")
        XCTAssertEqual(PomodoroOptions(focusMinutes: 0).minutes(for: .focus), 1)
    }

    // MARK: Countdown

    func testCountdownBeforeAndAfterItsTarget() {
        let calendar = Self.calendar()
        // 2 d 5 h 30 min 20 s. A sum of literals here takes the type checker minutes.
        let target = t0.addingTimeInterval(192_620)
        let before = CountdownReading.at(t0, target: target, countsUp: true, calendar: calendar)
        XCTAssertEqual(before, CountdownReading(isPast: false, days: 2, hours: 5, minutes: 31), "minutes round up while counting down")
        XCTAssertEqual(before.text(locale: Locale(identifier: "en_US"), calendar: calendar), "2d 5h")
        XCTAssertEqual(before.shortText(locale: Locale(identifier: "en_US"), calendar: calendar), "2d")

        let lastSeconds = CountdownReading.at(target.addingTimeInterval(-20), target: target, countsUp: false, calendar: calendar)
        XCTAssertEqual(lastSeconds, CountdownReading(isPast: false, days: 0, hours: 0, minutes: 1), "20 seconds left reads one minute")
        XCTAssertEqual(lastSeconds.text(locale: Locale(identifier: "en_US"), calendar: calendar), "1m")

        let exactly = CountdownReading.at(target.addingTimeInterval(-3600), target: target, countsUp: false, calendar: calendar)
        XCTAssertEqual(exactly, CountdownReading(isPast: false, days: 0, hours: 1, minutes: 0))

        let later = target.addingTimeInterval(273_659) // 3 d 4 h 0 min 59 s
        XCTAssertEqual(CountdownReading.at(later, target: target, countsUp: true, calendar: calendar),
                       CountdownReading(isPast: true, days: 3, hours: 4, minutes: 0), "after it, the time since")
        let stopped = CountdownReading.at(later, target: target, countsUp: false, calendar: calendar)
        XCTAssertTrue(stopped.isPast)
        XCTAssertTrue(stopped.isZero, "without counting up it stays at zero")
        XCTAssertTrue(CountdownReading.at(target, target: target, countsUp: true, calendar: calendar).isPast, "the moment itself has passed")
    }

    func testCountdownCountsCalendarDaysAcrossDaylightSaving() {
        // Lisbon springs forward on 2026-03-29: that day has 23 hours.
        let calendar = Self.calendar("Europe/Lisbon")
        let now = Self.date("2026-03-28T12:00:00", zone: "Europe/Lisbon")
        let target = Self.date("2026-03-30T12:00:00", zone: "Europe/Lisbon")
        XCTAssertEqual(CountdownReading.at(now, target: target, countsUp: false, calendar: calendar),
                       CountdownReading(isPast: false, days: 2, hours: 0, minutes: 0))
    }

    // MARK: Time progress

    func testTimeProgressOfDayWeekMonthAndYear() throws {
        let calendar = Self.calendar(firstWeekday: 2)
        func fraction(_ period: TimePeriod, _ date: String, _ calendar: Calendar = Self.calendar(firstWeekday: 2)) throws -> Double {
            try XCTUnwrap(TimeProgress.of(period, at: Self.date(date), calendar: calendar)).fraction
        }
        XCTAssertEqual(try fraction(.day, "2026-10-21T00:00:00"), 0)
        XCTAssertEqual(try fraction(.day, "2026-10-21T06:00:00"), 0.25, accuracy: 1e-9)
        XCTAssertEqual(try fraction(.day, "2026-10-21T23:59:59"), 86_399.0 / 86_400, accuracy: 1e-9)

        // 2026-10-19 is a Monday.
        XCTAssertEqual(try fraction(.week, "2026-10-19T00:00:00"), 0, "weeks start on Monday here")
        XCTAssertEqual(try fraction(.week, "2026-10-22T12:00:00"), 0.5, accuracy: 1e-9)
        XCTAssertEqual(try fraction(.week, "2026-10-18T12:00:00", Self.calendar(firstWeekday: 1)), 0.5 / 7, accuracy: 1e-9, "and on Sunday where the week starts then")
        let week = try XCTUnwrap(TimeProgress.of(.week, at: Self.date("2026-10-22T12:00:00"), calendar: calendar))
        XCTAssertEqual(week.interval.start, Self.date("2026-10-19T00:00:00"))
        XCTAssertEqual(week.interval.end, Self.date("2026-10-26T00:00:00"))

        XCTAssertEqual(try fraction(.month, "2024-02-15T00:00:00"), 14.0 / 29, accuracy: 1e-9, "a leap February")
        XCTAssertEqual(try fraction(.month, "2026-02-15T00:00:00"), 14.0 / 28, accuracy: 1e-9)
        XCTAssertEqual(try fraction(.month, "2026-12-01T00:00:00"), 0)

        XCTAssertEqual(try fraction(.year, "2024-07-02T00:00:00"), 0.5, accuracy: 1e-9, "day 183 of 366")
        XCTAssertEqual(try fraction(.year, "2026-07-02T12:00:00"), 0.5, accuracy: 1e-9, "day 182.5 of 365")
        XCTAssertEqual(try fraction(.year, "2026-12-31T23:59:59"), 1, accuracy: 1e-7)
        XCTAssertEqual(try fraction(.year, "2027-01-01T00:00:00"), 0)

        // A 23-hour day: at noon 11 of its 23 hours have passed.
        let lisbon = Self.calendar("Europe/Lisbon")
        let noon = Self.date("2026-03-29T12:00:00", zone: "Europe/Lisbon")
        XCTAssertEqual(try XCTUnwrap(TimeProgress.of(.day, at: noon, calendar: lisbon)).fraction, 11.0 / 23, accuracy: 1e-9)
    }

    // MARK: Stopwatch

    func testStopwatchLapsAcrossPauses() {
        var stopwatch = StopwatchState()
        stopwatch.lap(at: t0)
        XCTAssertTrue(stopwatch.laps.isEmpty, "no laps before it starts")
        stopwatch.toggle(at: t0)
        stopwatch.lap(at: t0.addingTimeInterval(30))
        stopwatch.toggle(at: t0.addingTimeInterval(40))
        XCTAssertEqual(stopwatch.elapsed(at: t0.addingTimeInterval(500)), 40)
        stopwatch.lap(at: t0.addingTimeInterval(500))
        XCTAssertEqual(stopwatch.laps, [30], "no laps while paused")
        stopwatch.toggle(at: t0.addingTimeInterval(600))
        stopwatch.lap(at: t0.addingTimeInterval(625))
        XCTAssertEqual(stopwatch.laps, [30, 65])
        XCTAssertEqual(stopwatch.lapDurations, [30, 35])
        XCTAssertEqual(stopwatch.currentLap(at: t0.addingTimeInterval(630)), 5)
        stopwatch.reset()
        XCTAssertEqual(stopwatch, StopwatchState())
    }

    // MARK: Persistence

    func testStateRoundTripKeepsDatesToTheMillisecond() throws {
        var state = TimeWidgetState()
        let started = Date(timeIntervalSince1970: 2_000_000_000.123_456)
        state.timers["timer"] = TimerState(duration: 1500, clock: RunClock(accumulated: 12.5, startedAt: started))
        state.timers["done"] = TimerState(duration: 300, clock: RunClock(accumulated: 300), finishedAt: t0)
        state.pomodoros["pomodoro"] = PomodoroState(stretch: .longBreak, clock: RunClock(accumulated: 61), cycleCount: 3, completions: [t0, t0.addingTimeInterval(1800)])
        state.stopwatches["stopwatch"] = StopwatchState(clock: RunClock(startedAt: started), laps: [1.25, 9.5])

        let data = try TimeWidgetState.encoded(state)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"2033-05-18T03:33:20.123Z\""), "readable dates: \(text)")
        let decoded = try TimeWidgetState.decoded(from: data)
        let startedAt = try XCTUnwrap(decoded.timers["timer"]?.clock.startedAt)
        XCTAssertEqual(startedAt.timeIntervalSince1970, started.timeIntervalSince1970, accuracy: 0.001)
        var expected = state
        expected.timers["timer"]?.clock.startedAt = startedAt
        expected.stopwatches["stopwatch"]?.clock.startedAt = decoded.stopwatches["stopwatch"]?.clock.startedAt
        XCTAssertEqual(decoded, expected)

        // Missing keys fall back; a file from a version without stopwatches still reads.
        let old = try TimeWidgetState.decoded(from: Data(#"{ "timers": { "t": { "duration": 600, "clock": { "startedAt": "2033-05-18T03:33:20Z" } } } }"#.utf8))
        XCTAssertEqual(old.timers["t"]?.endDate, t0.addingTimeInterval(600))
        XCTAssertEqual(old.pomodoros, [:])
        XCTAssertEqual(try TimeWidgetState.decoded(from: Data("{}".utf8)), TimeWidgetState())
        XCTAssertThrowsError(try TimeWidgetState.decoded(from: Data(#"{ "pomodoros": { "p": { "stretch": "nap" } } }"#.utf8)))
    }

    @MainActor
    func testServiceKeepsRunningTimersAcrossRelaunch() throws {
        let directory = scratchDirectory()
        var alerts: [TimeAlert] = []
        let timerTile = DockTile(id: "timer", kind: .timer, timer: TimerOptions(durations: [3, 10], playsSound: false))
        let pomodoroTile = DockTile(id: "pomodoro", kind: .pomodoro, pomodoro: PomodoroOptions(focusMinutes: 25, autoStartBreaks: true))
        let stopwatchTile = DockTile(id: "stopwatch", kind: .stopwatch)
        let tiles = [timerTile, pomodoroTile, stopwatchTile, DockTile(id: "clock", kind: .clock)]

        let first = TimeWidgetService(directory: directory) { alerts.append($0) }
        first.setTiles(tiles, now: t0)
        XCTAssertEqual(first.timer(for: timerTile).duration, minutes(3), "an unused timer offers its first quick duration")
        first.startTimer(timerTile, minutes: 10, now: t0)
        first.togglePomodoro(pomodoroTile, now: t0)
        first.toggleStopwatch(stopwatchTile, now: t0)
        first.lapStopwatch(stopwatchTile, now: t0.addingTimeInterval(12))
        first.stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("time-widgets.json").path))

        // Relaunched four minutes later: the clocks kept going.
        let second = TimeWidgetService(directory: directory) { alerts.append($0) }
        let later = t0.addingTimeInterval(minutes(4))
        XCTAssertEqual(second.timer(for: timerTile).remaining(at: later), minutes(6), accuracy: 0.001)
        XCTAssertEqual(second.stopwatch(for: stopwatchTile).elapsed(at: later), minutes(4), accuracy: 0.001)
        XCTAssertEqual(second.stopwatch(for: stopwatchTile).laps, [12])
        second.setTiles(tiles, now: later)
        XCTAssertTrue(alerts.isEmpty)

        // The timer ends while Kosmodock runs: one alert, at the end.
        second.tick(now: t0.addingTimeInterval(minutes(10) + 1))
        XCTAssertEqual(alerts.map(\.tileID), ["timer"])
        XCTAssertFalse(alerts[0].playsSound, "the tile's sound setting")
        XCTAssertEqual(second.timer(for: timerTile).phase(at: t0.addingTimeInterval(minutes(11))), .finished)
        second.tick(now: t0.addingTimeInterval(minutes(10) + 2))
        XCTAssertEqual(alerts.count, 1, "an end is told once")

        // The pomodoro's focus ended long ago (Kosmodock was quit): no alert,
        // but the break that started then and ended too, and focus waits.
        second.tick(now: t0.addingTimeInterval(minutes(90)))
        XCTAssertEqual(alerts.count, 1, "late ends are silent")
        let pomodoro = second.pomodoro(for: pomodoroTile)
        XCTAssertEqual(pomodoro.stretch, .focus)
        XCTAssertFalse(pomodoro.clock.isRunning)
        XCTAssertEqual(pomodoro.completions, [t0.addingTimeInterval(minutes(25))])
        second.stop()

        let third = TimeWidgetService(directory: directory) { alerts.append($0) }
        XCTAssertEqual(third.pomodoro(for: pomodoroTile).completions, [t0.addingTimeInterval(minutes(25))], "saved after the stretch ended")
        third.stop()
    }

    @MainActor
    func testServiceDropsStateOfRemovedTilesOnly() {
        let directory = scratchDirectory()
        let timerTile = DockTile(id: "timer", kind: .timer)
        let service = TimeWidgetService(directory: directory) { _ in }
        service.startTimer(timerTile, minutes: 5, now: t0)
        // A config that failed to load has no tiles: nothing is dropped.
        service.setTiles([], now: t0)
        XCTAssertNotNil(service.state.timers["timer"])
        service.setTiles([timerTile], now: t0)
        XCTAssertNotNil(service.state.timers["timer"])
        // A tile whose kind changed loses its timer, as does a removed one.
        service.setTiles([DockTile(id: "timer", kind: .stopwatch)], now: t0)
        XCTAssertNil(service.state.timers["timer"])
        service.stop()
    }

    @MainActor
    func testPomodoroAlertsTellWhatComesNext() {
        let tile = DockTile(id: "p", kind: .pomodoro, pomodoro: PomodoroOptions(autoStartBreaks: false))
        let focus = TimeWidgetService.alert(pomodoroOf: tile, end: PomodoroState.End(stretch: .focus, at: t0, next: .longBreak))
        XCTAssertEqual(focus.tileID, "p")
        XCTAssertEqual(focus.body, "Time for a long break.")
        XCTAssertTrue(focus.playsSound)
        let pause = TimeWidgetService.alert(pomodoroOf: tile, end: PomodoroState.End(stretch: .shortBreak, at: t0, next: .focus))
        XCTAssertEqual(pause.title, "Break's over")
        XCTAssertEqual(TimeWidgetService.alert(timerOf: DockTile(id: "t", kind: .timer), duration: 1500).body, "Your 25 min timer is done.")
    }

    // MARK: Config

    private func tiles(_ json: String) throws -> [DockTile] {
        try JSONDecoder().decode(DockConfig.self, from: Data(json.utf8)).tiles
    }

    func testOldConfigsDecodeWithDefaults() throws {
        let old = try tiles(#"{ "tiles": [ { "kind": "clock", "showsSeconds": true }, { "kind": "battery", "width": "square" } ] }"#)
        XCTAssertNil(old[0].timeZone)
        XCTAssertEqual(old[0].clockFace, .digital)
        XCTAssertFalse(old[0].isWorldClock)
        XCTAssertEqual(old[0].timeZoneValue.identifier, TimeZone.current.identifier)
        XCTAssertEqual(old[1].timerOptions, TimerOptions())
        XCTAssertEqual(old[1].pomodoroOptions, PomodoroOptions())
        XCTAssertEqual(old[1].timePeriod, .day)

        // A tile without time options writes none.
        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(old[1]), encoding: .utf8))
        for key in ["timeZone", "face", "timer", "pomodoro", "countdown", "period"] {
            XCTAssertFalse(encoded.contains("\"\(key)\""), "\(key) in \(encoded)")
        }

        let new = try tiles(#"""
        { "tiles": [
            { "kind": "timer", "timer": { "durations": [3, 0, 999, 20] } },
            { "kind": "pomodoro", "pomodoro": { "focusMinutes": 50, "autoStartBreaks": true } },
            { "kind": "countdown", "label": "Launch", "countdown": { "target": "2026-12-24T18:00:00-03:00", "countsUp": true } },
            { "kind": "countdown", "countdown": { "target": "2026-12-31" } },
            { "kind": "stopwatch" },
            { "kind": "timeProgress", "period": "year", "width": "square" },
            { "kind": "clock", "timeZone": "Asia/Tokyo", "face": "analog" },
            { "kind": "clock", "timeZone": "Mars/Olympus_Mons" }
        ] }
        """#)
        XCTAssertEqual(new.map(\.kind), [.timer, .pomodoro, .countdown, .countdown, .stopwatch, .timeProgress, .clock, .clock])
        XCTAssertEqual(new[0].timerOptions.durations, [3, 20], "out-of-range minutes are dropped")
        XCTAssertTrue(new[0].timerOptions.playsSound)
        XCTAssertEqual(new[1].pomodoroOptions, PomodoroOptions(focusMinutes: 50, autoStartBreaks: true))
        XCTAssertEqual(new[2].countdownOptions.target, Self.date("2026-12-24T21:00:00"))
        XCTAssertTrue(new[2].countdownOptions.countsUp)
        XCTAssertEqual(new[2].title, "Launch")
        XCTAssertNotNil(new[3].countdownOptions.target, "a day alone is midnight here")
        XCTAssertFalse(new[3].countdownOptions.countsUp)
        XCTAssertEqual(new[3].title, "Countdown")
        XCTAssertEqual(new[5].timePeriod, .year)
        XCTAssertEqual(new[6].clockFace, .analog)
        XCTAssertEqual(new[6].title, "Tokyo")
        XCTAssertTrue(new[6].isWorldClock)
        XCTAssertFalse(new[7].isWorldClock, "an unknown zone is this Mac's")
        XCTAssertEqual(new[7].title, "Clock")
        XCTAssertEqual(new.map(\.id), ["timer", "pomodoro", "countdown", "countdown-2", "stopwatch", "timeProgress", "clock", "clock-2"])

        XCTAssertThrowsError(try tiles(#"{ "tiles": [ { "kind": "countdown", "countdown": { "target": "next friday" } } ] }"#))
        XCTAssertThrowsError(try tiles(#"{ "tiles": [ { "kind": "timeProgress", "period": "decade" } ] }"#))
    }

    func testTimeOptionsRoundTrip() throws {
        var tile = DockTile(id: "launch", kind: .countdown, label: "Launch")
        tile.applyTimeDefaults(now: Self.date("2026-10-21T12:00:00"))
        let target = try XCTUnwrap(tile.countdown?.target)
        XCTAssertEqual(Calendar.current.dateComponents([.year, .month, .day, .hour], from: target), DateComponents(year: 2027, month: 1, day: 1, hour: 0),
                       "a new countdown counts to New Year")
        tile.countdown?.countsUp = true
        var config = DockConfig()
        config.tiles = [
            tile,
            DockTile(id: "focus", kind: .pomodoro, pomodoro: PomodoroOptions(shortBreakMinutes: 7, longBreakAfter: 3, playsSound: false)),
            DockTile(id: "tokyo", kind: .clock, width: .square, timeZone: "Asia/Tokyo", face: .analog),
            DockTile(id: "year", kind: .timeProgress, period: .year),
        ]
        let data = try JSONEncoder().encode(config)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"target\":\""), "the target is an ISO 8601 string")
        let decoded = try JSONDecoder().decode(DockConfig.self, from: data)
        XCTAssertEqual(decoded.tiles[0].countdown?.target?.timeIntervalSince1970 ?? 0, target.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(Array(decoded.tiles.dropFirst()), Array(config.tiles.dropFirst()))
    }

    func testTimeWidgetsAreInTheTimeCategory() {
        let time = TileKind.allCases.filter { $0.category == .time }
        XCTAssertEqual(time, [.clock, .timer, .pomodoro, .countdown, .stopwatch, .timeProgress])
        XCTAssertEqual(TileKind.allCases.last, .command, "time widgets come before Command")
    }

    // MARK: World clock

    func testTimeZoneSearchAndOffsets() throws {
        XCTAssertEqual(TimeZoneCatalog.city(of: "America/Argentina/Buenos_Aires"), "Buenos Aires")
        XCTAssertEqual(TimeZoneCatalog.region(of: "America/Argentina/Buenos_Aires"), "America · Argentina")
        XCTAssertEqual(TimeZoneCatalog.city(of: "UTC"), "UTC")
        let english = Locale(identifier: "en_US")
        XCTAssertTrue(TimeZoneCatalog.search("tokyo", locale: english).contains("Asia/Tokyo"))
        XCTAssertTrue(TimeZoneCatalog.search("São Paulo", locale: english).contains("America/Sao_Paulo"), "accents don't matter")
        XCTAssertTrue(TimeZoneCatalog.search("new york", locale: english).contains("America/New_York"), "words in any order and case")
        XCTAssertTrue(TimeZoneCatalog.search("zzzz-nowhere", locale: english).isEmpty)
        let all = TimeZoneCatalog.search("", in: ["Europe/Lisbon", "Asia/Tokyo", "America/Argentina/Buenos_Aires"], locale: english)
        XCTAssertEqual(all, ["America/Argentina/Buenos_Aires", "Europe/Lisbon", "Asia/Tokyo"], "by city")

        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let kolkata = try XCTUnwrap(TimeZone(identifier: "Asia/Kolkata"))
        XCTAssertEqual(TimeZoneCatalog.offset(of: tokyo, from: utc, at: t0), 9 * 3600)
        XCTAssertEqual(TimeZoneCatalog.offset(of: utc, from: kolkata, at: t0), -19_800) // 5 h 30 min
    }

    func testAnalogHandsPointAtTheTimeInTheirZone() throws {
        let threeInLondon = Self.date("2026-01-15T15:00:00")  // winter: London is UTC
        let london = try XCTUnwrap(TimeZone(identifier: "Europe/London"))
        let hands = AnalogClockFace.angles(at: threeInLondon, zone: london)
        XCTAssertEqual(hands.hour, .pi / 2, accuracy: 1e-9)
        XCTAssertEqual(hands.minute, 0, accuracy: 1e-9)
        let tokyo = AnalogClockFace.angles(at: threeInLondon.addingTimeInterval(30 * 60), zone: try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo")))
        // 00:30 in Tokyo: the hour hand just past 12, the minute hand at 6.
        XCTAssertEqual(tokyo.hour, 0.5 / 12 * 2 * .pi, accuracy: 1e-9)
        XCTAssertEqual(tokyo.minute, .pi, accuracy: 1e-9)
    }

    func testTickerAlignsToTheSecondsOfARunningClock() {
        let end = t0.addingTimeInterval(299.4)
        let aligned = TimeTicker<EmptyView>.aligned(end, now: t0)
        XCTAssertLessThanOrEqual(aligned, t0)
        XCTAssertEqual(end.timeIntervalSince(aligned).truncatingRemainder(dividingBy: 1), 1 - 0.02, accuracy: 1e-6, "just after a displayed second turns")
        XCTAssertEqual(TimeTicker<EmptyView>.aligned(t0, now: t0.addingTimeInterval(0.01)).timeIntervalSince(t0), -0.98, accuracy: 1e-6, "never after now")
    }
}
