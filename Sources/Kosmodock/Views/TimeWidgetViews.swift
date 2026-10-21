import AppKit
import SwiftUI

// Tiles, details and Settings rows for the time widgets: Timer, Pomodoro,
// Countdown, Stopwatch, Time progress, and the Clock's time zone and analog
// face. Their clocks run in TimeWidgetService; the math is in
// Models/TimeWidgets.swift.

// MARK: - Shared

extension DockTile {
    /// A countdown's name, or a world clock's city.
    var timeTitle: String? {
        switch kind {
        case .countdown: label.flatMap { $0.isBlank ? nil : $0 }
        case .clock: isWorldClock ? TimeZoneCatalog.city(of: timeZoneValue.identifier) : nil
        default: nil
        }
    }
}

extension Date.FormatStyle {
    /// The same style in another time zone.
    func inZone(_ zone: TimeZone) -> Date.FormatStyle {
        var style = self
        style.timeZone = zone
        return style
    }
}

extension PomodoroStretch {
    var color: Color {
        switch self {
        case .focus: Color(red: 1, green: 0.42, blue: 0.35)
        case .shortBreak: Color(red: 0.25, green: 0.80, blue: 0.52)
        case .longBreak: Color(red: 0.32, green: 0.62, blue: 1)
        }
    }

    var symbol: String {
        switch self {
        case .focus: "brain.head.profile"
        case .shortBreak: "cup.and.saucer.fill"
        case .longBreak: "leaf.fill"
        }
    }
}

/// Redraws once a second, right after the displayed second changes, while a
/// clock runs; draws once while it's stopped.
struct TimeTicker<Content: View>: View {
    /// A moment a displayed second turns over (a timer's end, a stopwatch's
    /// start); nil while nothing runs.
    let anchor: Date?
    let content: (Date) -> Content

    init(anchor: Date?, @ViewBuilder content: @escaping (Date) -> Content) {
        self.anchor = anchor
        self.content = content
    }

    var body: some View {
        if let anchor {
            TimelineView(.periodic(from: Self.aligned(anchor, now: Date()), by: 1)) { context in
                content(context.date)
            }
        } else {
            content(Date())
        }
    }

    /// The last turn of a second at or before `now`, plus a hair, so rounding
    /// lands past it.
    static func aligned(_ anchor: Date, now: Date) -> Date {
        let aligned = anchor.addingTimeInterval(now.timeIntervalSince(anchor).rounded(.down) + 0.02)
        return aligned > now ? aligned.addingTimeInterval(-1) : aligned
    }
}

