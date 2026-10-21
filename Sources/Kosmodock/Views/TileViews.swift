import SwiftUI

// MARK: - Bar tile

/// A widget tile on the bar. Its width depends only on `tile.width` and the
/// density, never on the reading, so the dock keeps its size.
struct TileView: View {
    @Environment(AppModel.self) private var model
    let tile: DockTile
    /// Draws a wide tile square, when the bar is short of room.
    var isSquare = false
    @ViewState private var isHovering = false

    /// A square tile's side: a collapsed capsule's height.
    static func unit(iconSize: Double) -> CGFloat { CGFloat(iconSize) * 0.62 + 18 }

    var body: some View {
        let theme = model.theme
        let unit = Self.unit(iconSize: theme.iconSize)
        let isWide = tile.width == .wide && !isSquare
        let radius = theme.capsuleRadius
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let isHighlighted = model.popoverItemID == DockConfig.itemID(for: tile)
        TileContent(tile: tile, isWide: isWide)
            .padding(.horizontal, isWide ? 9 : 3)
            .frame(width: isWide ? (unit * 2.6).rounded() : unit)
            .frame(minHeight: unit, maxHeight: .infinity)
            .background {
                shape.fill(Color.primary.opacity(isHighlighted ? 0.16 : (isHovering ? 0.12 : 0.07)))
                UtilityTileBackground(tile: tile, shape: shape)
            }
            .overlay {
                shape.strokeBorder(Color.primary.opacity(isHighlighted ? 0.32 : 0.1), lineWidth: 0.5)
            }
            .modifier(FloatingGlass(cornerRadius: radius))
            .contentShape(shape)
            .fileWidgetDropTarget(tile)
            .onTapGesture { model.activate(tile) }
            // One button for VoiceOver, reading the tile's name and its text.
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(tile.title)
            .accessibilityAction { model.activate(tile) }
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
            }
            .scaleEffect(isHovering && theme.hoverEffect != .none ? 1.04 : 1, anchor: .bottom)
            .contextMenu { TileContextMenu(tile: tile) }
            .help(tile.title)
    }
}

extension DockTile {
    /// A command tile's label, a shortcut's name, or the kind's name.
    var title: String {
        if kind == .command, let label, !label.isBlank { return L10n.configText(label) }
        if let title = timeTitle { return title }
        if kind == .shortcut, let shortcutName, !shortcutName.isBlank { return shortcutName }
        return kind.title
    }
}

private struct TileContent: View {
    let tile: DockTile
    let isWide: Bool

    var body: some View {
        switch tile.kind {
        case .clock: ClockTile(tile: tile, isWide: isWide)
        case .battery: BatteryTile(isWide: isWide)
        case .activity: ActivityTile(isWide: isWide)
        case .network: NetworkTile(isWide: isWide)
        case .claudeCode: ClaudeTile(isWide: isWide)
        case .nowPlaying: NowPlayingTile(isWide: isWide)
        case .calendar: CalendarTile(isWide: isWide)
        case .github: GitHubTile(isWide: isWide)
        case .codex: CodexTile(isWide: isWide)
        case .reminders: RemindersTile(isWide: isWide)
        // Time widgets
        case .timer: TimerTile(tile: tile, isWide: isWide)
        case .pomodoro: PomodoroTile(tile: tile, isWide: isWide)
        case .countdown: CountdownTile(tile: tile, isWide: isWide)
        case .stopwatch: StopwatchTile(tile: tile, isWide: isWide)
        case .timeProgress: TimeProgressTile(tile: tile, isWide: isWide)
        case .screenshots, .shelf, .files, .bookmarks, .appCollection, .shortcut, .airDrop: FileWidgetTile(tile: tile, isWide: isWide)
        case .pet: PetTileContent(tile: tile, isWide: isWide)
        case .note, .water, .converter, .emoji, .colorPicker, .clipboard, .weather: UtilityTile(tile: tile, isWide: isWide)
        case .command: CommandTile(tile: tile, isWide: isWide)
        }
    }
}

