import SwiftUI

enum DockSpace {
    static let name = "kosmodock.dock"
}

struct CapsuleFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Marks the subviews `CapsuleRow` gives a common width: collapsed capsules.
struct EqualizesWidthKey: LayoutValueKey {
    static let defaultValue = false
}

/// Marks flexible spacers, which `CapsuleRow` gives the row's free width.
struct FlexibleWidthKey: LayoutValueKey {
    static let defaultValue = false
}

/// A row that gives every collapsed capsule the widest one's width, or as
/// close to it as `maxWidth` allows. A `Layout` instead of a width measured
/// into `@State`: `ViewThatFits` measures the candidates it isn't showing
/// too, and state they never render would keep an old width, leaving the
/// dock stuck at a sparser density after the content shrinks.
struct CapsuleRow: Layout {
    var spacing: CGFloat
    /// Width the row should stay within, while it can.
    var maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let widths = Self.widths(
            natural: sizes.map(\.width), equalized: subviews.map { $0[EqualizesWidthKey.self] },
            flexible: subviews.map { $0[FlexibleWidthKey.self] }, spacing: spacing, maxWidth: maxWidth
        )
        return CGSize(
            width: widths.reduce(0, +) + spacing * CGFloat(max(0, subviews.count - 1)),
            height: sizes.map(\.height).max() ?? 0
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let widths = Self.widths(
            natural: sizes.map(\.width), equalized: subviews.map { $0[EqualizesWidthKey.self] },
            flexible: subviews.map { $0[FlexibleWidthKey.self] }, spacing: spacing, maxWidth: maxWidth
        )
        // The row's height, so tiles (which fill it) match the capsules.
        let height = sizes.map(\.height).max() ?? 0
        var x = bounds.minX
        for index in subviews.indices {
            subviews[index].place(
                at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                proposal: ProposedViewSize(width: widths[index], height: height)
            )
            x += widths[index] + spacing
        }
    }

    /// Equalized subviews take a common width: the widest one's, lowered until
    /// the row fits `maxWidth`, but never below a subview's own width. Without
    /// the limit, one wide badge times every capsule would push the dock to a
    /// density that hides all badges. If even the natural widths don't fit,
    /// they're fully equalized: the row is too wide either way.
    ///
    /// `flexible` subviews (flexible spacers, never equalized) count with their
    /// own width while capsules are equalized, then share what's left of
    /// `maxWidth`, so they only take room capsules don't need.
    static func widths(natural: [CGFloat], equalized: [Bool], flexible: [Bool] = [], spacing: CGFloat, maxWidth: CGFloat) -> [CGFloat] {
        var widths = equalizedWidths(natural: natural, equalized: equalized, spacing: spacing, maxWidth: maxWidth)
        let flexes = natural.indices.filter { flexible.indices.contains($0) && flexible[$0] && !equalized[$0] }
        let free = maxWidth - widths.reduce(0, +) - spacing * CGFloat(max(0, natural.count - 1))
        guard !flexes.isEmpty, free >= 1 else { return widths }
        let share = (free / CGFloat(flexes.count)).rounded(.down)
        for index in flexes { widths[index] += share }
        return widths
    }

    private static func equalizedWidths(natural: [CGFloat], equalized: [Bool], spacing: CGFloat, maxWidth: CGFloat) -> [CGFloat] {
        let shared = natural.indices.filter { equalized[$0] }.map { natural[$0] }.sorted()
        guard var level = shared.last else { return natural }
        let fixed = natural.indices.filter { !equalized[$0] }.reduce(0) { $0 + natural[$1] }
        let budget = maxWidth - fixed - spacing * CGFloat(max(0, natural.count - 1))
        if level * CGFloat(shared.count) > budget, shared.reduce(0, +) <= budget {
            // Raise the k narrowest to `level` and keep the rest: the first k
            // whose level stays below the next width solves it.
            var rest = shared.reduce(0, +)
            for k in 1...shared.count {
                rest -= shared[k - 1]
                level = ((budget - rest) / CGFloat(k)).rounded(.down)
                if k == shared.count || level <= shared[k] { break }
            }
        }
        return natural.indices.map { equalized[$0] ? max(natural[$0], level) : natural[$0] }
    }
}

struct MeasuredSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// How much detail capsules show; the dock steps down until it fits the screen.
enum DockDensity: Int, CaseIterable, Sendable {
    /// Group names, badge text, three mini icons.
    case regular
    /// Three mini icons stacked above the badge, no names.
    case compact
    /// Status dot and two mini icons.
    case minimal

    var miniIconLimit: Int {
        switch self {
        case .regular: 3
        case .compact: 3
        case .minimal: 2
        }
    }

    /// A collapsed capsule's height: its minimum, or in compact the mini
    /// icons stacked over the badge line, plus the vertical padding. Pinned
    /// app icons take it, so they're as tall as the capsules beside them.
    func capsuleHeight(iconSize: Double) -> CGFloat {
        let minimum = CGFloat(iconSize) * 0.62 + 18
        guard self == .compact else { return minimum }
        // Mini icons (half the icon size), 5 pt spacing, a 10 pt badge line.
        return max(minimum, (CGFloat(iconSize) * 0.5 + 5 + 12.5 + 12).rounded())
    }
}

/// The dock: one glass strip holding every group capsule.
///
/// `ViewThatFits` receives a fixed proposal derived from the screen (not the
/// panel's current size, which is itself derived from this view) and picks the
/// richest density whose ideal width fits; a scrolling bar is the last resort.
struct DockRootView: View {
    @Environment(AppModel.self) private var model
    let geometry: GroupGeometryTracker
    @Namespace private var iconNamespace