/// A small round button inside a wide tile.
struct TileControlButton: View {
    let symbol: String
    let help: String
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .heavy))
                .frame(width: 17, height: 17)
                .background(Circle().fill(Color.primary.opacity(0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .help(help)
    }
}

/// A ring that empties as the time runs out, with the time inside.
private struct CountdownRing: View {
    let fraction: Double
    let color: Color
    let text: String
    var dimmed = false
    var lineWidth: CGFloat = 2.6
    var fontSize: CGFloat = 8.5

    var body: some View {
        ZStack {
            RingGauge(value: fraction, color: color, lineWidth: lineWidth)
            Text(verbatim: text)
                .font(.system(size: fontSize, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, lineWidth + 1.5)
                .foregroundStyle(dimmed ? .secondary : .primary)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

// MARK: - Timer

struct TimerTile: View {
    @Environment(AppModel.self) private var model
    let tile: DockTile
    let isWide: Bool

    var body: some View {
        let service = model.timeWidgets
        let timer = service.timer(for: tile)
        TimeTicker(anchor: timer.endDate) { now in
            let phase = timer.phase(at: now)
            let remaining = timer.remaining(at: now)
            if isWide {
                HStack(spacing: 5) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: TimeText.clock(remaining))
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(phase == .finished ? model.accent : .primary)
                        // A running timer's end time, with a bell: "Ends 17:20" doesn't fit.
                        HStack(spacing: 2) {
                            if phase == .running, let end = timer.endDate {
                                Image(systemName: "bell.fill").font(.system(size: 6.5, weight: .bold))
                                Text(end.formatted(.dateTime.hour().minute().locale(L10n.locale)))
                            } else {
                                Text(TimerLook.caption(timer, phase: phase))
                            }
                        }
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                    TileControlButton(symbol: phase == .running ? "pause.fill" : "play.fill", help: TimerLook.toggleTitle(phase)) {
                        service.toggleTimer(tile)
                    }
                    TileControlButton(symbol: "arrow.counterclockwise", help: L10n.tr("Reset (clock)"), isEnabled: phase != .idle) {
                        service.resetTimer(tile)
                    }
                }
            } else if phase == .finished {
                ZStack {
                    RingGauge(value: 1, color: model.accent, lineWidth: 2.6)
                    Image(systemName: "bell.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(model.accent)
                }
                .aspectRatio(1, contentMode: .fit)
                .padding(2)
            } else {
                CountdownRing(
                    fraction: phase == .idle ? 1 : timer.fractionRemaining(at: now), color: model.accent,
                    text: TimeText.compact(remaining), dimmed: phase == .paused
                )
                .padding(2)
            }
        }
    }
}

enum TimerLook {
    /// "Ends 14:35", "Paused", "Done" or the length of an idle timer.
    static func caption(_ timer: TimerState, phase: TimerState.Phase) -> String {
        switch phase {
        case .running:
            let end = timer.endDate ?? Date()
            return L10n.tr("Ends %@", end.formatted(.dateTime.hour().minute().locale(L10n.locale)))
        case .paused: return L10n.tr("Paused")
        case .finished: return L10n.tr("Done")
        case .idle: return L10n.tr("%lld min", Int((timer.duration / 60).rounded()))
        }
    }

    static func toggleTitle(_ phase: TimerState.Phase) -> String {
        switch phase {
        case .running: L10n.tr("Pause")
        case .paused: L10n.tr("Resume")
        case .idle: L10n.tr("Start")
        case .finished: L10n.tr("Restart")
        }
    }
}

struct TimerDetails: View {
    @Environment(AppModel.self) private var model
    let tile: DockTile
    @ViewState private var customMinutes: Int?

    var body: some View {
        let service = model.timeWidgets
        let timer = service.timer(for: tile)
        let options = tile.timerOptions
        let custom = customMinutes ?? max(1, Int((timer.duration / 60).rounded()))
        VStack(alignment: .leading, spacing: 10) {
            TimeTicker(anchor: timer.endDate) { now in
                let phase = timer.phase(at: now)
                HStack(spacing: 16) {
                    ZStack {
                        RingGauge(value: phase == .idle || phase == .finished ? 1 : timer.fractionRemaining(at: now), color: model.accent, lineWidth: 6)
                        Text(verbatim: TimeText.clock(timer.remaining(at: now)))
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .padding(.horizontal, 9)
                    }
                    .frame(width: 84, height: 84)
                    VStack(alignment: .leading, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(TimerLook.caption(timer, phase: phase))
                                .font(.system(size: 13, weight: .semibold))
                                .monospacedDigit()
                            Text(L10n.tr("%lld min timer", Int((timer.duration / 60).rounded())))
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 6) {
                            Button(TimerLook.toggleTitle(phase)) { service.toggleTimer(tile) }
                                .buttonStyle(GlassPillButtonStyle(tint: model.accent, prominent: true))
                            Button(L10n.tr("Reset (clock)")) { service.resetTimer(tile) }
                                .buttonStyle(GlassPillButtonStyle(tint: model.accent))
                                .disabled(phase == .idle)
                        }
                    }
                }
            }
            BentoCard(title: L10n.tr("Quick start"), symbol: "bolt.fill") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 58), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(options.durations, id: \.self) { minutes in
                        Button(L10n.tr("%lld min", minutes)) { service.startTimer(tile, minutes: minutes) }
                            .buttonStyle(GlassPillButtonStyle(tint: model.accent))
                    }
                }
            }
            BentoCard(title: L10n.tr("Custom length"), symbol: "slider.horizontal.3") {
                HStack(spacing: 8) {
                    Stepper {
                        Text(L10n.tr("%lld min", custom))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    } onIncrement: {
                        customMinutes = min(TimerOptions.minuteRange.upperBound, custom + (custom < 10 ? 1 : 5))
                    } onDecrement: {
                        customMinutes = max(TimerOptions.minuteRange.lowerBound, custom - (custom <= 10 ? 1 : 5))
                    }
                    Spacer(minLength: 6)
                    Button(L10n.tr("Start")) { service.startTimer(tile, minutes: custom) }
                        .buttonStyle(GlassPillButtonStyle(tint: model.accent, prominent: true))
                }
            }
        }
    }
}

// MARK: - Pomodoro

/// Today's finished focus stretches as dots, a gap after each cycle.
private struct SessionDots: View {
    let count: Int
    let perCycle: Int
    let color: Color
    var size: CGFloat = 4.5
    var limit = 8