private struct ClockTile: View {
    let tile: DockTile
    let isWide: Bool

    /// Seconds show in the wide tile and on the analog face.
    private var showsSeconds: Bool {
        tile.showsSeconds && (isWide || tile.clockFace == .analog)
    }

    var body: some View {
        if showsSeconds {
            TimelineView(.periodic(from: .now, by: 1)) { content(at: $0.date) }
        } else {
            TimelineView(.everyMinute) { content(at: $0.date) }
        }
    }

    @ViewBuilder
    private func content(at date: Date) -> some View {
        let locale = L10n.locale
        let zone = tile.timeZoneValue
        if isWide {
            VStack(alignment: .leading, spacing: 1) {
                Text(date, format: (showsSeconds
                    ? Date.FormatStyle.dateTime.hour().minute().second().locale(locale)
                    : Date.FormatStyle.dateTime.hour().minute().locale(locale)).inZone(zone))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .monospacedDigit()
                // A world clock names its city.
                Text(tile.isWorldClock
                     ? "\(tile.title) · \(date.formatted(.dateTime.weekday(.abbreviated).locale(locale).inZone(zone)))"
                     : date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(locale)))
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if tile.clockFace == .analog {
            AnalogClockFace(date: date, zone: zone, showsSeconds: showsSeconds)
                .padding(3)
        } else {
            VStack(spacing: 0) {
                Text((tile.isWorldClock ? tile.title : date.formatted(.dateTime.weekday(.abbreviated).locale(locale))).uppercased())
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(.red)
                Text(date, format: Date.FormatStyle.dateTime.hour(.defaultDigits(amPM: .omitted)).minute().locale(locale).inZone(zone))
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
    }
}

private struct BatteryTile: View {
    @Environment(AppModel.self) private var model
    let isWide: Bool

    var body: some View {
        if let battery = model.telemetry.battery {
            let symbol = Image(systemName: BatteryLook.symbol(for: battery))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(BatteryLook.color(for: battery))
            if isWide {
                HStack(spacing: 7) {
                    symbol.font(.system(size: 17))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: "\(battery.percent)%")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text(BatteryLook.status(of: battery))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    Spacer(minLength: 0)
                }
            } else {
                VStack(spacing: 2) {
                    symbol.font(.system(size: 12))
                    Text(verbatim: "\(battery.percent)%")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
            }
        } else {
            VStack(spacing: 2) {
                Image(systemName: "powerplug.fill").font(.system(size: 12))
                if isWide {
                    Text("No battery").font(.system(size: 9, weight: .medium))
                }
            }
            .foregroundStyle(.secondary)
        }
    }
}

enum BatteryLook {
    static func symbol(for battery: BatteryStatus) -> String {
        if battery.isCharging { return "battery.100percent.bolt" }
        switch battery.percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    static func color(for battery: BatteryStatus) -> Color {
        if battery.isCharging || battery.isPluggedIn { return HealthLevel.ok.color }
        if battery.percent < 20 { return HealthLevel.critical.color }
        return .primary
    }

    static func status(of battery: BatteryStatus) -> String {
        if battery.isCharged { return L10n.tr("Charged") }
        if battery.isCharging {
            return battery.minutesRemaining.map { L10n.tr("%@ to full", duration($0)) } ?? L10n.tr("Charging")
        }
        if battery.isPluggedIn { return L10n.tr("Not charging") }
        return battery.minutesRemaining.map { L10n.tr("%@ left", duration($0)) } ?? L10n.tr("Calculating…")
    }

    /// "3:34", hours and minutes.
    static func duration(_ minutes: Int) -> String {
        String(format: "%d:%02d", minutes / 60, minutes % 60)
    }
}

private struct ActivityTile: View {
    @Environment(AppModel.self) private var model
    let isWide: Bool

    var body: some View {
        let system = model.telemetry.system
        let memory = system.memoryFraction * 100
        if isWide {
            VStack(alignment: .leading, spacing: 5) {
                meter(L10n.tr("CPU"), fraction: system.cpuPercent / 100, value: system.cpuPercent, color: model.accent)
                meter(L10n.tr("RAM"), fraction: system.memoryFraction, value: memory, color: system.pressure.level.color)
            }
        } else {
            VStack(alignment: .leading, spacing: 1) {
                reading("C", system.cpuPercent)
                reading("M", memory)
            }
        }
    }

    private func meter(_ label: String, fraction: Double, value: Double, color: Color) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .leading)
            UsageBar(fraction: fraction, color: color)
            Text(verbatim: "\(Int(value.rounded()))%")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(width: 28, alignment: .trailing)
        }
    }

    private func reading(_ letter: String, _ value: Double) -> some View {
        HStack(spacing: 2) {
            Text(verbatim: letter).foregroundStyle(.secondary)
            Text(verbatim: "\(Int(value.rounded()))%")
        }
        .font(.system(size: 9, weight: .bold, design: .rounded))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

private struct NetworkTile: View {
    @Environment(AppModel.self) private var model
    let isWide: Bool

    var body: some View {
        let rate = model.telemetry.network ?? NetworkRate()
        VStack(alignment: .leading, spacing: isWide ? 2 : 1) {
            line("arrow.down", Format.rate(rate.receivedPerSecond, short: !isWide), color: .blue)
            line("arrow.up", Format.rate(rate.sentPerSecond, short: !isWide), color: .orange)
        }
        .frame(maxWidth: .infinity, alignment: isWide ? .leading : .center)
    }

    private func line(_ symbol: String, _ text: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: isWide ? 8.5 : 7, weight: .heavy))
                .foregroundStyle(color)
            Text(verbatim: text)
                .font(.system(size: isWide ? 11 : 8.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }
}

private struct CommandTile: View {
    @Environment(AppModel.self) private var model
    let tile: DockTile
    let isWide: Bool

    var body: some View {
        let result = model.telemetry.commandResults[TelemetryService.commandKey(tile: tile)]
        let output = result?.output
        let summary = result?.summary ?? ((tile.command?.isBlank ?? true) ? L10n.tr("No command") : L10n.tr("Running…"))
        let color = Color(hex: output?.colorHex) ?? model.accent
        if isWide {
            HStack(spacing: 6) {
                if let symbol = output?.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(color)
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        StatusDot(level: result?.level ?? .unknown, size: 6)
                        Text(tile.title.uppercased())
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    Text(summary)
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                    if let progress = output?.progress {
                        UsageBar(fraction: progress, color: color).padding(.top, 1)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 3) {
                if let symbol = output?.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(color)
                } else {
                    StatusDot(level: result?.level ?? .unknown, size: 7)
                }
                Text(summary)
                    .font(.system(size: 8, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let progress = output?.progress {
                    UsageBar(fraction: progress, color: color)
                }
            }
        }
    }
}

// MARK: - Popover

/// Details of a tile, opened by clicking it.
struct TilePopoverView: View {
    @Environment(AppModel.self) private var model
    let tileID: String

    var body: some View {
        if let tile = model.tile(id: tileID) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    GroupGlyph(symbol: tile.kind.symbol, tint: model.accent, size: 34)
                    Text(tile.title)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    IconButton(symbol: "gearshape", help: L10n.tr("Edit Widgets…"), size: 28) {
                        model.openSettings(.tiles)
                    }
                }
                switch tile.kind {
                case .clock: ClockDetails(tile: tile)
                case .battery: BatteryDetails()
                case .activity: ActivityDetails()
                case .network: NetworkDetails()
                case .claudeCode: ClaudeDetails()
                case .nowPlaying: NowPlayingDetails()
                case .calendar: CalendarDetails()
                case .github: GitHubDetails()
                case .codex: CodexDetails()
                case .reminders: RemindersDetails()
                // Time widgets
                case .timer: TimerDetails(tile: tile)
                case .pomodoro: PomodoroDetails(tile: tile)
                case .countdown: CountdownDetails(tile: tile)
                case .stopwatch: StopwatchDetails(tile: tile)
                case .timeProgress: TimeProgressDetails(tile: tile)
                case .screenshots, .shelf, .files, .bookmarks, .appCollection, .shortcut, .airDrop: FileWidgetDetails(tile: tile)
                case .pet: PetDetails(tile: tile)
                case .note, .water, .converter, .emoji, .colorPicker, .clipboard, .weather: UtilityDetails(tile: tile)
                case .command: CommandDetails(tile: tile)
                }
            }
            .padding(16)
            .frame(width: 340)
            .background(SurfaceBackground(surface: model.theme.popoverSurface, cornerRadius: CGFloat(model.theme.popoverSurface.cornerRadius) + 4))
            .tint(model.accent)
        }
    }
}

private struct ClockDetails: View {
    @Environment(AppModel.self) private var model
    let tile: DockTile

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let locale = L10n.locale
            let zone = tile.timeZoneValue
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    if tile.clockFace == .analog {
                        AnalogClockFace(date: context.date, zone: zone, showsSeconds: true, accent: model.accent)
                            .frame(width: 64, height: 64)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.date, format: Date.FormatStyle.dateTime.hour().minute().second().locale(locale).inZone(zone))
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text(context.date, format: Date.FormatStyle.dateTime.weekday(.wide).day().month(.wide).year().locale(locale).inZone(zone))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                if tile.isWorldClock {
                    WorldClockSummary(tile: tile, date: context.date)
                }
                BentoCard(title: context.date.formatted(Date.FormatStyle.dateTime.month(.wide).year().locale(locale).inZone(zone)), symbol: "calendar") {
                    MonthGrid(date: context.date, zone: zone)
                }
            }
        }
    }
}

