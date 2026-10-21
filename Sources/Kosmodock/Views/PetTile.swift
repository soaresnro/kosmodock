import AppKit
import Observation
import SwiftUI

// The pet tile: a small animal that sits while the Mac is quiet, walks when
// it works and runs when it's busy (`PetActivity`, from `TelemetryService`),
// and naps after a quiet while (`PetMemory`). It paces in its tile, or walks
// along the top of the whole bar, and can keep walking along the bottom of
// the screen while Intellihide hides the dock. Drawn with SF Symbols.

// MARK: - Keeper

/// Each pet tile's mood, from the readings, once a second while a pet is on
/// the bar.
@MainActor
@Observable
final class PetKeeper {
    /// By tile id; assigned only when one changes.
    private(set) var moods: [String: PetMood] = [:]

    @ObservationIgnored private let configService: ConfigService
    @ObservationIgnored private let telemetry: TelemetryService
    @ObservationIgnored private var memories: [String: PetMemory] = [:]
    @ObservationIgnored private var timer: Timer?

    init(configService: ConfigService, telemetry: TelemetryService) {
        self.configService = configService
        self.telemetry = telemetry
    }

    func mood(for tileID: String) -> PetMood {
        moods[tileID] ?? .sitting
    }

    /// The reading the pet follows, 0…1.
    func load(for options: PetOptions) -> Double {
        let system = telemetry.system
        return options.follows == .cpu ? min(1, max(0, system.cpuPercent / 100)) : system.memoryFraction
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != (timer != nil) else { return }
        timer?.invalidate()
        timer = nil
        guard enabled else { return }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// "Put Out Food": the pet wakes up and eats.
    func feed(tileID: String) {
        memories[tileID, default: PetMemory()].feed(at: Date())
        tick()
    }

    private func tick() {
        let now = Date()
        var next: [String: PetMood] = [:]
        for tile in configService.config.tiles where tile.kind == .pet {
            let options = tile.petOptions
            var memory = memories[tile.id] ?? PetMemory()
            memory.record(load: load(for: options), metric: options.follows, at: now)
            memories[tile.id] = memory
            next[tile.id] = memory.mood(at: now)
        }
        memories = memories.filter { next[$0.key] != nil }
        if next != moods { moods = next }
    }
}

// MARK: - Figure

/// The animal in one moment of its mood, its feet on the bottom edge.
struct PetFigure: View {
    let options: PetOptions
    let mood: PetMood
    /// The symbol's point size.
    let size: CGFloat
    var facingRight = true
    /// Seconds; drives the hops, the breathing and the floating z's.
    var time: TimeInterval = 0
    /// `false` holds still (Reduce Motion): the pose alone tells the mood.
    var moves = true

    static func frameSize(for size: CGFloat) -> CGSize {
        CGSize(width: (size * 1.5).rounded(.up), height: (size * 1.3).rounded(.up))
    }

    var body: some View {
        let coat = Color(hex: options.coat) ?? .orange
        let frame = Self.frameSize(for: size)
        let direction: CGFloat = facingRight ? 1 : -1
        ZStack(alignment: .bottom) {
            if mood == .running { speedLines.offset(x: -direction * size * 0.62) }
            animal(coat: coat)
                .offset(y: -hop)
            if mood == .eating {
                Bowl(size: size)
                    .offset(x: direction * size * 0.6)
            }
            if mood == .sleeping {
                sleepyZs.offset(x: direction * size * 0.45, y: -size * 0.55)
            }
        }
        .frame(width: frame.width, height: frame.height, alignment: .bottom)
    }

    private func animal(coat: Color) -> some View {
        let luminance = DockSurface.luminance(hex: options.coat) ?? 0.5
        // A thin halo keeps a black cat visible on a dark bar, and a white one on a light bar.
        let halo = luminance < 0.3 ? Color.white.opacity(0.55) : Color.black.opacity(0.35)
        return Image(systemName: options.animal.symbol)
            .font(.system(size: size, weight: .regular))
            .foregroundStyle(coat)
            .shadow(color: halo, radius: 0.6)
            .rotationEffect(.degrees(options.animal.heading))
            .scaleEffect(x: squash.width, y: squash.height, anchor: .bottom)
            .rotationEffect(.degrees(tilt), anchor: .bottom)
            .scaleEffect(x: facingRight ? 1 : -1, y: 1)
    }

    private var cycle: Double { moves ? time : 0.2 }

    private var hop: CGFloat {
        guard moves else { return 0 }
        switch mood {
        case .walking: return CGFloat(abs(sin(time * .pi * 2.2))) * size * 0.1
        case .running: return CGFloat(abs(sin(time * .pi * 3.6))) * size * 0.2
        default: return 0
        }
    }