    var body: some View {
        if count > limit {
            HStack(spacing: 2) {
                Circle().fill(color).frame(width: size, height: size)
                Text(verbatim: "×\(count)")
                    .font(.system(size: size + 3.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: size * 0.5) {
                ForEach(0..<count, id: \.self) { index in
                    Circle()
                        .fill(color)
                        .frame(width: size, height: size)
                        .padding(.leading, index > 0 && index % max(1, perCycle) == 0 ? size * 0.6 : 0)
                }
            }
        }
    }
}

struct PomodoroTile: View {
    @Environment(AppModel.self) private var model
    let tile: DockTile
    let isWide: Bool

    var body: some View {
        let service = model.timeWidgets
        let pomodoro = service.pomodoro(for: tile)
        let options = tile.pomodoroOptions
        let color = pomodoro.stretch.color
        TimeTicker(anchor: pomodoro.endDate(options: options)) { now in
            let remaining = pomodoro.remaining(options: options, at: now)
            let isRunning = pomodoro.clock.isRunning
            if isWide {
                HStack(spacing: 5) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 3) {
                            Image(systemName: pomodoro.stretch.symbol)
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(color)
                            Text(pomodoro.stretch.title.uppercased())
                                .font(.system(size: 7.5, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                        Text(verbatim: TimeText.clock(remaining))
                            .font(.system(size: 13.5, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(isRunning ? .primary : .secondary)
                        SessionDots(count: pomodoro.completedToday(at: now), perCycle: options.stretchesPerCycle, color: PomodoroStretch.focus.color, size: 4)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                    TileControlButton(symbol: isRunning ? "pause.fill" : "play.fill", help: isRunning ? L10n.tr("Pause") : L10n.tr("Start")) {
                        service.togglePomodoro(tile)
                    }
                }
            } else {
                CountdownRing(
                    fraction: pomodoro.fractionRemaining(options: options, at: now), color: color,
                    text: TimeText.compact(remaining), dimmed: !isRunning
                )
                .padding(2)
            }
        }
    }
}

struct PomodoroDetails: View {
    @Environment(AppModel.self) private var model
    let tile: DockTile

    var body: some View {
        let service = model.timeWidgets
        let pomodoro = service.pomodoro(for: tile)
        let options = tile.pomodoroOptions
        let color = pomodoro.stretch.color
        VStack(alignment: .leading, spacing: 10) {
            TimeTicker(anchor: pomodoro.endDate(options: options)) { now in
                let isRunning = pomodoro.clock.isRunning
                HStack(spacing: 16) {
                    ZStack {
                        RingGauge(value: pomodoro.fractionRemaining(options: options, at: now), color: color, lineWidth: 6)
                        Text(verbatim: TimeText.clock(pomodoro.remaining(options: options, at: now)))
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .padding(.horizontal, 9)
                    }
                    .frame(width: 84, height: 84)
                    VStack(alignment: .leading, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(pomodoro.stretch.title, systemImage: pomodoro.stretch.symbol)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(color)
                            Text(isRunning
                                 ? L10n.tr("Next: %@", pomodoro.nextStretch(options: options).title)
                                 : (pomodoro.clock.accumulated > 0 ? L10n.tr("Paused") : L10n.tr("Ready when you are")))
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 6) {
                            Button(isRunning ? L10n.tr("Pause") : (pomodoro.clock.accumulated > 0 ? L10n.tr("Resume") : L10n.tr("Start"))) {
                                service.togglePomodoro(tile)
                            }
                            .buttonStyle(GlassPillButtonStyle(tint: color, prominent: true))
                            Button(L10n.tr("Skip")) { service.skipPomodoro(tile) }
                                .buttonStyle(GlassPillButtonStyle(tint: color))
                                .help(L10n.tr("Go to the next stretch without counting this one"))
                            Button(L10n.tr("Reset (clock)")) { service.resetPomodoro(tile) }
                                .buttonStyle(GlassPillButtonStyle(tint: color))
                                .help(L10n.tr("Start the cycle over from the first focus stretch"))
                        }
                    }
                }
            }
            TimelineView(.everyMinute) { context in
                let today = pomodoro.completedToday(at: context.date)
                BentoCard(title: L10n.tr("Today"), symbol: "checkmark.circle") {
                    VStack(alignment: .leading, spacing: 7) {
                        if today > 0 {
                            SessionDots(count: today, perCycle: options.stretchesPerCycle, color: PomodoroStretch.focus.color, size: 8, limit: 24)
                        }
                        StatLine(label: L10n.tr("Focus stretches done"), value: "\(today)")
                        StatLine(label: L10n.tr("This cycle"), value: "\(min(pomodoro.cycleCount, options.stretchesPerCycle))/\(options.stretchesPerCycle)")
                        StatLine(label: L10n.tr("Focus · short · long break"), value: L10n.tr("%lld · %lld · %lld min", options.focusMinutes, options.shortBreakMinutes, options.longBreakMinutes))
                    }
                }
            }
        }
    }
}

// MARK: - Countdown

enum CountdownLook {
    static var calendar: Calendar {
        var calendar = Calendar.current
        calendar.locale = L10n.locale
        return calendar
    }

    /// "12d 5h left", "3d 4h ago" or "Done".
    static func summary(_ reading: CountdownReading) -> String {
        if reading.isPast {
            return reading.isZero ? L10n.tr("Done") : L10n.tr("%@ ago", reading.text(locale: L10n.locale, calendar: calendar))
        }
        return L10n.tr("%@ left", reading.text(locale: L10n.locale, calendar: calendar))
    }
}

struct CountdownTile: View {
    @Environment(AppModel.self) private var model
    let tile: DockTile
    let isWide: Bool

    var body: some View {
        let options = tile.countdownOptions
        if let target = options.target {
            TimelineView(.everyMinute) { context in
                let reading = CountdownReading.at(context.date, target: target, countsUp: options.countsUp, calendar: CountdownLook.calendar)
                if isWide {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tile.title.uppercased())
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                        Text(CountdownLook.summary(reading))
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if reading.isPast, reading.isZero {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(model.accent)
                } else {
                    VStack(spacing: 1) {
                        Text(reading.isPast ? L10n.tr("Since") : L10n.tr("Left"))
                            .textCase(.uppercase)
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(model.accent)
                        Text(verbatim: reading.shortText(locale: L10n.locale, calendar: CountdownLook.calendar))
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .monospacedDigit()
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                }
            }
        } else {
            HStack(spacing: 5) {
                Image(systemName: TileKind.countdown.symbol).font(.system(size: 12))
                if isWide { Text("No date").font(.system(size: 9.5, weight: .medium)).lineLimit(1) }
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: isWide ? .leading : .center)
        }
    }
}

struct CountdownDetails: View {
    @Environment(AppModel.self) private var model
    let tile: DockTile

    var body: some View {
        let options = tile.countdownOptions
        if let target = options.target {
            TimelineView(.everyMinute) { context in
                let reading = CountdownReading.at(context.date, target: target, countsUp: options.countsUp, calendar: CountdownLook.calendar)
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(reading.isPast ? L10n.tr("Since") : L10n.tr("Until"))
                            .textCase(.uppercase)
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(.secondary)
                        Text(target.formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute().locale(L10n.locale)))
                            .font(.system(size: 12, weight: .medium))
                    }
                    if reading.isPast, reading.isZero {
                        Text("This date has passed.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 8) {
                            unit(reading.days, L10n.tr("Days"))
                            unit(reading.hours, L10n.tr("Hours"))
                            unit(reading.minutes, L10n.tr("Minutes"))
                        }
                    }
                }
            }
        } else {
            Text("Pick a date for this countdown in Settings › Widgets.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func unit(_ value: Int, _ title: String) -> some View {
        VStack(spacing: 2) {
            Text(verbatim: "\(value)")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(model.accent)
            Text(title)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06)))
    }
}

// MARK: - Stopwatch

struct StopwatchTile: View {
    @Environment(AppModel.self) private var model
    let tile: DockTile
    let isWide: Bool

    var body: some View {
        let service = model.timeWidgets
        let stopwatch = service.stopwatch(for: tile)
        let isRunning = stopwatch.clock.isRunning
        TimeTicker(anchor: stopwatch.clock.startedAt.map { $0.addingTimeInterval(-stopwatch.clock.accumulated) }) { now in
            let elapsed = stopwatch.elapsed(at: now)
            if isWide {
                HStack(spacing: 5) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: TimeText.clock(elapsed, roundingUp: false))
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(isRunning || elapsed == 0 ? .primary : .secondary)
                        Text(StopwatchLook.caption(stopwatch, isRunning: isRunning, now: now))
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                    TileControlButton(symbol: isRunning ? "pause.fill" : "play.fill", help: isRunning ? L10n.tr("Pause") : L10n.tr("Start")) {
                        service.toggleStopwatch(tile)
                    }
                }
            } else {
                VStack(spacing: 2) {
                    Image(systemName: TileKind.stopwatch.symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isRunning ? model.accent : .secondary)
                    Text(verbatim: TimeText.compact(elapsed, roundingUp: false))
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
        }
    }
}

enum StopwatchLook {
    /// "Lap 3 · 0:42", "Paused" or "Ready".
    static func caption(_ stopwatch: StopwatchState, isRunning: Bool, now: Date) -> String {
        if isRunning, !stopwatch.laps.isEmpty {
            return L10n.tr("Lap %lld · %@", stopwatch.laps.count + 1, TimeText.clock(stopwatch.currentLap(at: now), roundingUp: false))
        }
        if isRunning { return L10n.tr("Running") }
        return stopwatch.elapsed(at: now) > 0 ? L10n.tr("Paused") : L10n.tr("Ready")
    }
}

struct StopwatchDetails: View {
    @Environment(AppModel.self) private var model
    let tile: DockTile

    var body: some View {
        let service = model.timeWidgets
        let stopwatch = service.stopwatch(for: tile)
        let isRunning = stopwatch.clock.isRunning
        VStack(alignment: .leading, spacing: 10) {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isRunning)) { context in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: TimeText.stopwatch(stopwatch.elapsed(at: context.date)))
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    if !stopwatch.laps.isEmpty {
                        Text(L10n.tr("Lap %lld · %@", stopwatch.laps.count + 1, TimeText.stopwatch(stopwatch.currentLap(at: context.date))))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            HStack(spacing: 6) {
                Button(isRunning ? L10n.tr("Pause") : (stopwatch.clock.accumulated > 0 ? L10n.tr("Resume") : L10n.tr("Start"))) {
                    service.toggleStopwatch(tile)
                }
                .buttonStyle(GlassPillButtonStyle(tint: model.accent, prominent: true))
                Button(L10n.tr("Lap")) { service.lapStopwatch(tile) }
                    .buttonStyle(GlassPillButtonStyle(tint: model.accent))
                    .disabled(!isRunning || stopwatch.laps.count >= StopwatchState.maxLaps)
                Button(L10n.tr("Reset (clock)")) { service.resetStopwatch(tile) }
                    .buttonStyle(GlassPillButtonStyle(tint: model.accent))
                    .disabled(isRunning || (stopwatch.clock.accumulated == 0 && stopwatch.laps.isEmpty))
            }
            BentoCard(title: L10n.tr("Laps"), symbol: "flag.fill") {
                if stopwatch.laps.isEmpty {
                    Text("Laps you take show up here.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    LapList(stopwatch: stopwatch)
                }
            }
        }
    }
}

private struct LapList: View {
    let stopwatch: StopwatchState
    private static let rowHeight: CGFloat = 19
    private static let visibleRows = 8

    var body: some View {
        let durations = stopwatch.lapDurations
        // The fastest and slowest stand out once there are three to compare.
        let fastest = durations.count >= 3 ? durations.min() : nil
        let slowest = durations.count >= 3 ? durations.max() : nil
        if durations.count > Self.visibleRows {
            ScrollView { rows(durations, fastest: fastest, slowest: slowest) }
                // A scroll view has no height of its own in the measured popover.
                .frame(height: CGFloat(Self.visibleRows) * Self.rowHeight - 5)
        } else {
            rows(durations, fastest: fastest, slowest: slowest)
        }
    }

    private func rows(_ durations: [TimeInterval], fastest: TimeInterval?, slowest: TimeInterval?) -> some View {
        VStack(spacing: 5) {
            ForEach(Array(durations.enumerated().reversed()), id: \.offset) { lap in
                let index = lap.offset, duration = lap.element
                HStack {
                    Text(L10n.tr("Lap %lld", index + 1))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(verbatim: TimeText.stopwatch(duration))
                        .fontWeight(.semibold)
                        .foregroundStyle(duration == fastest ? HealthLevel.ok.color : (duration == slowest ? HealthLevel.critical.color : .primary))
                    Text(verbatim: TimeText.stopwatch(stopwatch.laps[index]))
                        .foregroundStyle(.tertiary)
                        .frame(width: 74, alignment: .trailing)
                }
                .font(.system(size: 11, design: .rounded))
                .monospacedDigit()
                .frame(height: Self.rowHeight - 5)
            }
        }
    }
}

// MARK: - Time progress

enum TimeProgressLook {
    static var calendar: Calendar {
        var calendar = Calendar.current
        calendar.locale = L10n.locale
        return calendar
    }

    /// The span holding `date`: "Wednesday", "Week 43", "October", "2026".
    static func name(of period: TimePeriod, at date: Date) -> String {
        let locale = L10n.locale
        switch period {
        case .day: return date.formatted(.dateTime.weekday(.wide).locale(locale))
        case .week: return L10n.tr("Week %lld", calendar.component(.weekOfYear, from: date))
        case .month: return date.formatted(.dateTime.month(.wide).locale(locale))
        case .year: return date.formatted(.dateTime.year().locale(locale))
        }
    }

    /// The details' second name, beside the period's: a week's days, "19 – 25 Oct".
    static func detail(of period: TimePeriod, at date: Date) -> String {
        guard period == .week, let week = calendar.dateInterval(of: .weekOfYear, for: date) else { return name(of: period, at: date) }
        let style = Date.FormatStyle.dateTime.day().month(.abbreviated).locale(L10n.locale)
        return "\(week.start.formatted(style)) – \(week.end.addingTimeInterval(-1).formatted(style))"
    }

    /// "73%".
    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)).locale(L10n.locale))
    }

    /// "6h 12m left".
    static func left(until end: Date, now: Date) -> String {
        CountdownLook.summary(CountdownReading.at(now, target: end, countsUp: false, calendar: calendar))
    }
}

