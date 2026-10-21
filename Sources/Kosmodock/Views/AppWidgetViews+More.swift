import AppKit
import SwiftUI

// Tiles and details for Codex and Reminders, and Music's album art for Now
// Playing. Their data comes from AppWidgetServices+More.swift.

// MARK: - Codex

struct CodexTile: View {
    @Environment(AppModel.self) private var model
    let isWide: Bool

    var body: some View {
        let usage = model.codex.usage
        if !usage.hasSessions {
            HStack(spacing: 5) {
                Image(systemName: TileKind.codex.symbol).font(.system(size: 12))
                if isWide {
                    Text("Codex hasn't run on this Mac")
                        .font(.system(size: 9.5, weight: .medium))
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: isWide ? .leading : .center)
        } else if isWide {
            let tokens = Text(L10n.tr("%@ tokens · 5h", Format.count(usage.lastFiveHours.total)))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if usage.fiveHourLimit == nil, usage.weeklyLimit == nil {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: "CODEX")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                    tokens.font(.system(size: 11, weight: .semibold, design: .rounded))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // A plan can have only one of the windows.
                VStack(alignment: .leading, spacing: 5) {
                    if let limit = usage.fiveHourLimit { LimitMeter(label: L10n.tr("5h"), limit: limit) }
                    if let limit = usage.weeklyLimit { LimitMeter(label: L10n.tr("Week"), limit: limit) }
                    if usage.fiveHourLimit == nil || usage.weeklyLimit == nil {
                        tokens
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        } else {
            VStack(spacing: 2) {
                Image(systemName: TileKind.codex.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.teal)
                Text(verbatim: (usage.fiveHourLimit ?? usage.weeklyLimit).map { "\(Int($0.usedPercent.rounded()))%" } ?? Format.count(usage.lastFiveHours.total))
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }
}

struct CodexDetails: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let usage = model.codex.usage
        if !usage.hasSessions {
            VStack(alignment: .leading, spacing: 4) {
                Text("Codex hasn't run on this Mac")
                    .font(.system(size: 12, weight: .semibold))
                Text("Its usage shows up here after your first session in Codex, read from ~/.codex.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                BentoCard(title: L10n.tr("Plan limits"), symbol: "gauge.with.dots.needle.33percent") {
                    VStack(alignment: .leading, spacing: 8) {
                        if usage.fiveHourLimit == nil, usage.weeklyLimit == nil {
                            Text("Limits show up after your next reply in Codex.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        } else {
                            if let limit = usage.fiveHourLimit { CodexLimitRow(title: L10n.tr("Current session (5h)"), limit: limit) }
                            if let limit = usage.weeklyLimit { CodexLimitRow(title: L10n.tr("Week"), limit: limit) }
                            if let updated = usage.limitsUpdatedAt {
                                Text(L10n.tr("Updated %@", updated.formatted(.relative(presentation: .named).locale(L10n.locale))))
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.tertiary)
                            }
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
                Text("Read from Codex's session files on this Mac. Tokens include cached input.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A plan window with its bar and reset time.
private struct CodexLimitRow: View {
    let title: String
    let limit: ClaudeLimit

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.system(size: 11, weight: .medium))
                Spacer()
                Text(verbatim: "\(Int(limit.usedPercent.rounded()))%")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            UsageBar(fraction: limit.usedPercent / 100, color: LimitMeter.color(for: limit.usedPercent))
            Text(L10n.tr("Resets %@", limit.resetsAt.formatted(.relative(presentation: .named).locale(L10n.locale))))
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Reminders

struct RemindersTile: View {
    @Environment(AppModel.self) private var model
    let isWide: Bool

    var body: some View {
        let service = model.reminders
        TimelineView(.everyMinute) { context in
            let now = context.date
            let count = RemindersService.dueCount(in: service.reminders, at: now)
            let anyOverdue = service.reminders.contains { RemindersService.isOverdue($0, at: now) }
            if isWide {
                if service.access != .granted {
                    Label("Reminders access", systemImage: TileKind.reminders.symbol)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if let next = service.reminders.first {
                    HStack(spacing: 6) {
                        Image(systemName: "circle")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(hex: next.colorHex) ?? model.accent)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(next.title).font(.system(size: 10.5, weight: .semibold))
                            Text(RemindersDetails.due(next, now: now) ?? next.listTitle)
                                .font(.system(size: 9))
                                .foregroundStyle(RemindersService.isOverdue(next, at: now) ? HealthLevel.critical.color : .secondary)
                                .monospacedDigit()
                                .minimumScaleFactor(0.75)
                        }
                        .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                } else {
                    Text("No reminders")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(spacing: 2) {
                    Image(systemName: TileKind.reminders.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(anyOverdue ? HealthLevel.critical.color : (count > 0 ? Color.orange : Color.secondary))
                    if service.access == .granted {
                        Text(verbatim: "\(count)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .monospacedDigit()
                    }
                }
            }
        }
    }
}

struct RemindersDetails: View {
    @Environment(AppModel.self) private var model
    private static let shown = 12

    var body: some View {
        let service = model.reminders
        VStack(alignment: .leading, spacing: 10) {
            switch service.access {
            case .granted:
                TimelineView(.everyMinute) { context in
                    BentoCard(title: L10n.tr("Reminders"), symbol: TileKind.reminders.symbol) {
                        VStack(alignment: .leading, spacing: 7) {
                            if service.reminders.isEmpty {
                                Text("No reminders").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            ForEach(service.reminders.prefix(Self.shown)) { item in
                                ReminderRow(item: item, now: context.date)
                            }
                            if service.reminders.count > Self.shown {
                                Text(L10n.tr("%lld more in Reminders", service.reminders.count - Self.shown))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let error = service.lastError {
                    Text(error).font(.system(size: 10)).foregroundStyle(HealthLevel.critical.color)
                }
            case .unknown:
                Button("Allow Reminders Access") { Task { await service.requestAccessIfNeeded() } }
            case .denied:
                Text("Kosmodock can't read your reminders. Turn it on in System Settings › Privacy & Security › Reminders.")
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Reminders Settings") { NSWorkspace.shared.open(Self.privacySettings) }
            case .unavailable:
                Text("This build can't ask for reminders access.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Button("Open Reminders") {
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Reminders.app"), configuration: NSWorkspace.OpenConfiguration())
            }
            .buttonStyle(.link)
            .font(.system(size: 10.5))
        }
    }

    static let privacySettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")!

    /// "14:30 · in 20 min" today, "Tomorrow · 09:00", or the day alone
    /// ("Yesterday", "In 3 days") for a reminder without a time.
    static func due(_ item: ReminderItem, now: Date) -> String? {
        guard let due = item.due else { return nil }
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: due)).day ?? 0
        let named = RelativeDateTimeFormatter()
        named.locale = L10n.locale
        named.dateTimeStyle = .named
        named.formattingContext = .beginningOfSentence
        let day = named.localizedString(from: DateComponents(day: days))
        guard item.hasDueTime else { return day }
        let time = due.formatted(Date.FormatStyle.dateTime.hour().minute().locale(L10n.locale))
        guard days == 0 else { return "\(day) · \(time)" }
        let relative = RelativeDateTimeFormatter()
        relative.locale = L10n.locale
        relative.unitsStyle = .short
        return "\(time) · \(relative.localizedString(for: due, relativeTo: now))"
    }
}

/// A reminder with a circle that completes it.
private struct ReminderRow: View {
    @Environment(AppModel.self) private var model
    let item: ReminderItem
    let now: Date
    @ViewState private var isHovering = false

    var body: some View {
        let overdue = RemindersService.isOverdue(item, at: now)
        let subtitle = [RemindersDetails.due(item, now: now), item.listTitle]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { model.reminders.complete(item) }
            } label: {
                Image(systemName: isHovering ? "checkmark.circle" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(hex: item.colorHex) ?? model.accent)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .help("Mark as Completed")
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(2)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 9.5))
                        .foregroundStyle(overdue ? HealthLevel.critical.color : .secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Settings › Widgets: the Reminders permission.
struct RemindersAccessRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        LabeledContent("Reminders access") {
            switch model.reminders.access {
            case .granted: Text("Allowed").foregroundStyle(.secondary)
            case .unknown: Button("Allow") { Task { await model.reminders.requestAccessIfNeeded() } }
            case .denied: Button("Open Settings") { NSWorkspace.shared.open(RemindersDetails.privacySettings) }
            case .unavailable: Text("Not in this build").foregroundStyle(.secondary)
            }
        }
        Text("Shows your incomplete reminders from every list. Kosmodock changes one only when you click its circle to complete it.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Now Playing artwork

/// Music's album art, or the player's icon: Spotify's art is on the web, and
/// Kosmodock makes no internet requests.
struct TrackArtwork: View {
    @Environment(AppModel.self) private var model
    let player: MediaPlayer
    let size: CGFloat

    var body: some View {
        if player == .music, let artwork = model.nowPlaying.artwork {
            let shape = RoundedRectangle(cornerRadius: max(3, size * 0.18), style: .continuous)
            Image(nsImage: artwork)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(shape)
                .overlay { shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5) }
        } else {
            PlayerIcon(player: player, size: size)
        }
    }
}
