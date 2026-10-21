import AppKit
import SwiftUI

// Tiles, details and Settings options of the utility widgets. Their state
// comes from `model.utilities` (UtilityWidgetServices.swift, ClipboardHistory.swift
// and WeatherService.swift); their options from the tile itself.

// MARK: - Dispatch

/// A utility widget's tile content; `TileView` gives it its size.
struct UtilityTile: View {
    let tile: DockTile
    let isWide: Bool

    var body: some View {
        switch tile.kind {
        case .note: NoteTile(tile: tile, isWide: isWide)
        case .water: WaterTile(tile: tile, isWide: isWide)
        case .converter: ConverterTile(tile: tile, isWide: isWide)
        case .emoji: EmojiTile(tile: tile, isWide: isWide)
        case .colorPicker: ColorPickerTile(tile: tile, isWide: isWide)
        case .clipboard: ClipboardTile(isWide: isWide)
        case .weather: WeatherTile(tile: tile, isWide: isWide)
        default: EmptyView()
        }
    }
}

/// A utility widget's details, in the tile's popover.
struct UtilityDetails: View {
    let tile: DockTile

    var body: some View {
        switch tile.kind {
        case .note: NoteDetails(tile: tile)
        case .water: WaterDetails(tile: tile)
        case .converter: ConverterDetails(tile: tile)
        case .emoji: EmojiDetails(tile: tile)
        case .colorPicker: ColorPickerDetails(tile: tile)
        case .clipboard: ClipboardDetails()
        case .weather: WeatherDetails(tile: tile)
        default: EmptyView()
        }
    }
}

/// Settings › Widgets: a utility widget's options.
struct UtilityTileOptions: View {
    @Binding var tile: DockTile

    var body: some View {
        switch tile.kind {
        case .note: NoteOptionsRows(tile: $tile)
        case .water: WaterOptionsRows(tile: $tile)
        case .converter:
            Text("Converts length, mass, temperature, volume, speed, area and data with the units built into macOS. The tile shows the last conversion.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .emoji: EmojiOptionsRows(tile: $tile)
        case .colorPicker: ColorPickerOptionsRows(tile: $tile)
        case .clipboard: ClipboardOptionsRows(tile: $tile)
        case .weather: WeatherOptionsRows(tile: $tile)
        default: EmptyView()
        }
    }
}

/// Fills the tile behind its content: the note's paper, the picked color.
struct UtilityTileBackground: View {
    @Environment(AppModel.self) private var model
    let tile: DockTile
    let shape: RoundedRectangle

    var body: some View {
        switch tile.kind {
        case .note:
            shape.fill((Color(hex: (tile.note ?? NoteOptions()).color.hex) ?? .yellow).gradient)
        case .colorPicker:
            if let hex = model.utilities.colorHistory(tile.id).colors.first?.hex, let color = Color(hex: hex) {
                shape.fill(color)
            }
        default:
            EmptyView()
        }
    }
}

extension Binding where Value == DockTile {
    /// One of the tile's optional option groups, with its defaults when unset.
    func option<Option>(_ keyPath: WritableKeyPath<DockTile, Option?>, default fallback: Option) -> Binding<Option> {
        Binding<Option>(
            get: { self.wrappedValue[keyPath: keyPath] ?? fallback },
            set: { self.wrappedValue[keyPath: keyPath] = $0 }
        )
    }
}

/// "Copied" for a moment after a click.
private struct CopiedMark: View {
    var body: some View {
        Label("Copied", systemImage: "checkmark.circle.fill")
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(HealthLevel.ok.color)
            .transition(.opacity)
    }
}

/// Sets a "copied" mark, and clears it 1.2 s later.
@MainActor
private enum CopyFlash {
    static func run(_ set: @escaping @MainActor (String?) -> Void, value: String) {
        set(value)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1200))
            set(nil)
        }
    }
}

// MARK: - Sticky note

private let noteInk = Color.black.opacity(0.8)

private struct NoteTile: View {
    @Environment(AppModel.self) private var model
    let tile: DockTile
    let isWide: Bool