struct TimeProgressTile: View {
    @Environment(AppModel.self) private var model
    let tile: DockTile
    let isWide: Bool

    var body: some View {
        let period = tile.timePeriod
        TimelineView(.everyMinute) { context in
            let progress = TimeProgress.of(period, at: context.date, calendar: TimeProgressLook.calendar)
            let fraction = progress?.fraction ?? 0
            if isWide {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(TimeProgressLook.name(of: period, at: context.date).uppercased())
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 2)
                        Text(verbatim: TimeProgressLook.percent(fraction))
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                            .monospacedDigit()
                    }
                    UsageBar(fraction: fraction, color: model.accent)
                    if let progress {
                        Text(TimeProgressLook.left(until: progress.interval.end, now: context.date))
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            } else {
                VStack(spacing: 3) {
                    Text(period.title)
                        .textCase(.uppercase)
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text(verbatim: TimeProgressLook.percent(fraction))
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    UsageBar(fraction: fraction, color: model.accent)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            }
        }
    }
}

struct TimeProgressDetails: View {
    @Environment(AppModel.self) private var model
    let tile: DockTile

    var body: some View {
        TimelineView(.everyMinute) { context in
            BentoCard(title: L10n.tr("Time passed"), symbol: TileKind.timeProgress.symbol) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(TimePeriod.allCases) { period in
                        row(period, now: context.date, isSelected: period == tile.timePeriod)
                    }
                }
            }
        }
    }

    private func row(_ period: TimePeriod, now: Date, isSelected: Bool) -> some View {
        let progress = TimeProgress.of(period, at: now, calendar: TimeProgressLook.calendar)
        let fraction = progress?.fraction ?? 0
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(period.title)
                    .font(.system(size: 11.5, weight: isSelected ? .bold : .medium))
                Text(TimeProgressLook.detail(of: period, at: now))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(verbatim: TimeProgressLook.percent(fraction))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            UsageBar(fraction: fraction, color: isSelected ? model.accent : Color.secondary)
            if let progress {
                Text(TimeProgressLook.left(until: progress.interval.end, now: now))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}

// MARK: - Clock: analog face and world clock

/// A watch face drawn with Canvas: twelve ticks, hour and minute hands, and a
/// second hand when asked.
struct AnalogClockFace: View {
    let date: Date
    var zone: TimeZone = .autoupdatingCurrent
    var showsSeconds = false
    var accent: Color = .red

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let radius = side / 2
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let dial = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: side, height: side))
            context.fill(dial, with: .color(Color.primary.opacity(0.08)))
            context.stroke(dial, with: .color(Color.primary.opacity(0.18)), lineWidth: max(0.5, side * 0.02))

            func point(_ angle: Double, _ length: CGFloat) -> CGPoint {
                CGPoint(x: center.x + CGFloat(sin(angle)) * length, y: center.y - CGFloat(cos(angle)) * length)
            }
            func line(_ angle: Double, from start: CGFloat, to end: CGFloat) -> Path {
                var path = Path()
                path.move(to: point(angle, start))
                path.addLine(to: point(angle, end))
                return path
            }
            for hour in 0..<12 {
                let isQuarter = hour % 3 == 0
                let angle = Double(hour) / 12 * 2 * .pi
                context.stroke(
                    line(angle, from: radius * (isQuarter ? 0.70 : 0.78), to: radius * 0.88),
                    with: .color(Color.primary.opacity(isQuarter ? 0.85 : 0.45)),
                    style: StrokeStyle(lineWidth: side * (isQuarter ? 0.045 : 0.025), lineCap: .round)
                )
            }

            let hands = Self.angles(at: date, zone: zone)
            context.stroke(line(hands.hour, from: -radius * 0.08, to: radius * 0.5), with: .color(.primary),
                           style: StrokeStyle(lineWidth: side * 0.07, lineCap: .round))
            context.stroke(line(hands.minute, from: -radius * 0.08, to: radius * 0.74), with: .color(.primary),
                           style: StrokeStyle(lineWidth: side * 0.045, lineCap: .round))
            if showsSeconds {
                context.stroke(line(hands.second, from: -radius * 0.16, to: radius * 0.82), with: .color(accent),
                               style: StrokeStyle(lineWidth: max(0.6, side * 0.02), lineCap: .round))
            }
            let hub = side * 0.09
            context.fill(Path(ellipseIn: CGRect(x: center.x - hub / 2, y: center.y - hub / 2, width: hub, height: hub)),
                         with: .color(showsSeconds ? accent : .primary))
        }
        .aspectRatio(1, contentMode: .fit)
    }

    /// Clockwise from 12, in radians.
    static func angles(at date: Date, zone: TimeZone) -> (hour: Double, minute: Double, second: Double) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        let second = Double(parts.second ?? 0)
        let minute = Double(parts.minute ?? 0) + second / 60
        let hour = Double((parts.hour ?? 0) % 12) + minute / 60
        return (hour / 12 * 2 * .pi, minute / 60 * 2 * .pi, second / 60 * 2 * .pi)
    }
}

