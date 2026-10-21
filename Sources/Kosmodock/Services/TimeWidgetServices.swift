import AppKit
import Observation
import OSLog
import UserNotifications

// Runs the time widgets: Timer, Pomodoro and Stopwatch keep their clocks in
// time-widgets.json next to config.json, as dates, so they keep going while
// Kosmodock is quit. The file is written on clicks and when a stretch ends,
// never every second. The math is in Models/TimeWidgets.swift.

/// A timer that reached zero or a pomodoro stretch that ended.
struct TimeAlert: Equatable, Sendable {
    var tileID: String
    var title: String
    var body: String
    var playsSound: Bool
}

@MainActor
@Observable
final class TimeWidgetService {
    private(set) var state = TimeWidgetState()

    let fileURL: URL
    /// Opens a tile's details, when its notification is clicked.
    @ObservationIgnored var onOpenTile: ((String) -> Void)?

    @ObservationIgnored private var tiles: [String: DockTile] = [:]
    @ObservationIgnored private var hasTiles = false
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var deliver: (TimeAlert) -> Void = { _ in }
    @ObservationIgnored private var notifier: TimeNotifier?

    /// An end found later than this (Kosmodock was quit, the Mac slept) only
    /// updates the tile: a sound minutes late helps nobody.
    static let lateAlertLimit: TimeInterval = 60
    /// Longest wait between checks, so a sleep or a clock change is noticed.
    static let maxWait: TimeInterval = 10

    /// `alert` replaces the notification and sound, for tests.
    init(directory: URL, alert: ((TimeAlert) -> Void)? = nil) {
        fileURL = directory.appendingPathComponent("time-widgets.json")
        if let alert {
            deliver = alert
        } else {
            let notifier = TimeNotifier()
            notifier.onOpen = { [weak self] id in self?.onOpenTile?(id) }
            self.notifier = notifier
            deliver = { notifier.deliver($0) }
        }
        load()
    }

    // MARK: Tiles