    var body: some View {
        let line = model.utilities.note(tile.id).firstLine
        Group {
            if line.isEmpty {
                VStack(spacing: 2) {
                    Image(systemName: "square.and.pencil").font(.system(size: isWide ? 13 : 12, weight: .semibold))
                    if isWide { Text("Write a note").font(.system(size: 9.5, weight: .medium)) }
                }
                .foregroundStyle(noteInk.opacity(0.55))
                .frame(maxWidth: .infinity)
            } else {
                Text(line)
                    .font(.system(size: isWide ? 10.5 : 8.5, weight: .semibold))
                    .foregroundStyle(noteInk)
                    .lineLimit(isWide ? 2 : 3)
                    .multilineTextAlignment(.leading)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct NoteDetails: View {
    @Environment(AppModel.self) private var model
    let tile: DockTile

    var body: some View {
        let options = tile.note ?? NoteOptions()
        let paper = Color(hex: options.color.hex) ?? .yellow
        let tileID = tile.id
        let utilities = model.utilities
        let text = Binding(
            get: { MainActor.assumeIsolated { utilities.note(tileID).text } },
            set: { value in MainActor.assumeIsolated { utilities.setNoteText(value, for: tileID) } }
        )
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: text)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .foregroundStyle(noteInk)
                if text.wrappedValue.isEmpty {
                    Text("Write something…")
                        .font(.system(size: 13))
                        .foregroundStyle(noteInk.opacity(0.4))
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .padding(10)
            .frame(height: 200)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(paper.gradient))
            // Dark ink and caret on the light paper in either appearance.
            .environment(\.colorScheme, .light)
            HStack(spacing: 8) {
                NoteColorSwatches(selection: options.color) { color in
                    model.updateTile(tileID) { $0.note = NoteOptions(color: color) }
                }
                Spacer(minLength: 4)
                Text("Saved on this Mac")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct NoteColorSwatches: View {
    let selection: NoteColor
    let choose: (NoteColor) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(NoteColor.allCases) { color in
                Button {
                    choose(color)
                } label: {
                    Circle()
                        .fill(Color(hex: color.hex) ?? .yellow)
                        .frame(width: 16, height: 16)
                        .overlay { Circle().strokeBorder(Color.primary.opacity(selection == color ? 0.7 : 0.15), lineWidth: selection == color ? 2 : 0.5) }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(color.title)
                .accessibilityLabel(color.title)
            }
        }
    }
}

private struct NoteOptionsRows: View {
    @Binding var tile: DockTile

    var body: some View {
        let options = $tile.option(\.note, default: NoteOptions())
        LabeledContent("Color") {
            NoteColorSwatches(selection: options.wrappedValue.color) { options.wrappedValue.color = $0 }
        }
        Text("Write in the widget's details. The text is kept in ~/.config/kosmodock/widget-state, and the tile shows its first line.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Water

private let waterColor = Color(red: 0.25, green: 0.66, blue: 1.0)

private struct WaterTile: View {
    @Environment(AppModel.self) private var model
    let tile: DockTile
    let isWide: Bool

    var body: some View {
        let options = tile.water ?? WaterOptions()
        let drinks = model.utilities.waterState(tile.id).drinks
        TimelineView(.everyMinute) { context in
            let now = context.date
            let total = WaterMath.total(of: drinks, on: now)
            let progress = WaterMath.progress(total, goal: options.resolvedGoal)
            let due = WaterMath.nextGlass(after: drinks, every: options.reminderMinutes, goal: options.resolvedGoal, now: now)
            let isDue = due.map { $0 <= now } ?? false
            if isWide {
                HStack(spacing: 4) {
                    ring(progress, isDue: isDue, size: 20)
                    // A wide tile can be 84 pt inside: short lines only.
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: options.resolvedUnit.format(total))
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                        HStack(spacing: 2) {
                            if let symbol = Self.reminderSymbol(due: due, isDue: isDue, reached: total >= options.resolvedGoal) {
                                Image(systemName: symbol).font(.system(size: 7, weight: .bold))
                            }
                            Text(verbatim: Self.shortCaption(due: due, isDue: isDue, progress: progress))
                        }
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(isDue ? Color.orange : .secondary)
                    }
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        model.utilities.drink(tile)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 16, height: 16)
                            .background(Circle().fill(waterColor.opacity(0.25)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(L10n.tr("Drink a glass (%@)", options.resolvedUnit.format(options.resolvedGlass)))
                }
            } else {
                VStack(spacing: 2) {
                    ring(progress, isDue: isDue, size: 20)
                    Text(verbatim: "\(Int((min(progress, 9.99) * 100).rounded()))%")
                        .font(.system(size: 8.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
    }

    /// The next glass's time, "Now" when due, or the day's percent.
    static func shortCaption(due: Date?, isDue: Bool, progress: Double) -> String {
        if isDue { return L10n.tr("Now") }
        if let due { return due.formatted(Date.FormatStyle.dateTime.hour().minute().locale(L10n.locale)) }
        return "\(Int((min(progress, 9.99) * 100).rounded()))%"
    }

    static func reminderSymbol(due: Date?, isDue: Bool, reached: Bool) -> String? {
        if reached { return "checkmark" }
        guard due != nil else { return nil }
        return isDue ? "bell.fill" : "bell"
    }

    private func ring(_ progress: Double, isDue: Bool, size: CGFloat) -> some View {
        ZStack {
            RingGauge(value: progress, color: waterColor, lineWidth: 2.5)
            Image(systemName: "drop.fill")
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(waterColor)
        }
        .frame(width: size, height: size)
        .overlay(alignment: .topTrailing) {
            if isDue { Circle().fill(Color.orange).frame(width: 6, height: 6).offset(x: 2, y: -1) }
        }
    }
}

private struct WaterDetails: View {
    @Environment(AppModel.self) private var model
    let tile: DockTile

    var body: some View {
        let options = tile.water ?? WaterOptions()
        let unit = options.resolvedUnit
        let drinks = model.utilities.waterState(tile.id).drinks
        TimelineView(.everyMinute) { context in
            let now = context.date
            let total = WaterMath.total(of: drinks, on: now)
            let progress = WaterMath.progress(total, goal: options.resolvedGoal)
            let due = WaterMath.nextGlass(after: drinks, every: options.reminderMinutes, goal: options.resolvedGoal, now: now)
            let glasses = drinks.filter { Calendar.current.isDate($0.date, inSameDayAs: now) }.count
            VStack(alignment: .leading, spacing: 10) {
                BentoCard(title: L10n.tr("Today"), symbol: "drop.fill") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 14) {
                            ZStack {
                                RingGauge(value: progress, color: waterColor)
                                Text(verbatim: "\(Int((progress * 100).rounded()))%")
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                            }
                            .frame(width: 58, height: 58)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(verbatim: unit.format(total))
                                    .font(.system(size: 18, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                Text(L10n.tr("of %@", unit.format(options.resolvedGoal)))
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                Text(verbatim: "\(glasses) × \(unit.format(options.resolvedGlass))")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                    .monospacedDigit()
                            }
                        }
                        Text(Self.caption(due: due, now: now, goal: options, total: total))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(due.map { $0 <= now } ?? false ? Color.orange : .secondary)
                        HStack(spacing: 8) {
                            Button {
                                model.utilities.drink(tile)
                            } label: {
                                Label("Drink", systemImage: "plus")
                            }
                            .buttonStyle(GlassPillButtonStyle(tint: waterColor, prominent: true))
                            .help(L10n.tr("Drink a glass (%@)", unit.format(options.resolvedGlass)))
                            Button {
                                model.utilities.takeBackGlass(tile)
                            } label: {
                                Label("Take Back a Glass", systemImage: "arrow.uturn.backward")
                            }
                            .buttonStyle(GlassPillButtonStyle(tint: waterColor))
                            .disabled(glasses == 0)
                            .opacity(glasses == 0 ? 0.5 : 1)
                        }
                    }
                }
                BentoCard(title: L10n.tr("This week"), symbol: "chart.bar.fill") {
                    WaterWeekChart(days: WaterMath.week(of: drinks, endingOn: now), goal: options.resolvedGoal, unit: unit)
                }
            }
        }
    }

    /// The reminder, or how much is left: "Next glass 14:30", "Time for a
    /// glass", "Goal reached".
    static func caption(due: Date?, now: Date, goal options: WaterOptions, total: Double) -> String {
        if total >= options.resolvedGoal { return L10n.tr("Goal reached") }
        if let due {
            if due <= now { return L10n.tr("Time for a glass") }
            let time = due.formatted(Date.FormatStyle.dateTime.hour().minute().locale(L10n.locale))
            return L10n.tr("Next glass at %@", time)
        }
        return L10n.tr("%@ to go", options.resolvedUnit.format(options.resolvedGoal - total))
    }
}

/// Seven days of glasses, today last, against the goal.
private struct WaterWeekChart: View {
    @Environment(AppModel.self) private var model
    let days: [WaterDay]
    let goal: Double
    let unit: WaterUnit

    var body: some View {
        let top = max(goal, days.map(\.amount).max() ?? 0) * 1.05
        let height: CGFloat = 70
        VStack(spacing: 4) {
            ZStack(alignment: .bottom) {
                // The goal line.
                Rectangle()
                    .fill(Color.primary.opacity(0.25))
                    .frame(height: 1)
                    .offset(y: -height * CGFloat(goal / top))
                    .frame(maxHeight: .infinity, alignment: .bottom)
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(days.indices, id: \.self) { index in
                        let day = days[index]
                        let isToday = index == days.count - 1
                        UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4, style: .continuous)
                            .fill(day.amount >= goal ? AnyShapeStyle(HealthLevel.ok.color.gradient) : AnyShapeStyle(waterColor.opacity(isToday ? 1 : 0.55).gradient))
                            .frame(maxWidth: 18)
                            .frame(height: max(3, height * CGFloat(day.amount / top)))
                            .frame(maxWidth: .infinity)
                            .help(unit.format(day.amount))
                    }
                }
            }
            .frame(height: height)
            HStack(spacing: 8) {
                ForEach(days.indices, id: \.self) { index in
                    Text(days[index].start.formatted(.dateTime.weekday(.narrow).locale(L10n.locale)))
                        .font(.system(size: 9, weight: index == days.count - 1 ? .bold : .medium))
                        .foregroundStyle(index == days.count - 1 ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

private struct WaterOptionsRows: View {
    @Binding var tile: DockTile

    var body: some View {
        let options = $tile.option(\.water, default: WaterOptions())
        let current = options.wrappedValue
        let unit = current.resolvedUnit
        Picker("Unit", selection: Binding(get: { unit }, set: { options.wrappedValue.unit = $0 })) {
            ForEach(WaterUnit.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        Stepper(value: displayed(options, \.goal, unit: unit), in: goalRange(unit), step: unit == .milliliters ? 100 : 4) {
            LabeledContent("Daily goal") { Text(verbatim: unit.format(current.resolvedGoal)).monospacedDigit() }
        }
        Stepper(value: glass(options, unit: unit), in: unit == .milliliters ? 50...1000 : 2...34, step: unit == .milliliters ? 25 : 1) {
            LabeledContent("Glass size") { Text(verbatim: unit.format(current.resolvedGlass)).monospacedDigit() }
        }
        Picker("Reminder", selection: Binding(get: { current.reminderMinutes ?? 0 }, set: { options.wrappedValue.reminderMinutes = $0 > 0 ? $0 : nil })) {
            Text("Off").tag(0)
            ForEach(WaterOptions.reminderChoices, id: \.self) { minutes in
                Text(Self.interval(minutes)).tag(minutes)
            }
        }
        Text("With a reminder, the tile shows when the next glass is due, counting from your last one today.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func goalRange(_ unit: WaterUnit) -> ClosedRange<Double> {
        unit.value(ofMilliliters: WaterOptions.goalRange.lowerBound).rounded(.up)...unit.value(ofMilliliters: WaterOptions.goalRange.upperBound).rounded(.down)
    }

    /// The goal in the chosen unit, saved in milliliters (whole ounces).
    private func displayed(_ options: Binding<WaterOptions>, _ keyPath: WritableKeyPath<WaterOptions, Double>, unit: WaterUnit) -> Binding<Double> {
        Binding(
            get: { unit.value(ofMilliliters: options.wrappedValue.resolvedGoal) },
            set: { value in
                let milliliters = unit.milliliters(unit == .ounces ? value.rounded() : value)
                options.wrappedValue[keyPath: keyPath] = min(max(milliliters, WaterOptions.goalRange.lowerBound), WaterOptions.goalRange.upperBound)
            }
        )
    }

    private func glass(_ options: Binding<WaterOptions>, unit: WaterUnit) -> Binding<Double> {
        Binding(
            get: { unit.value(ofMilliliters: options.wrappedValue.resolvedGlass) },
            set: { value in options.wrappedValue.glass = unit.milliliters(unit == .ounces ? value.rounded() : value) }
        )
    }

    /// "Every 45 min", "Every 1 hr, 30 min".
    static func interval(_ minutes: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .short
        var calendar = Calendar.current
        calendar.locale = L10n.locale
        formatter.calendar = calendar
        return L10n.tr("Every %@", formatter.string(from: TimeInterval(minutes * 60)) ?? "\(minutes)")
    }
}

// MARK: - Unit converter

private struct ConverterTile: View {
    @Environment(AppModel.self) private var model
    let tile: DockTile
    let isWide: Bool

    var body: some View {
        let state = model.utilities.conversion(tile.id)
        let from = state.category.unit(state.from)
        let to = state.category.unit(state.to)
        let result = state.result.map { UnitConversion.short($0) } ?? "—"
        if isWide {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "\(UnitConversion.short(state.value)) \(from?.symbol ?? "") =")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(verbatim: "\(result) \(to?.symbol ?? "")")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
            }
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 0) {
                Text(verbatim: result)
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(verbatim: to?.symbol ?? "")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        }
    }
}

private struct ConverterDetails: View {
    @Environment(AppModel.self) private var model
    let tile: DockTile
    @ViewState private var input = ""
    @ViewState private var copied: String?

    var body: some View {
        let state = model.utilities.conversion(tile.id)
        let category = state.category
        let result = state.result
        VStack(alignment: .leading, spacing: 10) {
            Picker("Convert", selection: binding(\.category)) {
                ForEach(ConverterCategory.allCases) { kind in
                    Label(kind.title, systemImage: kind.symbol).tag(kind)
                }
            }
            .pickerStyle(.menu)
            BentoCard(title: L10n.tr("From"), symbol: category.symbol) {
                HStack(spacing: 8) {
                    TextField("Value", text: $input)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .frame(width: 120)
                        .onChange(of: input) { _, text in
                            if let value = UnitConversion.parse(text) { update { $0.value = value } }
                        }
                    unitPicker(binding(\.from), units: category.units)
                }
            }
            HStack {
                Spacer()
                IconButton(symbol: "arrow.up.arrow.down", help: L10n.tr("Swap Units"), size: 28) {
                    update { state in swap(&state.from, &state.to) }
                }
                Spacer()
            }
            BentoCard(title: L10n.tr("To"), symbol: category.symbol) {
                HStack(spacing: 8) {
                    Text(verbatim: result.map { UnitConversion.format($0) } ?? "—")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .textSelection(.enabled)
                        .frame(width: 120, alignment: .leading)
                    unitPicker(binding(\.to), units: category.units)
                }
            } accessory: {
                if copied != nil {
                    CopiedMark()
                } else {
                    Button {
                        guard let result else { return }
                        model.utilities.copy(UnitConversion.format(result, grouping: false))
                        CopyFlash.run({ copied = $0 }, value: "result")
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .help("Copy Result")
                    .disabled(result == nil)
                }
            }
        }
        .onAppear { input = UnitConversion.format(state.value, grouping: false) }
    }

    private func unitPicker(_ selection: Binding<String>, units: [ConverterUnit]) -> some View {
        Picker("Unit", selection: selection) {
            ForEach(units) { unit in
                Text(verbatim: "\(unit.name()) (\(unit.symbol))").tag(unit.id)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(maxWidth: .infinity)
    }

    private func update(_ change: (inout ConverterState) -> Void) {
        var state = model.utilities.conversion(tile.id)
        change(&state)
        model.utilities.setConversion(state, for: tile.id)
    }

    /// A field of the state; a new category starts from its usual pair.
    private func binding<Value>(_ keyPath: WritableKeyPath<ConverterState, Value>) -> Binding<Value> {
        let utilities = model.utilities
        let tileID = tile.id
        return Binding(
            get: { MainActor.assumeIsolated { utilities.conversion(tileID)[keyPath: keyPath] } },
            set: { value in
                MainActor.assumeIsolated {
                    var state = utilities.conversion(tileID)
                    let category = state.category
                    state[keyPath: keyPath] = value
                    if state.category != category {
                        (state.from, state.to) = state.category.defaultPair
                    }
                    utilities.setConversion(state, for: tileID)
                }
            }
        )
    }
}

// MARK: - Emoji

private struct EmojiTile: View {
    @Environment(AppModel.self) private var model
    let tile: DockTile
    let isWide: Bool
    @ViewState private var copied: String?

    var body: some View {
        let recents = model.utilities.emojiState(tile.id).recents
        if isWide {
            // Recent emoji copy with a click; the last cell opens the grid.
            HStack(spacing: 2) {
                ForEach(Array(recents.prefix(3)), id: \.self) { emoji in
                    Button {
                        model.utilities.useEmoji(emoji, tile: tile)
                        CopyFlash.run({ copied = $0 }, value: emoji)
                    } label: {
                        Text(verbatim: emoji)
                            .font(.system(size: 17))
                            .frame(maxWidth: .infinity, minHeight: 26)
                            .overlay(alignment: .bottomTrailing) {
                                if copied == emoji {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(HealthLevel.ok.color)
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L10n.tr("Copy %@", emoji))
                }
                Image(systemName: recents.isEmpty ? TileKind.emoji.symbol : "square.grid.3x3.fill")
                    .font(.system(size: recents.isEmpty ? 14 : 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 26)
                if recents.isEmpty {
                    Text("Emoji")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            Text(verbatim: recents.first ?? "😀")
                .font(.system(size: 20))
                .opacity(recents.isEmpty ? 0.7 : 1)
        }
    }
}

private struct EmojiDetails: View {
    @Environment(AppModel.self) private var model
    let tile: DockTile
    @ViewState private var query = ""
    @ViewState private var copied: String?

    private static let columns = Array(repeating: GridItem(.fixed(30), spacing: 3), count: 9)

    var body: some View {
        let tone = (tile.emoji ?? EmojiOptions()).skinTone
        let recents = model.utilities.emojiState(tile.id).recents
        let results = EmojiCatalog.search(query)
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search emoji", text: $query)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if query.isEmpty, !recents.isEmpty {
                        section(L10n.tr("Recent"))
                        LazyVGrid(columns: Self.columns, spacing: 3) {
                            ForEach(recents, id: \.self) { emoji in
                                EmojiCell(emoji: emoji, help: emoji) { use(emoji) }
                            }
                        }
                        section(L10n.tr("All Emoji"))
                    }
                    if results.isEmpty {
                        Text("No emoji match.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 20)
                            .frame(maxWidth: .infinity)
                    }
                    LazyVGrid(columns: Self.columns, spacing: 3) {
                        ForEach(results) { entry in
                            let emoji = entry.with(tone)
                            EmojiCell(emoji: emoji, help: entry.name) { use(emoji) }
                        }
                    }
                }
            }
            .frame(height: 240)
            HStack {
                if let copied {
                    Label(L10n.tr("Copied %@", copied), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(HealthLevel.ok.color)
                } else {
                    Text("Click an emoji to copy it.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }

    private func use(_ emoji: String) {
        model.utilities.useEmoji(emoji, tile: tile)
        CopyFlash.run({ copied = $0 }, value: emoji)
    }
}

private struct EmojiCell: View {
    let emoji: String
    let help: String
    let action: () -> Void
    @ViewState private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(verbatim: emoji)
                .font(.system(size: 20))
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(isHovering ? 0.12 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

private struct EmojiOptionsRows: View {
    @Binding var tile: DockTile

    var body: some View {
        let options = $tile.option(\.emoji, default: EmojiOptions())
        Picker("Skin tone", selection: options.skinTone) {
            ForEach(SkinTone.allCases) { tone in
                Text(verbatim: "\(tone.sample)  \(tone.title)").tag(tone)
            }
        }
        Stepper(value: options.recentCount, in: EmojiOptions.recentRange, step: 4) {
            LabeledContent("Recent emoji") { Text(verbatim: "\(options.wrappedValue.resolvedRecentCount)").monospacedDigit() }
        }
        Text("Click an emoji to copy it. The wide tile shows the latest ones for a quick copy. The names are Unicode's, in English.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Color picker

private struct ColorPickerTile: View {
    @Environment(AppModel.self) private var model
    let tile: DockTile
    let isWide: Bool

    var body: some View {
        let current = model.utilities.colorHistory(tile.id).colors.first.flatMap { RGBColor(hex: $0.hex) }
        let ink = current.map { $0.luminance > 0.6 ? Color.black.opacity(0.8) : Color.white } ?? .secondary
        let isSampling = model.utilities.samplingTileID == tile.id
        if isWide {
            HStack(spacing: 6) {
                Image(systemName: "eyedropper")
                    .font(.system(size: 12, weight: .semibold))
                VStack(alignment: .leading, spacing: 0) {
                    if let current {
                        Text(verbatim: current.hex)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                        Text(verbatim: "\(current.red) \(current.green) \(current.blue)")
                            .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                            .opacity(0.75)
                    } else {
                        Text(isSampling ? L10n.tr("Picking…") : L10n.tr("Pick a color"))
                            .font(.system(size: 9.5, weight: .medium))
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                Spacer(minLength: 0)
            }
            .foregroundStyle(ink)
        } else {
            Image(systemName: isSampling ? "eyedropper.halffull" : "eyedropper")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ink)
        }
    }
}

private struct ColorPickerDetails: View {
    @Environment(AppModel.self) private var model
    let tile: DockTile
    @ViewState private var copied: String?

    private static let columns = Array(repeating: GridItem(.fixed(28), spacing: 6), count: 8)

    var body: some View {
        let options = tile.colors ?? ColorPickerOptions()
        let history = model.utilities.colorHistory(tile.id)
        let current = history.colors.first.flatMap { RGBColor(hex: $0.hex) }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(current.flatMap { Color(hex: $0.hex) } ?? Color.primary.opacity(0.08))
                    .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5) }
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    if let current {
                        Text(verbatim: current.hex)
                            .font(.system(size: 17, weight: .bold, design: .monospaced))
                            .textSelection(.enabled)
                        Text(verbatim: current.formatted(.rgb))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Click the widget to pick a color anywhere on the screen.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
                Button {
                    model.sampleColor(tile)
                } label: {
                    Label("Pick", systemImage: "eyedropper")
                }
                .buttonStyle(GlassPillButtonStyle(tint: model.accent, prominent: true))
                .help("Pick a Color on the Screen")
            }
            if let current {
                BentoCard(title: L10n.tr("Copy as"), symbol: "doc.on.doc") {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(ColorFormat.allCases) { format in
                            formatRow(format, text: current.formatted(format), isDefault: format == options.format)
                        }
                    }
                }
            }
            if !history.colors.isEmpty {
                BentoCard(title: L10n.tr("Recent colors"), symbol: "clock") {
                    LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 6) {
                        ForEach(history.colors) { color in
                            swatch(color, options: options)
                        }
                    }
                }
                Text("Click a color to use and copy it. Right-click to pin it, so it stays.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func formatRow(_ format: ColorFormat, text: String, isDefault: Bool) -> some View {
        Button {
            model.utilities.copy(text)
            CopyFlash.run({ copied = $0 }, value: format.rawValue)
        } label: {
            HStack(spacing: 6) {
                Text(format.title)
                    .font(.system(size: 10, weight: isDefault ? .bold : .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 88, alignment: .leading)
                Text(verbatim: text)
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Image(systemName: copied == format.rawValue ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.system(size: 10))
                    .foregroundStyle(copied == format.rawValue ? HealthLevel.ok.color : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.tr("Copy %@", text))
    }

    private func swatch(_ color: RecentColor, options: ColorPickerOptions) -> some View {
        Button {
            model.utilities.addColor(color.hex, to: tile.id, options: options)
            if let rgb = RGBColor(hex: color.hex) { model.utilities.copy(rgb.formatted(options.format)) }
            CopyFlash.run({ copied = $0 }, value: options.format.rawValue)
        } label: {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(hex: color.hex) ?? .gray)
                .overlay { RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5) }
                .overlay(alignment: .topTrailing) {
                    if color.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(2)
                            .background(Circle().fill(.black.opacity(0.55)))
                            .offset(x: 3, y: -3)
                    }
                }
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(color.hex)
        .contextMenu {
            Button(color.isPinned ? L10n.tr("Unpin") : L10n.tr("Pin")) { model.utilities.togglePin(color.hex, in: tile.id) }
            Button("Remove") { model.utilities.removeColor(color.hex, from: tile.id) }
        }
    }
}

private struct ColorPickerOptionsRows: View {
    @Binding var tile: DockTile

    var body: some View {
        let options = $tile.option(\.colors, default: ColorPickerOptions())
        Toggle("Copy after picking", isOn: options.copiesOnPick)
        Picker("Copy as", selection: options.format) {
            ForEach(ColorFormat.allCases) { Text($0.title).tag($0) }
        }
        Stepper(value: options.recentCount, in: ColorPickerOptions.recentRange, step: 4) {
            LabeledContent("Recent colors") { Text(verbatim: "\(options.wrappedValue.resolvedRecentCount)").monospacedDigit() }
        }
        Text("Click the widget to pick a color anywhere on the screen with macOS's magnifier, which needs no Screen Recording permission. Pinned colors stay beyond the limit.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Clipboard history

private struct ClipboardTile: View {
    @Environment(AppModel.self) private var model
    let isWide: Bool

    var body: some View {
        let history = model.utilities.clipboard
        let latest = history.items.first
        if isWide {
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.tr("%lld items", history.items.count).uppercased())
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(latest.map(\.summary) ?? L10n.tr("Nothing copied yet"))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(latest == nil ? .secondary : .primary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 2) {
                Image(systemName: TileKind.clipboard.symbol)
                    .font(.system(size: 12, weight: .semibold))
                Text(verbatim: "\(history.items.count)")
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }
}

private struct ClipboardDetails: View {
    @Environment(AppModel.self) private var model
    @ViewState private var query = ""
    @ViewState private var confirmsClear = false

    var body: some View {
        let history = model.utilities.clipboard
        let items = ClipboardPolicy.search(query, in: history.items)
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search the history", text: $query)
                .textFieldStyle(.roundedBorder)
            if history.items.isEmpty {
                Text("Copy something and it shows up here.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
            } else if items.isEmpty {
                Text("Nothing matches.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(items) { item in
                            ClipboardRow(item: item)
                        }
                    }
                }
                .frame(height: min(300, CGFloat(items.count) * 42 + 4))
            }
            HStack(spacing: 8) {
                Text(L10n.tr("%lld items", history.items.count))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                if confirmsClear {
                    Button("Cancel") { confirmsClear = false }
                        .buttonStyle(GlassPillButtonStyle(tint: model.accent))
                    Button("Clear") {
                        history.clear()
                        confirmsClear = false
                    }
                    .buttonStyle(GlassPillButtonStyle(tint: HealthLevel.critical.color, prominent: true))
                } else {
                    Button("Clear History") { confirmsClear = true }
                        .buttonStyle(GlassPillButtonStyle(tint: model.accent))
                        .disabled(history.items.allSatisfy(\.isPinned))
                        .help("Forget every item except the pinned ones")
                }
            }
        }
    }
}

private struct ClipboardRow: View {
    @Environment(AppModel.self) private var model
    let item: ClipboardItem
    @ViewState private var isHovering = false

    var body: some View {
        let history = model.utilities.clipboard
        Button {
            history.copy(item)
            model.dismissPopover?()
        } label: {
            HStack(spacing: 8) {
                preview(history)
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.summary)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(item.kind == .text ? 2 : 1)
                        .truncationMode(item.kind == .files ? .middle : .tail)
                    Text(item.date.formatted(.relative(presentation: .named).locale(L10n.locale)))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                if item.isPinned || isHovering {
                    Button {
                        history.togglePin(item)
                    } label: {
                        Image(systemName: item.isPinned ? "pin.fill" : "pin")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(item.isPinned ? model.accent : .secondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(item.isPinned ? L10n.tr("Unpin") : L10n.tr("Pin"))
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(isHovering ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Copy to the Clipboard")
        .contextMenu {
            Button("Copy") {
                history.copy(item)
                model.dismissPopover?()
            }
            Button(item.isPinned ? L10n.tr("Unpin") : L10n.tr("Pin")) { history.togglePin(item) }
            Divider()
            Button("Delete") { history.remove(item) }
        }
    }

    @ViewBuilder
    private func preview(_ history: ClipboardHistory) -> some View {
        switch item.kind {
        case .image:
            if let image = history.thumbnail(for: item) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                symbol("photo")
            }
        case .files:
            if let path = item.paths?.first {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().aspectRatio(contentMode: .fit)
            } else {
                symbol("doc")
            }
        case .text:
            symbol(item.text.flatMap(URL.init(string:))?.scheme?.hasPrefix("http") == true ? "link" : "text.alignleft")
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 30, height: 30)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.07)))
    }
}

private struct ClipboardOptionsRows: View {
    @Environment(AppModel.self) private var model
    @Binding var tile: DockTile

    var body: some View {
        let options = $tile.option(\.clipboard, default: ClipboardOptions())
        let current = options.wrappedValue
        Picker("Keep up to", selection: options.limit) {
            ForEach(Self.choices([10, 25, 50, 100, 200, 500, 1000], current.limit), id: \.self) { count in
                Text(L10n.tr("%lld items", count)).tag(count)
            }
        }
        Picker("Forget after", selection: options.days) {
            ForEach(Self.choices([1, 3, 7, 14, 30, 60, 90, 180, 365], current.days), id: \.self) { days in
                Text(L10n.tr("%lld days", days)).tag(days)
            }
        }
        LabeledContent("History") {
            Button("Clear History") { model.utilities.clipboard.clear() }
                .disabled(model.utilities.clipboard.items.allSatisfy(\.isPinned))
        }
        Text("While this widget is on the Dock, Kosmodock reads everything you copy (text, images and files) and keeps it only on this Mac, in ~/.config/kosmodock/clipboard, readable by you alone. Copies that password managers and other apps mark as concealed or transient are skipped. Pinned items never expire. Removing the widget deletes the history.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// The choices, plus a value set in config.json that isn't one of them.
    static func choices(_ values: [Int], _ current: Int) -> [Int] {
        values.contains(current) ? values : (values + [current]).sorted()
    }
}

// MARK: - Weather

private struct WeatherTile: View {
    @Environment(AppModel.self) private var model
    let tile: DockTile
    let isWide: Bool

    var body: some View {
        let options = tile.weather ?? WeatherOptions()
        let unit = options.resolvedUnit
        let entry = model.utilities.weather.entries[tile.id]
        if let location = options.location {
            let report = entry?.report
            let symbol = report.map { $0.condition.symbol(isDay: $0.isDay) } ?? (entry?.error == nil ? "cloud" : "exclamationmark.triangle")
            let temperature = report.map { unit.degrees($0.temperature) } ?? "—°"
            if isWide {
                HStack(spacing: 7) {
                    Image(systemName: symbol)
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 18))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: temperature)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text(location.name)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    Spacer(minLength: 0)
                }
            } else {
                VStack(spacing: 1) {
                    Image(systemName: symbol)
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 13))
                    Text(verbatim: temperature)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        } else {
            HStack(spacing: 5) {
                Image(systemName: "location.magnifyingglass").font(.system(size: 12))
                if isWide {
                    Text("Choose a city")
                        .font(.system(size: 9.5, weight: .medium))
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: isWide ? .leading : .center)
        }
    }
}

private struct WeatherDetails: View {
    @Environment(AppModel.self) private var model
    let tile: DockTile

    var body: some View {
        let options = tile.weather ?? WeatherOptions()
        let unit = options.resolvedUnit
        let entry = model.utilities.weather.entries[tile.id]
        VStack(alignment: .leading, spacing: 10) {
            if let location = options.location {
                if let report = entry?.report {
                    current(report, location: location, unit: unit)
                    BentoCard(title: L10n.tr("Next days"), symbol: "calendar") {
                        VStack(spacing: 6) {
                            ForEach(Array(report.days.enumerated()), id: \.element.id) { index, day in
                                dayRow(day, isFirst: index == 0, unit: unit)
                            }
                        }
                    }
                } else if entry?.error == nil {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L10n.tr("Getting the weather for %@…", location.name))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                footer(entry)
            } else {
                Text("Choose the city to show.")
                    .font(.system(size: 12, weight: .semibold))
                WeatherLocationSearch { place in
                    model.updateTile(tile.id) { tile in
                        tile.weather = WeatherOptions(location: place, unit: tile.weather?.unit)
                    }
                }
            }
        }
    }

    private func current(_ report: WeatherReport, location: WeatherLocation, unit: TemperatureUnit) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: report.condition.symbol(isDay: report.isDay))
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 36))
                .frame(width: 48)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: unit.degrees(report.temperature))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(report.condition.title)
                    .font(.system(size: 12, weight: .medium))
                Text(L10n.tr("Feels like %@", unit.degrees(report.feelsLike)))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                Text(location.name)
                    .font(.system(size: 12, weight: .semibold))
                if let detail = location.detail {
                    Text(detail)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                if let today = report.days.first {
                    Text(verbatim: "↑ \(unit.degrees(today.high))  ↓ \(unit.degrees(today.low))")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .padding(.top, 3)
                }
            }
            .lineLimit(2)
        }
    }

    private func dayRow(_ day: WeatherDay, isFirst: Bool, unit: TemperatureUnit) -> some View {
        HStack(spacing: 8) {
            Text(OpenMeteo.dayLabel(day.date, isFirst: isFirst))
                .font(.system(size: 11, weight: isFirst ? .bold : .medium))
                .frame(width: 52, alignment: .leading)
            Image(systemName: day.condition.symbol())
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 13))
                .frame(width: 22)
            Text(day.condition.title)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(verbatim: unit.degrees(day.low))
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
            Text(verbatim: unit.degrees(day.high))
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .frame(width: 34, alignment: .trailing)
        }
        .monospacedDigit()
    }

    private func footer(_ entry: WeatherService.Entry?) -> some View {
        HStack(spacing: 6) {
            if let error = entry?.error {
                Text(L10n.tr("Couldn't update: %@", error))
                    .font(.system(size: 9.5))
                    .foregroundStyle(HealthLevel.critical.color)
                    .lineLimit(2)
            } else if let updated = entry?.report?.updatedAt {
                Text(L10n.tr("Updated %@", updated.formatted(.relative(presentation: .named).locale(L10n.locale))))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            Button("Weather data by Open-Meteo.com") {
                if let url = URL(string: "https://open-meteo.com/") { NSWorkspace.shared.open(url) }
            }
            .buttonStyle(.link)
            .font(.system(size: 9.5))
        }
    }
}

/// Finds a city through Open-Meteo's geocoding, for the weather tile.
private struct WeatherLocationSearch: View {
    @Environment(AppModel.self) private var model
    let choose: (WeatherLocation) -> Void
    @ViewState private var query = ""
    @ViewState private var results: [WeatherLocation] = []
    @ViewState private var isSearching = false
    @ViewState private var error: String?
    @ViewState private var searched = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("City", text: $query, prompt: Text(verbatim: "Lisboa, Berlin, Austin…"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(search)
                Button("Search", action: search)
                    .disabled(query.isBlank || isSearching)
            }
            if isSearching {
                ProgressView().controlSize(.small)
            }
            if let error {
                Text(error)
                    .font(.system(size: 10.5))
                    .foregroundStyle(HealthLevel.critical.color)
            } else if searched, !isSearching, results.isEmpty {
                Text("No places found.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            ForEach(results) { place in
                Button {
                    choose(place)
                    results = []
                    query = ""
                    searched = false
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "mappin.circle.fill").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(place.name).font(.system(size: 11.5, weight: .medium))
                            if let detail = place.detail {
                                Text(detail).font(.system(size: 9.5)).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func search() {
        let text = query
        guard !text.isBlank else { return }
        isSearching = true
        error = nil
        let weather = model.utilities.weather
        Task { @MainActor in
            do {
                results = try await weather.search(text)
            } catch {
                self.error = error.localizedDescription
                results = []
            }
            isSearching = false
            searched = true
        }
    }
}

private struct WeatherOptionsRows: View {
    @Binding var tile: DockTile

    var body: some View {
        let options = $tile.option(\.weather, default: WeatherOptions())
        let current = options.wrappedValue
        LabeledContent("City") {
            if let location = current.location {
                HStack(spacing: 8) {
                    Text(location.title).foregroundStyle(.secondary).lineLimit(1)
                    Button("Change") { options.wrappedValue.location = nil }
                }
            } else {
                Text("None").foregroundStyle(.secondary)
            }
        }
        if current.location == nil {
            WeatherLocationSearch { place in options.wrappedValue.location = place }
        }
        Picker("Units", selection: Binding(get: { current.resolvedUnit }, set: { options.wrappedValue.unit = $0 })) {
            ForEach(TemperatureUnit.allCases) { Text(verbatim: $0.symbol).tag($0) }
        }
        .pickerStyle(.segmented)
        Text("The only widget that goes online: it asks Open-Meteo (open-meteo.com, no account) for the weather at the city's coordinates every 20 minutes and when you open its details, and sends the name you search for to find the city. Nothing is sent while no weather widget is on the Dock, and your location is never used.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Snapshots

#if DEBUG
/// Debug snapshots of the widgets that read the pasteboard or the network,
/// from sample data only: their services stay off.
@MainActor
enum UtilityWidgetPreviews {
    static func views(model: AppModel) -> [(name: String, view: AnyView)] {
        let utilities = model.utilities
        utilities.isPreview = true
        let lisbon = WeatherLocation(name: "Lisboa", latitude: 38.7167, longitude: -9.1333, detail: "Lisboa, Portugal")
        let weather = DockTile(id: "preview-weather", kind: .weather, weather: WeatherOptions(location: lisbon, unit: .celsius))
        let today = Date()
        let days = (0..<5).map { offset -> WeatherDay in
            let date = Calendar.current.date(byAdding: .day, value: offset, to: today) ?? today
            let stamp = date.formatted(.iso8601.year().month().day())
            return WeatherDay(date: stamp, code: [1, 3, 61, 80, 0][offset], high: [24.4, 22.1, 19.6, 20.3, 25.0][offset], low: [15.2, 14.8, 13.9, 14.1, 16.0][offset])
        }
        utilities.weather.injectPreview(
            WeatherReport(temperature: 21.6, feelsLike: 20.2, code: 2, isDay: true, days: days, updatedAt: today.addingTimeInterval(-240)),
            location: lisbon, tileID: weather.id
        )
        let clipboard = DockTile(id: "preview-clipboard", kind: .clipboard)
        utilities.clipboard.injectPreviewItems([
            ClipboardItem(id: "1", kind: .text, text: "git rebase --onto main feature/widgets", digest: "1", date: today.addingTimeInterval(-30)),
            ClipboardItem(id: "2", kind: .text, text: "https://open-meteo.com/en/docs", digest: "2", date: today.addingTimeInterval(-600)),
            ClipboardItem(id: "3", kind: .files, paths: ["/Applications/Safari.app", "/Applications/Mail.app"], digest: "3", date: today.addingTimeInterval(-3600)),
            ClipboardItem(id: "4", kind: .text, text: "Meeting moved to Thursday at 15:00.\nBring the slides.", digest: "4", date: today.addingTimeInterval(-86_400), isPinned: true),
        ])
        let height = TileView.unit(iconSize: model.theme.iconSize) + 6
        func tiles(_ tile: DockTile) -> AnyView {
            var wide = tile
            wide.width = .wide
            var square = tile
            square.width = .square
            return AnyView(HStack(spacing: 8) { TileView(tile: wide); TileView(tile: square) }.frame(height: height))
        }
        func details(_ tile: DockTile) -> AnyView {
            AnyView(
                UtilityDetails(tile: tile)
                    .padding(16)
                    .frame(width: 340)
                    .background(SurfaceBackground(surface: model.theme.popoverSurface, cornerRadius: 18))
                    .tint(model.accent)
            )
        }
        // ImageRenderer can't draw scroll views: the rows on their own.
        let rows = AnyView(
            VStack(spacing: 2) { ForEach(utilities.clipboard.items) { ClipboardRow(item: $0) } }
                .padding(16)
                .frame(width: 340)
        )
        let emoji = AnyView(
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 3), count: 9), spacing: 3) {
                ForEach(EmojiCatalog.all.prefix(36) + EmojiCatalog.search("flag").prefix(9)) { entry in
                    EmojiCell(emoji: entry.with(.mediumLight), help: entry.name) {}
                }
            }
            .padding(16)
        )
        // The config's utility tiles away from the bar's AppKit overlays.
        let configured = model.config.tiles.filter { TileKind.utilities.contains($0.kind) }.map { tile in
            (name: "utility-tiles-\(tile.id)", view: tiles(tile))
        }
        return configured + [
            ("utility-tiles-weather", tiles(weather)), ("utility-popover-weather", details(weather)),
            ("utility-tiles-clipboard", tiles(clipboard)), ("utility-popover-clipboard", details(clipboard)),
            ("utility-clipboard-rows", rows), ("utility-emoji-grid", emoji),
        ]
    }
}
#endif