enum WorldClockLook {
    /// "Same time as this Mac", "12h ahead of this Mac".
    static func offset(of zone: TimeZone, at date: Date) -> String {
        let seconds = TimeZoneCatalog.offset(of: zone, at: date)
        guard seconds != 0 else { return L10n.tr("Same time as this Mac") }
        var calendar = Calendar.current
        calendar.locale = L10n.locale
        let magnitude = abs(seconds)
        let text = CountdownReading.format(
            DateComponents(hour: magnitude / 3600, minute: magnitude / 60 % 60),
            units: [.hour, .minute], maximum: 2, locale: L10n.locale, calendar: calendar
        )
        return seconds > 0 ? L10n.tr("%@ ahead of this Mac", text) : L10n.tr("%@ behind this Mac", text)
    }
}

/// The Clock's details for another city: its offset and this Mac's time.
struct WorldClockSummary: View {
    let tile: DockTile
    let date: Date

    var body: some View {
        let zone = tile.timeZoneValue
        VStack(alignment: .leading, spacing: 4) {
            StatLine(label: TimeZoneCatalog.city(of: zone.identifier), value: WorldClockLook.offset(of: zone, at: date))
            StatLine(label: L10n.tr("This Mac"), value: date.formatted(.dateTime.hour().minute().locale(L10n.locale)))
        }
    }
}