    /// Degrees, for a figure facing right: positive leans forward.
    private var tilt: Double {
        switch mood {
        case .walking: moves ? 4 * sin(cycle * .pi * 2.2) : 0
        case .running: 8
        case .eating: 10 + (moves ? 6 * max(0, sin(cycle * 7)) : 0)
        case .sitting, .sleeping: 0
        }
    }

    private var squash: CGSize {
        switch mood {
        // Lying down, breathing slowly.
        case .sleeping: CGSize(width: 1.06, height: 0.8 + (moves ? 0.035 * sin(cycle * 1.3) : 0))
        case .sitting: CGSize(width: 1, height: 1 + (moves ? 0.025 * sin(cycle * 2.2) : 0))
        default: CGSize(width: 1, height: 1)
        }
    }

    private var speedLines: some View {
        VStack(alignment: .trailing, spacing: size * 0.12) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(Color.primary.opacity(0.35))
                    .frame(width: size * (index == 1 ? 0.42 : 0.28), height: max(1, size * 0.07))
                    .opacity(moves ? 0.5 + 0.5 * sin(time * 9 + Double(index) * 2) : 0.8)
            }
        }
        .padding(.bottom, size * 0.25)
    }

    private var sleepyZs: some View {
        ZStack(alignment: .bottomLeading) {
            ForEach(0..<3, id: \.self) { index in
                let u = moves ? (time * 0.45 + Double(index) / 3).truncatingRemainder(dividingBy: 1) : Double(index) / 3 + 0.2
                Text(verbatim: "z")
                    .font(.system(size: size * (0.26 + 0.1 * CGFloat(index)), weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.primary.opacity(0.75))
                    .offset(x: CGFloat(u) * size * 0.35, y: -CGFloat(u) * size * 0.45)
                    .opacity(moves ? sin(.pi * u) : 0.85)
            }
        }
        .frame(width: size * 0.6, height: size * 0.6, alignment: .bottomLeading)
    }
}

/// A food bowl with a few kibbles.
private struct Bowl: View {
    let size: CGFloat

    var body: some View {
        let width = size * 0.55
        let height = size * 0.22
        ZStack(alignment: .bottom) {
            HStack(spacing: width * 0.08) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(Color(red: 0.55, green: 0.34, blue: 0.18)).frame(width: width * 0.2, height: width * 0.2)
                }
            }
            .offset(y: -height * 0.75)
            UnevenRoundedRectangle(bottomLeadingRadius: height * 0.7, bottomTrailingRadius: height * 0.7, style: .continuous)
                .fill(Color(red: 0.84, green: 0.25, blue: 0.27).gradient)
                .frame(width: width, height: height)
        }
        .frame(width: width, height: height * 2, alignment: .bottom)
    }
}

// MARK: - Walking

/// A pet going back and forth across the view's width, its feet on the
/// bottom edge. Changing pace starts a new path from where it stands.
struct WalkingPet: View {
    let options: PetOptions
    let mood: PetMood
    let size: CGFloat
    /// Points per second walking; running goes three times as fast.
    let walkSpeed: Double
    var isPaused = false
    /// Puts several pets in different places.
    var seed: Double = 0
    @ViewState private var path: PetPath?
    @ViewState private var range: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var still: Bool { reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    var body: some View {
        GeometryReader { proxy in
            let figure = PetFigure.frameSize(for: size)
            let width = max(0, Double(proxy.size.width - figure.width))
            TimelineView(.animation(minimumInterval: mood.isMoving ? 1.0 / 30 : 1.0 / 12, paused: isPaused || still)) { timeline in
                let now = timeline.date.timeIntervalSinceReferenceDate
                let place = currentPath(range: width).position(at: now, speed: still ? 0 : speed(for: mood), range: width)
                PetFigure(options: options, mood: mood, size: size, facingRight: place.facingRight, time: now + seed, moves: !still)
                    .position(x: CGFloat(place.x) + figure.width / 2, y: proxy.size.height - figure.height / 2)
            }
            .onAppear { range = width }
            .onChange(of: width) { _, new in range = new }
        }
        .onChange(of: mood) { old, _ in
            let now = Date().timeIntervalSinceReferenceDate
            let place = currentPath(range: range).position(at: now, speed: still ? 0 : speed(for: old), range: range)
            path = PetPath(startX: place.x, startTime: now, facingRight: place.facingRight)
        }
    }

    private func currentPath(range: Double) -> PetPath {
        // Before the first change of pace: a place of its own, from the seed.
        path ?? PetPath(startX: range * (0.5 + 0.35 * sin(seed * 1.7)), startTime: seed * 13, facingRight: Int(seed) % 2 == 0)
    }

    private func speed(for mood: PetMood) -> Double {
        switch mood {
        case .walking: walkSpeed
        case .running: walkSpeed * 3
        case .sitting, .sleeping, .eating: 0
        }
    }
}

// MARK: - Tile

/// What a pet tile shows: the pet pacing in it, or, when it roams the bar,
/// its mood and the reading it follows.
struct PetTileContent: View {
    @Environment(AppModel.self) private var model
    let tile: DockTile
    let isWide: Bool

