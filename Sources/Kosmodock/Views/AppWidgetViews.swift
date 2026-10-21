import AppKit
import SwiftUI

// Tiles and details for the app widgets: Claude Code, Now Playing, Calendar
// and GitHub. Their data comes from the services in AppWidgetServices.swift.

// MARK: - Claude Code

struct ClaudeTile: View {
    @Environment(AppModel.self) private var model
    let isWide: Bool

    var body: some View {
        let usage = model.claude.usage
        if isWide {
            if usage.fiveHourLimit != nil || usage.weeklyLimit != nil {
                VStack(alignment: .leading, spacing: 5) {
                    LimitMeter(label: L10n.tr("5h"), limit: usage.fiveHourLimit)
                    LimitMeter(label: L10n.tr("Week"), limit: usage.weeklyLimit)
                }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: "CLAUDE CODE")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text(L10n.tr("%@ tokens · 5h", Format.count(usage.lastFiveHours.total)))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(spacing: 2) {
                Image(systemName: "sparkle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.orange)
                Text(verbatim: usage.fiveHourLimit.map { "\(Int($0.usedPercent.rounded()))%" } ?? Format.count(usage.lastFiveHours.total))
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }
}

/// A plan window as a bar, with "—" once it has reset or before any data.
private struct LimitMeter: View {
    let label: String
    let limit: ClaudeLimit?

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .leading)
            UsageBar(fraction: (limit?.usedPercent ?? 0) / 100, color: LimitMeter.color(for: limit?.usedPercent ?? 0))
            Text(verbatim: limit.map { "\(Int($0.usedPercent.rounded()))%" } ?? "—")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(width: 28, alignment: .trailing)
        }
    }

    static func color(for percent: Double) -> Color {
        switch percent {
        case ..<70: .orange
        case ..<90: HealthLevel.warning.color
        default: HealthLevel.critical.color
        }
    }
}