    var body: some View {
        let maxWidth = model.dockMaxWidth
        ViewThatFits(in: .horizontal) {
            // Capsules give up a mini icon before wide tiles go square (they
            // were chosen wide), and tiles go square before capsules lose detail.
            DockBar(density: .regular, namespace: iconNamespace, maxWidth: maxWidth, scrolls: false)
            DockBar(density: .regular, fewerMiniIcons: true, namespace: iconNamespace, maxWidth: maxWidth, scrolls: false)
            DockBar(density: .regular, squareTiles: true, namespace: iconNamespace, maxWidth: maxWidth, scrolls: false)
            DockBar(density: .compact, namespace: iconNamespace, maxWidth: maxWidth, scrolls: false)
            DockBar(density: .compact, squareTiles: true, namespace: iconNamespace, maxWidth: maxWidth, scrolls: false)
            DockBar(density: .minimal, namespace: iconNamespace, maxWidth: maxWidth, scrolls: false)
            DockBar(density: .minimal, namespace: iconNamespace, maxWidth: maxWidth, scrolls: true)
        }
        .frame(width: maxWidth)
        .padding(DockMetrics.shadowInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .coordinateSpace(.named(DockSpace.name))
        .tint(model.accent)
        .onPreferenceChange(CapsuleFramesKey.self) { frames in
            MainActor.assumeIsolated { geometry.capsuleFrames = frames }
        }
        .onPreferenceChange(MeasuredSizeKey.self) { size in
            MainActor.assumeIsolated { geometry.reportBar(size: size) }
        }
    }
}

struct DockBar: View {
    @Environment(AppModel.self) private var model
    let density: DockDensity
    /// Wide tiles drawn square, a step before the next density.
    var squareTiles = false
    /// One mini icon less per capsule, a step before squaring tiles.
    var fewerMiniIcons = false
    let namespace: Namespace.ID
    let maxWidth: CGFloat
    let scrolls: Bool
    @Environment(\.colorScheme) private var inheritedScheme

    /// The bar's horizontal padding, which `CapsuleRow` leaves out of `maxWidth`.
    private static let padding: CGFloat = 7

    var body: some View {
        let surface = model.theme.surface
        Group {
            if scrolls {
                ScrollView(.horizontal) { content }
                    .scrollIndicators(.never)
                    .frame(width: maxWidth)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                content.fixedSize()
            }
        }
        // Seasonal decorations and roaming pets, outside the layout.
        .barLooks(surface: surface)
        .background(SurfaceBackground(surface: surface, cornerRadius: CGFloat(surface.cornerRadius)))
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: MeasuredSizeKey.self, value: proxy.size)
            }
        }
        .environment(\.colorScheme, surface.colorScheme ?? inheritedScheme)
    }

    private var content: some View {
        CapsuleRow(spacing: density == .minimal ? 4 : 6, maxWidth: maxWidth - Self.padding * 2) {
            if model.canSwitchWorkspaces {
                WorkspaceDots()
            }
            let items = model.barItems
            ForEach(items) { item in
                Group {
                    switch item {
                    case .group(let group):
                        GroupCapsuleView(
                            group: group, density: density, variant: squareTiles ? 1 : fewerMiniIcons ? 2 : 0,
                            maxMiniIcons: fewerMiniIcons ? density.miniIconLimit - 1 : nil, namespace: namespace
                        )
                    case .app(let app):
                        PinnedAppView(app: app, density: density)
                    case .tile(let tile):
                        BarTileView(tile: tile, isSquare: squareTiles || density == .minimal)
                    case .extra(let extra):
                        BarExtraView(extra: extra, density: density)
                    }
                }
                // Popovers and the minimize animation find items by these frames.
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: CapsuleFramesKey.self,
                            value: [item.id: proxy.frame(in: .named(DockSpace.name))]
                        )
                    }
                }
                .layoutValue(key: EqualizesWidthKey.self, value: model.theme.equalGroupWidths && item.equalizesWidth(expandedGroupID: model.expandedGroupID))
                .layoutValue(key: FlexibleWidthKey.self, value: item.isFlexibleSpacer)
                .keyboardFocusRing(item.id)
            }
            if items.isEmpty {
                EmptyDockHint()
            }
            DockUtilityButton()
        }
        .padding(.horizontal, Self.padding)
        .padding(.vertical, 6)
    }
}

private struct EmptyDockHint: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.openSettings(nil)
        } label: {
            Label("Add a group in Settings", systemImage: "plus.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}

/// Trailing button: Kosmodock menu plus an Accessibility warning when needed.
private struct DockUtilityButton: View {
    @Environment(AppModel.self) private var model
    @ViewState private var isHovering = false

    var body: some View {
        let untrusted = !model.windows.isTrusted
        Button {
            model.popUpMainMenu?()
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "circle.grid.2x2.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: CGFloat(model.theme.iconSize) * 0.62 + 18)
                    .background {
                        RoundedRectangle(cornerRadius: model.theme.capsuleRadius, style: .continuous)
                            .fill(Color.primary.opacity(isHovering ? 0.12 : 0.05))
                    }
                    .modifier(FloatingGlass(cornerRadius: model.theme.capsuleRadius))
                if untrusted {
                    Circle()
                        .fill(HealthLevel.warning.color)
                        .frame(width: 7, height: 7)
                        .offset(x: -5, y: 5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(untrusted ? L10n.tr("Kosmodock — Accessibility access needed for tiling") : "Kosmodock")
    }
}