    var body: some View {
        let options = tile.petOptions
        let mood = model.pets.mood(for: tile.id)
        if options.roams {
            PetHome(options: options, mood: mood, load: model.pets.load(for: options), isWide: isWide)
        } else {
            GeometryReader { proxy in
                WalkingPet(
                    options: options, mood: mood, size: (proxy.size.height * options.size.tileFactor).rounded(),
                    walkSpeed: isWide ? 9 : 3, isPaused: model.isDockHidden
                )
                .padding(.bottom, 3)
            }
            .accessibilityLabel(Text(verbatim: "\(options.animal.title), \(mood.title)"))
        }
    }
}

/// The tile of a pet out walking on the bar.
private struct PetHome: View {
    let options: PetOptions
    let mood: PetMood
    let load: Double
    let isWide: Bool

    var body: some View {
        let paw = Image(systemName: "pawprint.fill")
            .foregroundStyle(Color(hex: options.coat) ?? .orange)
        let reading = "\(Int((load * 100).rounded()))%"
        if isWide {
            HStack(spacing: 7) {
                paw.font(.system(size: 15))
                VStack(alignment: .leading, spacing: 1) {
                    Text(mood.title)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                    Text(verbatim: "\(options.follows.title) \(reading)")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                Spacer(minLength: 0)
            }
        } else {
            VStack(spacing: 2) {
                paw.font(.system(size: 12))
                Text(verbatim: reading)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
        }
    }
}

/// The popover of a pet tile.
struct PetDetails: View {
    @Environment(AppModel.self) private var model
    let tile: DockTile

    var body: some View {
        let options = tile.petOptions
        let mood = model.pets.mood(for: tile.id)
        let load = model.pets.load(for: options)
        VStack(alignment: .leading, spacing: 10) {
            BentoCard(title: options.animal.title, symbol: options.animal.symbol) {
                VStack(alignment: .leading, spacing: 8) {
                    WalkingPet(options: options, mood: mood, size: 30, walkSpeed: 24)
                        .frame(height: 46)
                        .overlay(alignment: .bottom) {
                            Capsule().fill(Color.primary.opacity(0.12)).frame(height: 2)
                        }
                    StatLine(label: L10n.tr("Now"), value: mood.title)
                    StatLine(label: options.follows.title, value: "\(Int((load * 100).rounded()))%")
                }
            }
            Text(PetCopy.behavior)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Put Out Food") { model.pets.feed(tileID: tile.id) }
                    .buttonStyle(GlassPillButtonStyle(tint: model.accent, prominent: true))
                Spacer()
            }
        }
    }
}

private enum PetCopy {
    static var behavior: String {
        L10n.tr("It sits while the Mac is quiet, walks when it works and runs when it's busy. After two quiet minutes it naps; putting out food wakes it.")
    }
}

/// The pet tile's options in Settings › Widgets.
struct PetTileOptions: View {
    let tile: Binding<DockTile>