// MARK: - Settings

extension Binding where Value == DockTile {
    /// A field of optional per-kind options, which start from `fallback`.
    func option<Options, Field>(_ options: WritableKeyPath<DockTile, Options?>, _ fallback: Options, _ field: WritableKeyPath<Options, Field>) -> Binding<Field> {
        Binding<Field>(
            get: { (wrappedValue[keyPath: options] ?? fallback)[keyPath: field] },
            set: { value in
                var current = wrappedValue[keyPath: options] ?? fallback
                current[keyPath: field] = value
                wrappedValue[keyPath: options] = current
            }
        )
    }
}

/// Settings › Widgets: the Clock's face and time zone.
struct ClockSettingsRows: View {
    let tile: Binding<DockTile>
    @ViewState private var isPicking = false

    var body: some View {
        let current = tile.wrappedValue
        Picker("Square face", selection: Binding(get: { current.clockFace }, set: { tile.wrappedValue.face = $0 == .digital ? nil : $0 })) {
            ForEach(ClockFace.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        LabeledContent("Time zone") {
            Button {
                isPicking = true
            } label: {
                Text(current.isWorldClock ? TimeZoneCatalog.city(of: current.timeZoneValue.identifier) : L10n.tr("This Mac"))
            }
            .popover(isPresented: $isPicking, arrowEdge: .trailing) {
                TimeZonePicker(selection: Binding(get: { tile.wrappedValue.timeZone }, set: { tile.wrappedValue.timeZone = $0 })) {
                    isPicking = false
                }
            }
        }
        Text("Pick a city to make this a world clock. The square tile can show an analog face.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// A searchable list of every time zone macOS knows, by city.
struct TimeZonePicker: View {
    @Binding var selection: String?
    let done: () -> Void
    @ViewState private var query = ""

    var body: some View {
        let results = TimeZoneCatalog.search(query, locale: L10n.locale)
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search cities or time zones", text: $query)
                .textFieldStyle(.roundedBorder)
            List {
                if query.isBlank {
                    row(title: L10n.tr("This Mac"), subtitle: TimeZone.current.identifier, zone: .current, isSelected: selection == nil) {
                        selection = nil
                    }
                }
                ForEach(results.prefix(120), id: \.self) { identifier in
                    if let zone = TimeZone(identifier: identifier) {
                        row(title: TimeZoneCatalog.city(of: identifier), subtitle: TimeZoneCatalog.region(of: identifier), zone: zone, isSelected: selection == identifier) {
                            selection = identifier
                        }
                    }
                }
                if results.isEmpty {
                    Text("No matching time zone").foregroundStyle(.secondary)
                }
            }
            .listStyle(.plain)
        }
        .padding(10)
        .frame(width: 320, height: 380)
    }

    private func row(title: String, subtitle: String, zone: TimeZone, isSelected: Bool, choose: @escaping () -> Void) -> some View {
        Button {
            choose()
            done()
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).fontWeight(isSelected ? .semibold : .regular)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(Date().formatted(.dateTime.hour().minute().locale(L10n.locale).inZone(zone)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if isSelected { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct TimerSettingsRows: View {
    let tile: Binding<DockTile>
    @ViewState private var text: String?

    var body: some View {
        let options = tile.wrappedValue.timerOptions
        TextField("Quick durations", text: Binding(
            get: { text ?? options.durations.map(String.init).joined(separator: ", ") },
            set: { value in
                text = value
                if let durations = TimerOptions.parseDurations(value) {
                    tile.wrappedValue.timer = TimerOptions(durations: durations, playsSound: options.playsSound)
                }
            }
        ), prompt: Text(verbatim: "5, 10, 15, 25, 45"))
        Toggle("Play a sound", isOn: tile.option(\.timer, TimerOptions(), \.playsSound))
        Text("Minutes, separated by commas. Its details also start any length from 1 to 600 minutes. A running timer keeps going while Kosmodock is closed; when it ends, you get a notification.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

struct PomodoroSettingsRows: View {
    let tile: Binding<DockTile>

    var body: some View {
        let options = tile.wrappedValue.pomodoroOptions
        let fallback = PomodoroOptions()
        Stepper(value: tile.option(\.pomodoro, fallback, \.focusMinutes), in: PomodoroOptions.minuteRange) {
            Text(L10n.tr("Focus: %lld min", options.focusMinutes))
        }
        Stepper(value: tile.option(\.pomodoro, fallback, \.shortBreakMinutes), in: PomodoroOptions.minuteRange) {
            Text(L10n.tr("Short break: %lld min", options.shortBreakMinutes))
        }
        Stepper(value: tile.option(\.pomodoro, fallback, \.longBreakMinutes), in: PomodoroOptions.minuteRange) {
            Text(L10n.tr("Long break: %lld min", options.longBreakMinutes))
        }
        Stepper(value: tile.option(\.pomodoro, fallback, \.longBreakAfter), in: PomodoroOptions.longBreakRange) {
            Text(L10n.tr("Long break after %lld focus stretches", options.stretchesPerCycle))
        }
        Toggle("Start breaks automatically", isOn: tile.option(\.pomodoro, fallback, \.autoStartBreaks))
        Toggle("Play a sound", isOn: tile.option(\.pomodoro, fallback, \.playsSound))
        Text("The next focus stretch always waits for you to start it. You get a notification when a stretch ends; today's finished focus stretches show as dots.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

struct CountdownSettingsRows: View {
    let tile: Binding<DockTile>

    var body: some View {
        TextField("Name", text: Binding(
            get: { tile.wrappedValue.label ?? "" },
            set: { tile.wrappedValue.label = $0.isEmpty ? nil : $0 }
        ))
        DatePicker(selection: Binding(
            get: { tile.wrappedValue.countdownOptions.target ?? CountdownOptions.defaultTarget(after: Date()) ?? Date() },
            set: { date in
                var options = tile.wrappedValue.countdownOptions
                options.target = date
                tile.wrappedValue.countdown = options
            }
        ), displayedComponents: [.date, .hourAndMinute]) {
            Text("Date and time")
        }
        Toggle("Keep counting after it passes", isOn: tile.option(\.countdown, CountdownOptions(), \.countsUp))
        Text("The tile shows the days and hours left. Once the date passes, it shows the time since, or Done.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

struct TimeProgressSettingsRows: View {
    let tile: Binding<DockTile>

    var body: some View {
        Picker("Period", selection: Binding(get: { tile.wrappedValue.timePeriod }, set: { tile.wrappedValue.period = $0 })) {
            ForEach(TimePeriod.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        Text("How much of the day, week, month or year has passed. Weeks start on the first weekday of the interface language.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

struct StopwatchSettingsRows: View {
    var body: some View {
        Text("Start, pause, take laps and reset in its details. It keeps running while Kosmodock is closed.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