struct ClaudeDetails: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let service = model.claude
        let usage = service.usage
        VStack(alignment: .leading, spacing: 10) {
            BentoCard(title: L10n.tr("Plan limits"), symbol: "gauge.with.dots.needle.33percent") {
                VStack(alignment: .leading, spacing: 8) {
                    switch service.statusLine {
                    case .kosmodock:
                        if usage.fiveHourLimit == nil, usage.weeklyLimit == nil {
                            Text("Limits show up after your next reply in Claude Code.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        } else {
                            limitRow(L10n.tr("Current session (5h)"), usage.fiveHourLimit)
                            limitRow(L10n.tr("Week"), usage.weeklyLimit)
                            if let updated = usage.limitsUpdatedAt {
                                Text(L10n.tr("Updated %@", updated.formatted(.relative(presentation: .named).locale(L10n.locale))))
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Button("Remove from Claude Code") { service.removeStatusLine() }
                            .buttonStyle(.link)
                            .font(.system(size: 10.5))
                    case .notSet:
                        Text("Claude Code shares your plan's 5-hour and weekly limits only with its status line. Set up adds a small one that saves them for this widget and shows them in Claude Code.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Set Up") { service.installStatusLine() }
                            .buttonStyle(GlassPillButtonStyle(tint: .orange, prominent: true))
                    case .other(let command):
                        Text("You already have a Claude Code status line, so Kosmodock leaves it alone. To see the limits here, make it also save its input to ~/.config/kosmodock/claude-status.json.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(verbatim: command)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let error = service.lastError {
                        Text(error).font(.system(size: 10)).foregroundStyle(HealthLevel.critical.color)
                    }
                }
            }
            BentoCard(title: L10n.tr("Tokens"), symbol: "number") {
                VStack(alignment: .leading, spacing: 4) {
                    StatLine(label: L10n.tr("Last 5 hours"), value: Format.count(usage.lastFiveHours.total))
                    StatLine(label: L10n.tr("Today"), value: Format.count(usage.today.total))
                    StatLine(label: L10n.tr("Last 7 days"), value: Format.count(usage.lastSevenDays.total))
                    if let last = usage.lastActivity {
                        StatLine(label: L10n.tr("Last reply"), value: last.formatted(.relative(presentation: .named).locale(L10n.locale)))
                    }
                    if let model = usage.model {
                        StatLine(label: L10n.tr("Model"), value: model)
                    }
                }
            }
            Text("Read from Claude Code's files on this Mac. Tokens include cache reads.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private func limitRow(_ title: String, _ limit: ClaudeLimit?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.system(size: 11, weight: .medium))
                Spacer()
                Text(verbatim: limit.map { "\(Int($0.usedPercent.rounded()))%" } ?? "—")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            UsageBar(fraction: (limit?.usedPercent ?? 0) / 100, color: LimitMeter.color(for: limit?.usedPercent ?? 0))
            if let resets = limit?.resetsAt {
                Text(L10n.tr("Resets %@", resets.formatted(.relative(presentation: .named).locale(L10n.locale))))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Now Playing

struct NowPlayingTile: View {
    @Environment(AppModel.self) private var model
    let isWide: Bool

    var body: some View {
        switch model.nowPlaying.state {
        case .playing(let track):
            if isWide {
                HStack(spacing: 6) {
                    PlayerIcon(player: track.player, size: 18)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(track.title).font(.system(size: 10.5, weight: .semibold))
                        Text(track.artist).font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    Button {
                        model.nowPlaying.send(.playPause, to: track.player)
                    } label: {
                        Image(systemName: track.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(track.isPlaying ? L10n.tr("Pause") : L10n.tr("Play"))
                }
            } else {
                PlayerIcon(player: track.player, size: 22)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: track.isPlaying ? "play.fill" : "pause.fill")
                            .font(.system(size: 6.5, weight: .heavy))
                            .padding(2)
                            .background(Circle().fill(.black.opacity(0.6)))
                            .foregroundStyle(.white)
                            .offset(x: 3, y: 3)
                    }
            }
        case .idle:
            placeholder(symbol: "music.note", text: L10n.tr("Nothing playing"))
        case .denied:
            placeholder(symbol: "exclamationmark.triangle", text: L10n.tr("Allow access"))
        }
    }

    private func placeholder(symbol: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 12))
            if isWide { Text(text).font(.system(size: 9.5, weight: .medium)).lineLimit(1) }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: isWide ? .leading : .center)
    }
}

private struct PlayerIcon: View {
    let player: MediaPlayer
    let size: CGFloat

    var body: some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.bundleID)
        Image(nsImage: url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage())
            .resizable()
            .frame(width: size, height: size)
    }
}

struct NowPlayingDetails: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.nowPlaying.state {
        case .playing(let track):
            BentoCard(title: track.player.scriptName, symbol: "music.note") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        PlayerIcon(player: track.player, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title).font(.system(size: 13, weight: .semibold))
                            Text(track.artist).font(.system(size: 11)).foregroundStyle(.secondary)
                            Text(track.album).font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                        .lineLimit(1)
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let position = track.position(at: context.date)
                        VStack(spacing: 3) {
                            UsageBar(fraction: track.duration > 0 ? position / track.duration : 0, color: .pink)
                            HStack {
                                Text(verbatim: Self.time(position))
                                Spacer()
                                Text(verbatim: Self.time(track.duration))
                            }
                            .font(.system(size: 9, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 18) {
                        Spacer()
                        control("backward.fill", .previous, track, help: L10n.tr("Previous"))
                        control(track.isPlaying ? "pause.fill" : "play.fill", .playPause, track, help: track.isPlaying ? L10n.tr("Pause") : L10n.tr("Play"))
                        control("forward.fill", .next, track, help: L10n.tr("Next"))
                        Spacer()
                    }
                }
            }
        case .idle:
            Text("Nothing is playing in Music or Spotify.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        case .denied(let player):
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.tr("Kosmodock isn't allowed to control %@. Turn it on in System Settings › Privacy & Security › Automation.", player.scriptName))
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Automation Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    private func control(_ symbol: String, _ command: NowPlayingService.Command, _ track: NowPlaying, help: String) -> some View {
        IconButton(symbol: symbol, help: help, size: 30) {
            model.nowPlaying.send(command, to: track.player)
        }
    }

    /// "3:07".
    static func time(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Calendar

struct CalendarTile: View {
    @Environment(AppModel.self) private var model
    let isWide: Bool

    var body: some View {
        let service = model.calendar
        TimelineView(.everyMinute) { context in
            let next = CalendarService.next(in: service.events, at: context.date)
            if isWide {
                if service.access != .granted {
                    Label("Calendar access", systemImage: "calendar.badge.exclamationmark")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let next {
                    HStack(spacing: 6) {
                        Capsule()
                            .fill(Color(hex: next.colorHex) ?? model.accent)
                            .frame(width: 3, height: 24)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(next.title).font(.system(size: 10.5, weight: .semibold))
                            Text(CalendarDetails.when(next, now: context.date))
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                } else {
                    Text("No more events")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(spacing: 0) {
                    Text(context.date.formatted(.dateTime.weekday(.abbreviated).locale(L10n.locale)).uppercased())
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(.red)
                    Text(context.date.formatted(.dateTime.day().locale(L10n.locale)))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                }
                .overlay(alignment: .topTrailing) {
                    // An event within the hour.
                    if let next, next.start.timeIntervalSince(context.date) < 3600 {
                        Circle().fill(Color(hex: next.colorHex) ?? model.accent).frame(width: 5, height: 5).offset(x: 5, y: 1)
                    }
                }
            }
        }
    }
}

struct CalendarDetails: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let service = model.calendar
        switch service.access {
        case .granted:
            let calendar = Calendar.current
            let today = service.events.filter { calendar.isDateInToday($0.start) || ($0.start < Date() && $0.end > Date()) }
            let tomorrow = service.events.filter { calendar.isDateInTomorrow($0.start) }
            VStack(alignment: .leading, spacing: 10) {
                day(L10n.tr("Today"), today)
                day(L10n.tr("Tomorrow"), tomorrow)
                Button("Open Calendar") {
                    NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Calendar.app"), configuration: NSWorkspace.OpenConfiguration())
                }
                .buttonStyle(.link)
                .font(.system(size: 10.5))
            }
        case .unknown:
            Button("Allow Calendar Access") { Task { await service.requestAccessIfNeeded() } }
        case .denied:
            VStack(alignment: .leading, spacing: 8) {
                Text("Kosmodock can't read your calendars. Turn it on in System Settings › Privacy & Security › Calendars.")
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Calendar Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        case .unavailable:
            Text("This build can't ask for calendar access.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func day(_ title: String, _ events: [CalendarEvent]) -> some View {
        BentoCard(title: title, symbol: "calendar") {
            VStack(alignment: .leading, spacing: 6) {
                if events.isEmpty {
                    Text("No events").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                ForEach(events) { event in
                    HStack(spacing: 8) {
                        Capsule().fill(Color(hex: event.colorHex) ?? model.accent).frame(width: 3, height: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(event.title).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                            Text(event.isAllDay ? L10n.tr("All day") : Self.range(event))
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    static func range(_ event: CalendarEvent) -> String {
        let style = Date.FormatStyle.dateTime.hour().minute().locale(L10n.locale)
        return "\(event.start.formatted(style)) – \(event.end.formatted(style))"
    }

    /// "14:30 · in 20 min", "Now · until 15:00" or "All day".
    static func when(_ event: CalendarEvent, now: Date) -> String {
        if event.isAllDay { return L10n.tr("All day") }
        let time = Date.FormatStyle.dateTime.hour().minute().locale(L10n.locale)
        if event.start <= now { return L10n.tr("Now · until %@", event.end.formatted(time)) }
        let relative = RelativeDateTimeFormatter()
        relative.locale = L10n.locale
        relative.unitsStyle = .short
        return "\(event.start.formatted(time)) · \(relative.localizedString(for: event.start, relativeTo: now))"
    }
}

// MARK: - GitHub

struct GitHubTile: View {
    @Environment(AppModel.self) private var model
    let isWide: Bool

    var body: some View {
        let service = model.github
        if service.status != .ready {
            HStack(spacing: 5) {
                Image(systemName: service.status == .loading ? "arrow.triangle.pull" : "exclamationmark.triangle")
                    .font(.system(size: 12))
                if isWide {
                    Text(Self.problem(service.status))
                        .font(.system(size: 9.5, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: isWide ? .leading : .center)
        } else if isWide {
            VStack(alignment: .leading, spacing: 2) {
                line("eye", L10n.tr("%lld to review", service.reviewRequests.count), highlighted: !service.reviewRequests.isEmpty)
                line("arrow.triangle.pull", L10n.tr("%lld open", service.mine.count), highlighted: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            let reviews = service.reviewRequests.count
            VStack(spacing: 2) {
                Image(systemName: reviews > 0 ? "eye" : "arrow.triangle.pull")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(reviews > 0 ? Color.orange : Color.secondary)
                Text(verbatim: "\(reviews > 0 ? reviews : service.mine.count)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
        }
    }

    /// What to do about it, short enough for a tile.
    static func problem(_ status: GitHubService.Status) -> String {
        switch status {
        case .ready, .loading: L10n.tr("Loading…")
        case .notInstalled: L10n.tr("Install gh")
        case .signedOut: L10n.tr("Sign in to gh")
        case .failed: L10n.tr("gh failed")
        }
    }

    private func line(_ symbol: String, _ text: String, highlighted: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(highlighted ? Color.orange : Color.secondary)
                .frame(width: 12)
            Text(text).font(.system(size: 10, weight: .semibold)).monospacedDigit()
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

struct GitHubDetails: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let service = model.github
        switch service.status {
        case .ready:
            VStack(alignment: .leading, spacing: 10) {
                list(L10n.tr("Waiting for your review"), "eye", service.reviewRequests)
                list(L10n.tr("Your pull requests"), "arrow.triangle.pull", service.mine)
                if let updated = service.updatedAt {
                    Text(L10n.tr("Updated %@", updated.formatted(.relative(presentation: .named).locale(L10n.locale))))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
            }
        case .loading:
            ProgressView().controlSize(.small)
        case .notInstalled:
            message(L10n.tr("GitHub's `gh` command isn't installed. Install it with `brew install gh`, then sign in with `gh auth login`."))
        case .signedOut:
            message(L10n.tr("`gh` isn't signed in. Run `gh auth login` in Terminal."))
        case .failed(let error):
            message(L10n.tr("gh failed: %@", error))
        }
    }

    /// Already translated; `LocalizedStringKey` only renders its `code`.
    private func message(_ text: String) -> some View {
        Text(LocalizedStringKey(text))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func list(_ title: String, _ symbol: String, _ pulls: [PullRequest]) -> some View {
        BentoCard(title: title, symbol: symbol) {
            VStack(alignment: .leading, spacing: 6) {
                if pulls.isEmpty {
                    Text("None").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                ForEach(pulls.prefix(8)) { pull in
                    Button {
                        if let url = URL(string: pull.url) { NSWorkspace.shared.open(url) }
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: "\(pull.repository.nameWithOwner) #\(pull.number)\(pull.isDraft ? " · " + L10n.tr("Draft") : "")")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                            Text(pull.title).font(.system(size: 11.5, weight: .medium))
                        }
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(pull.url)
                }
            }
        }
    }
}