/// The current month, weeks starting on the language's first weekday.
private struct MonthGrid: View {
    @Environment(AppModel.self) private var model
    let date: Date
    var zone: TimeZone = .autoupdatingCurrent

    var body: some View {
        let calendar = Self.calendar(in: zone)
        let start = calendar.dateInterval(of: .month, for: date)?.start ?? date
        let days = calendar.range(of: .day, in: .month, for: date)?.count ?? 30
        let leading = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        let today = calendar.component(.day, from: date)
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let ordered = Array(symbols[(calendar.firstWeekday - 1)...] + symbols[..<(calendar.firstWeekday - 1)])
        // Ids are unique across the three kinds of cell: the grid drops repeats.
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 3) {
            ForEach(ordered.enumerated().map { (id: "weekday-\($0.offset)", symbol: $0.element) }, id: \.id) { cell in
                Text(verbatim: cell.symbol)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(0..<leading).map { "blank-\($0)" }, id: \.self) { _ in Color.clear.frame(height: 20) }
            ForEach(Array(1...days).map { (id: "day-\($0)", day: $0) }, id: \.id) { cell in
                let day = cell.day
                Text(verbatim: "\(day)")
                    .font(.system(size: 10.5, weight: day == today ? .bold : .regular, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(day == today ? Color.white : Color.primary)
                    .frame(width: 22, height: 20)
                    .background { if day == today { Circle().fill(model.accent.gradient) } }
            }
        }
    }

    private static func calendar(in zone: TimeZone) -> Calendar {
        var calendar = Calendar.current
        calendar.locale = L10n.locale
        calendar.timeZone = zone
        return calendar
    }
}

private struct BatteryDetails: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let battery = model.telemetry.battery {
            BentoCard(title: L10n.tr("Battery"), symbol: BatteryLook.symbol(for: battery)) {
                HStack(spacing: 14) {
                    ZStack {
                        RingGauge(value: Double(battery.percent) / 100, color: BatteryLook.color(for: battery) == .primary ? model.accent : BatteryLook.color(for: battery))
                        Text(verbatim: "\(battery.percent)%")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .monospacedDigit()
                    }
                    .frame(width: 58, height: 58)
                    VStack(alignment: .leading, spacing: 4) {
                        StatLine(label: L10n.tr("Status"), value: BatteryLook.status(of: battery))
                        StatLine(label: L10n.tr("Power source"), value: battery.isPluggedIn ? L10n.tr("Power adapter") : L10n.tr("Battery"))
                        if let cycles = battery.cycleCount {
                            StatLine(label: L10n.tr("Cycle count"), value: "\(cycles)")
                        }
                    }
                }
            }
        } else {
            Text("This Mac has no battery.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}

private struct ActivityDetails: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let system = model.telemetry.system
        HStack(alignment: .top, spacing: 10) {
            BentoCard(title: L10n.tr("CPU"), symbol: "cpu") {
                VStack(alignment: .leading, spacing: 8) {
                    ZStack {
                        RingGauge(value: system.cpuPercent / 100, color: model.accent)
                        Text(Format.percent(system.cpuPercent))
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .monospacedDigit()
                    }
                    .frame(width: 46, height: 46)
                    StatLine(label: L10n.tr("Load"), value: String(format: "%.2f", locale: L10n.locale, system.loadAverage))
                    StatLine(label: L10n.tr("Cores"), value: "\(system.coreCount)")
                }
            }
            BentoCard(title: L10n.tr("Memory"), symbol: "memorychip") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Format.bytes(system.memoryUsed))
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text(L10n.tr("of %@", Format.bytes(system.memoryTotal)))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    UsageBar(fraction: system.memoryFraction, color: system.pressure.level.color)
                    StatLine(label: L10n.tr("Swap"), value: Format.bytes(system.swapUsed))
                    StatLine(label: L10n.tr("Pressure"), value: system.pressure.title)
                }
            }
        }
    }
}