    /// The bar's tiles changed: their options apply from now on, and removed
    /// tiles lose their state. Until the first tiles arrive nothing is
    /// dropped, because a config that failed to load has none.
    func setTiles(_ tiles: [DockTile], now: Date = Date()) {
        self.tiles = Dictionary(tiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if hasTiles || !tiles.isEmpty {
            hasTiles = true
            let kept = state.keeping(tiles)
            if kept != state {
                state = kept
                save(now: now)
            }
        }
        tick(now: now)
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    // MARK: Timer

    func timer(for tile: DockTile) -> TimerState {
        state.timers[tile.id] ?? TimerState(duration: TimeInterval((tile.timerOptions.durations.first ?? 5) * 60))
    }

    func startTimer(_ tile: DockTile, minutes: Int, now: Date = Date()) {
        var timer = timer(for: tile)
        timer.start(duration: TimeInterval(min(max(minutes, TimerOptions.minuteRange.lowerBound), TimerOptions.minuteRange.upperBound) * 60), at: now)
        change(now: now) { $0.timers[tile.id] = timer }
    }

    func toggleTimer(_ tile: DockTile, now: Date = Date()) {
        var timer = timer(for: tile)
        timer.toggle(at: now)
        change(now: now) { $0.timers[tile.id] = timer }
    }

    func resetTimer(_ tile: DockTile, now: Date = Date()) {
        var timer = timer(for: tile)
        timer.reset()
        change(now: now) { $0.timers[tile.id] = timer }
    }

    // MARK: Pomodoro

    func pomodoro(for tile: DockTile) -> PomodoroState {
        state.pomodoros[tile.id] ?? PomodoroState()
    }

    func togglePomodoro(_ tile: DockTile, now: Date = Date()) {
        var pomodoro = pomodoro(for: tile)
        pomodoro.toggle(at: now)
        change(now: now) { $0.pomodoros[tile.id] = pomodoro }
    }

    func skipPomodoro(_ tile: DockTile, now: Date = Date()) {
        var pomodoro = pomodoro(for: tile)
        pomodoro.skip(options: tile.pomodoroOptions)
        change(now: now) { $0.pomodoros[tile.id] = pomodoro }
    }

    func resetPomodoro(_ tile: DockTile, now: Date = Date()) {
        var pomodoro = pomodoro(for: tile)
        pomodoro.reset()
        change(now: now) { $0.pomodoros[tile.id] = pomodoro }
    }

    // MARK: Stopwatch

    func stopwatch(for tile: DockTile) -> StopwatchState {
        state.stopwatches[tile.id] ?? StopwatchState()
    }

    func toggleStopwatch(_ tile: DockTile, now: Date = Date()) {
        var stopwatch = stopwatch(for: tile)
        stopwatch.toggle(at: now)
        change(now: now) { $0.stopwatches[tile.id] = stopwatch }
    }

    func lapStopwatch(_ tile: DockTile, now: Date = Date()) {
        var stopwatch = stopwatch(for: tile)
        guard stopwatch.clock.isRunning, stopwatch.laps.count < StopwatchState.maxLaps else { return }
        stopwatch.lap(at: now)
        change(now: now) { $0.stopwatches[tile.id] = stopwatch }
    }

    func resetStopwatch(_ tile: DockTile, now: Date = Date()) {
        change(now: now) { $0.stopwatches[tile.id] = nil }
    }

    // MARK: Ticking

    /// Ends whatever reached zero by `now`, tells about it, saves, and waits
    /// for the next end.
    func tick(now: Date = Date()) {
        var next = state
        var alerts: [TimeAlert] = []
        for (id, timer) in state.timers {
            var timer = timer
            guard let end = timer.finishIfDue(at: now) else { continue }
            next.timers[id] = timer
            if let tile = tiles[id], now.timeIntervalSince(end) < Self.lateAlertLimit {
                alerts.append(Self.alert(timerOf: tile, duration: timer.duration))
            }
        }
        for (id, pomodoro) in state.pomodoros {
            guard let tile = tiles[id] else { continue }
            var pomodoro = pomodoro
            let ends = pomodoro.advance(to: now, options: tile.pomodoroOptions)
            guard let last = ends.last else { continue }
            next.pomodoros[id] = pomodoro
            if now.timeIntervalSince(last.at) < Self.lateAlertLimit {
                alerts.append(Self.alert(pomodoroOf: tile, end: last))
            }
        }
        if next != state {
            state = next
            save(now: now)
        }
        alerts.forEach(deliver)
        schedule(now: now)
    }

    private func schedule(now: Date) {
        loop?.cancel()
        loop = nil
        let timerEnds = state.timers.values.compactMap(\.endDate)
        let pomodoroEnds = state.pomodoros.compactMap { id, pomodoro in
            tiles[id].flatMap { pomodoro.endDate(options: $0.pomodoroOptions) }
        }
        guard let soonest = (timerEnds + pomodoroEnds).min() else { return }
        let delay = min(Self.maxWait, max(0.05, soonest.timeIntervalSince(now)))
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.tick()
        }
    }

    private func change(now: Date, _ mutate: (inout TimeWidgetState) -> Void) {
        var next = state
        mutate(&next)
        guard next != state else { return }
        state = next
        save(now: now)
        schedule(now: now)
    }

    // MARK: Alerts

    static func alert(timerOf tile: DockTile, duration: TimeInterval) -> TimeAlert {
        TimeAlert(
            tileID: tile.id,
            title: L10n.tr("Time's up"),
            body: L10n.tr("Your %@ timer is done.", L10n.tr("%lld min", Int((duration / 60).rounded()))),
            playsSound: tile.timerOptions.playsSound
        )
    }

    static func alert(pomodoroOf tile: DockTile, end: PomodoroState.End) -> TimeAlert {
        let options = tile.pomodoroOptions
        let title: String
        let body: String
        switch (end.stretch, end.next) {
        case (.focus, .longBreak):
            title = L10n.tr("Focus stretch done")
            body = options.autoStartBreaks ? L10n.tr("Your long break has started.") : L10n.tr("Time for a long break.")
        case (.focus, _):
            title = L10n.tr("Focus stretch done")
            body = options.autoStartBreaks ? L10n.tr("Your short break has started.") : L10n.tr("Time for a short break.")
        default:
            title = L10n.tr("Break's over")
            body = L10n.tr("Start the next focus stretch when you're ready.")
        }
        return TimeAlert(tileID: tile.id, title: title, body: body, playsSound: options.playsSound)
    }

    // MARK: File

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            state = try TimeWidgetState.decoded(from: data)
        } catch {
            Logger.timeWidgets.error("Could not read time-widgets.json: \(String(describing: error), privacy: .public)")
        }
    }

    private func save(now: Date = Date()) {
        var saved = state
        for id in saved.pomodoros.keys { saved.pomodoros[id]?.pruneCompletions(before: now) }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try TimeWidgetState.encoded(saved).write(to: fileURL, options: .atomic)
        } catch {
            Logger.timeWidgets.error("Could not save time-widgets.json: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension Logger {
    static let timeWidgets = Logger(subsystem: "dev.kosmodock.Kosmodock", category: "time-widgets")
}

// MARK: - Notifications

/// A notification and a sound when a timer or a stretch ends. Permission is
/// asked the first time one ends, not before. The sound plays even without
/// it, so a denied permission still rings.
@MainActor
final class TimeNotifier: NSObject {
    var onOpen: ((String) -> Void)?

    /// UNUserNotificationCenter needs an app bundle: in a bare debug binary
    /// `current()` raises an exception instead of returning.
    static var canNotify: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    func deliver(_ alert: TimeAlert) {
        if alert.playsSound { NSSound(named: "Glass")?.play() }
        guard Self.canNotify else { return }
        let center = UNUserNotificationCenter.current()
        if center.delegate == nil { center.delegate = self }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.userInfo = ["tileID": alert.tileID]
        // One per tile: a newer end replaces the older notification.
        let request = UNNotificationRequest(identifier: "dev.kosmodock.time.\(alert.tileID)", content: content, trigger: nil)
        Task {
            switch await center.notificationSettings().authorizationStatus {
            case .notDetermined:
                guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            case .denied:
                return
            default:
                break
            }
            do {
                try await center.add(request)
            } catch {
                Logger.timeWidgets.error("Notification failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

extension TimeNotifier: UNUserNotificationCenterDelegate {
    /// Kosmodock is often the active app (Settings, popovers): show it anyway.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let tileID = response.notification.request.content.userInfo["tileID"] as? String
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let tileID { self.onOpen?(tileID) }
            }
        }
        completionHandler()
    }
}

// MARK: - AppModel

extension AppModel {
    /// Opens a time widget's details (its notification was clicked), unless
    /// they're open already or the tile isn't on the bar.
    func showTimeWidget(id: String) {
        guard let tile = tile(id: id) else { return }
        let itemID = DockConfig.itemID(for: tile)
        guard popoverItemID != itemID, config.barOrder.contains(itemID) else { return }
        tap(tile)
    }
}