    var body: some View {
        Picker("Animal", selection: option(\.animal)) {
            ForEach(PetAnimal.allCases) { animal in
                Label(animal.title, systemImage: animal.symbol).tag(animal)
            }
        }
        Picker("Coat", selection: coat) {
            ForEach(PetCoat.allCases) { Text($0.title).tag(PetCoat?.some($0)) }
            if PetCoat(hex: tile.wrappedValue.petOptions.coatHex) == nil {
                Text("Custom color").tag(PetCoat?.none)
            }
        }
        ColorPicker("Coat color", selection: coatColor, supportsOpacity: false)
        Picker("Pet size", selection: option(\.size)) {
            ForEach(PetSize.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        Picker("Follows", selection: option(\.follows)) {
            ForEach(PetMetric.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        Toggle("Walks along the top of the whole Dock", isOn: option(\.roams))
        Toggle("Stays visible when the Dock hides", isOn: option(\.staysVisible))
        Text(PetCopy.behavior)
            .font(.caption)
            .foregroundStyle(.secondary)
        Text("When the Dock slides away (Intellihide), a pet that stays visible keeps walking along the bottom of the screen. Clicks go through it.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func option<Value>(_ keyPath: WritableKeyPath<PetOptions, Value>) -> Binding<Value> {
        Binding(
            get: { tile.wrappedValue.petOptions[keyPath: keyPath] },
            set: { value in
                var options = tile.wrappedValue.petOptions
                options[keyPath: keyPath] = value
                tile.wrappedValue.pet = options
            }
        )
    }

    private var coat: Binding<PetCoat?> {
        Binding(
            get: { PetCoat(hex: tile.wrappedValue.petOptions.coatHex) },
            set: { coat in
                guard let coat else { return }
                option(\.coatHex).wrappedValue = coat.hex
            }
        )
    }

    private var coatColor: Binding<Color> {
        Binding(
            get: { Color(hex: tile.wrappedValue.petOptions.coat) ?? .orange },
            set: { option(\.coatHex).wrappedValue = $0.hexString }
        )
    }
}

// MARK: - On the bar

/// Pets that roam walk on the bar's top edge, in the panel's inset above it.
struct RoamingPetsLayer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let pets = model.config.tiles.filter { $0.kind == .pet && $0.petOptions.roams }
        if !pets.isEmpty {
            GeometryReader { proxy in
                // Clear of the rounded corners.
                let inset = max(8, CGFloat(model.theme.surface.cornerRadius) * 0.6)
                ForEach(Array(pets.enumerated()), id: \.element.id) { index, tile in
                    let options = tile.petOptions
                    let size = CGFloat(options.size.barPoints)
                    let height = PetFigure.frameSize(for: size).height
                    WalkingPet(
                        options: options, mood: model.pets.mood(for: tile.id), size: size,
                        walkSpeed: 22, isPaused: model.isDockHidden, seed: Double(index) * 2.3
                    )
                    .frame(width: max(0, proxy.size.width - inset * 2), height: height)
                    // Feet on the top border.
                    .offset(x: inset, y: 1.5 - height)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

// MARK: - While the dock hides

/// A click-through strip at the bottom of the screen where pets that stay
/// visible keep walking while Intellihide has the dock off-screen.
@MainActor
final class PetPeekController {
    private let model: AppModel
    private var panel: FloatingPanel?
    private var showTask: Task<Void, Never>?
    private static let height: CGFloat = 30

    init(model: AppModel) {
        self.model = model
    }

    /// `dockFrame` is the bar where it shows, in screen coordinates.
    func dockDidChange(hidden: Bool, dockFrame: CGRect, screen: NSScreen) {
        showTask?.cancel()
        let wanted = model.config.tiles.contains { $0.kind == .pet && $0.petOptions.staysVisible }
        guard hidden, wanted, dockFrame.width > 0 else {
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? makePanel()
        panel.setFrame(NSRect(x: dockFrame.minX, y: screen.frame.minY, width: dockFrame.width, height: Self.height), display: true)
        showTask = Task { [weak self] in
            // Once the dock has slid away.
            try? await Task.sleep(for: .milliseconds(260))
            guard let self, !Task.isCancelled, let panel = self.panel else { return }
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                panel.animator().alphaValue = 1
            }, completionHandler: nil)
        }
    }

    private func makePanel() -> FloatingPanel {
        let panel = FloatingPanel(level: .statusBar, allowsKey: false)
        panel.ignoresMouseEvents = true
        let host = NSHostingView(rootView: PetPeekView().environment(model))
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
        return panel
    }
}

private struct PetPeekView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let pets = model.config.tiles.filter { $0.kind == .pet && $0.petOptions.staysVisible }
        ZStack(alignment: .bottomLeading) {
            ForEach(Array(pets.enumerated()), id: \.element.id) { index, tile in
                let options = tile.petOptions
                let size = CGFloat(options.size.barPoints)
                WalkingPet(options: options, mood: model.pets.mood(for: tile.id), size: size, walkSpeed: 22, seed: Double(index) * 2.3)
                    .frame(height: PetFigure.frameSize(for: size).height)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 1)
        .environment(\.colorScheme, .dark)
    }
}

#if DEBUG
/// Snapshots only: every animal in every mood, and the coats and sizes.
struct PetGallery: View {
    var body: some View {
        let moods: [PetMood] = [.sitting, .walking, .running, .sleeping, .eating]
        VStack(alignment: .leading, spacing: 14) {
            ForEach(moods, id: \.self) { mood in
                HStack(alignment: .bottom, spacing: 10) {
                    Text(verbatim: mood.rawValue)
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 56, alignment: .leading)
                    ForEach(PetAnimal.allCases) { animal in
                        PetFigure(options: PetOptions(animal: animal), mood: mood, size: 24, time: 0.35)
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                Text(verbatim: "coats").font(.system(size: 10, weight: .semibold)).frame(width: 56, alignment: .leading)
                ForEach(PetCoat.allCases) { coat in
                    PetFigure(options: PetOptions(animal: .cat, coatHex: coat.hex), mood: .sitting, size: 24, facingRight: false)
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                Text(verbatim: "sizes").font(.system(size: 10, weight: .semibold)).frame(width: 56, alignment: .leading)
                ForEach(PetSize.allCases) { size in
                    PetFigure(options: PetOptions(animal: .dog), mood: .walking, size: CGFloat(size.barPoints), moves: false)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.35)))
    }
}
#endif