private struct NetworkDetails: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let rate = model.telemetry.network ?? NetworkRate()
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                speedCard(L10n.tr("Download"), symbol: "arrow.down", value: rate.receivedPerSecond, total: rate.receivedSinceStart, color: .blue)
                speedCard(L10n.tr("Upload"), symbol: "arrow.up", value: rate.sentPerSecond, total: rate.sentSinceStart, color: .orange)
            }
            Text("Wi-Fi, Ethernet and Thunderbolt only. VPN tunnels and virtual machine interfaces are left out, so the same traffic isn't counted twice.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func speedCard(_ title: String, symbol: String, value: Double, total: UInt64, color: Color) -> some View {
        BentoCard(title: title, symbol: symbol) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Format.rate(value))
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color)
                StatLine(label: L10n.tr("Since launch"), value: Format.bytes(total))
            }
        }
    }
}

private struct CommandDetails: View {
    @Environment(AppModel.self) private var model
    let tile: DockTile

    var body: some View {
        let result = model.telemetry.commandResults[TelemetryService.commandKey(tile: tile)]
        BentoCard(title: L10n.tr("Command"), symbol: "terminal") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    StatusDot(level: result?.level ?? .unknown, size: 7)
                    Text(result?.summary ?? L10n.tr("Waiting for first run…"))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if let result {
                        Text(result.updatedAt, style: .relative)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
                Text(tile.command ?? L10n.tr("No command configured"))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail = result?.detail, !detail.isEmpty, detail != result?.summary {
                    Text(detail)
                        .font(.system(size: 10, design: result?.output == nil ? .monospaced : .default))
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                        .textSelection(.enabled)
                }
                if let progress = result?.output?.progress {
                    UsageBar(fraction: progress, color: Color(hex: result?.output?.colorHex) ?? model.accent)
                }
                if let url = result?.output?.url {
                    Button("Open") { NSWorkspace.shared.open(url) }
                        .buttonStyle(GlassPillButtonStyle(tint: model.accent, prominent: true))
                        .help(url.absoluteString)
                }
            }
        } accessory: {
            Button {
                model.telemetry.runCommandNow(for: tile)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Run now")
        }
    }
}
