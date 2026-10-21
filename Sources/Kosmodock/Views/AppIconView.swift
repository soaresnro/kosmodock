import SwiftUI

/// Real app icon, dimmed when hidden, with the running indicator under it,
/// its notification badge, the launch animation while the app starts and,
/// on the dock, a reflection.
struct AppIconView: View {
    @Environment(AppModel.self) private var model
    let app: DockApp
    let size: CGFloat
    var showsIndicator = true
    /// The group's tint, for `IndicatorColor.group`.
    var tint: Color?
    var badgeStyle: NotificationBadge.Style = .full
    /// Draws the style's reflection (`DockSurface.reflection`). Only dock icons
    /// do: elsewhere text sits right under the icon.
    var reflects = false

    var body: some View {
        let state = model.workspace.state(for: app)
        let theme = model.theme
        let image = model.workspace.icon(for: app)
        let opacity = state?.isHidden == true ? 0.55 : 1
        icon(image)
            .opacity(opacity)
            .modifier(NotificationBadge(label: badgeStyle == .hidden ? nil : model.notificationBadge(for: app), iconSize: size, style: badgeStyle))
            .modifier(LaunchMotion(animation: model.workspace.isLaunching(app) ? theme.launchAnimation : .none, size: size))
            .background(alignment: .bottom) {
                // Behind the icon and outside its frame: the layout never changes,
                // and the indicator, an overlay, stays on top.
                if reflects, theme.surface.reflection {
                    Reflection(height: size, margin: size * Self.artworkMargin) { icon(image) }
                        .opacity(opacity)
                }
            }
            .overlay(alignment: .bottom) {
                if showsIndicator, let state {
                    RunningIndicator(style: theme.indicatorStyle, color: indicatorColor(isActive: state.isActive), iconSize: size)
                }
            }
    }

    /// App icons keep a transparent margin around their artwork (about 10% on
    /// the macOS icon grid), so the mirror line sits that far above the frame.
    private static let artworkMargin: CGFloat = 0.09

    private func icon(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }

    private func indicatorColor(isActive: Bool) -> Color {
        switch model.theme.indicatorColor {
        case .accent: isActive ? model.accent : Color.primary.opacity(0.8)
        case .group: (tint ?? model.accent).opacity(isActive ? 1 : 0.7)
        }
    }
}

/// A faded, upside-down copy of `content` for just below it: put it in a
/// bottom-aligned `background`. `margin` is the content's transparent edge;
/// the copy starts twice that above the bottom, so it mirrors the artwork's
/// edge rather than the frame's, and that part hides behind the content.
struct Reflection<Content: View>: View {
    var height: CGFloat
    var margin: CGFloat = 0
    @ViewBuilder var content: Content

    var body: some View {
        let length = height * 0.38
        let span = length + margin * 2
        content
            .frame(height: height)
            .scaleEffect(x: 1, y: -1)
            .frame(height: span, alignment: .top)
            .clipped()
            .mask {
                LinearGradient(
                    stops: [.init(color: .black, location: margin * 2 / span), .init(color: .clear, location: 1)],
                    startPoint: .top, endPoint: .bottom
                )
            }
            .opacity(0.3)
            .offset(y: length)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The mark under a running app: a dot or a short line, just below the icon.
struct RunningIndicator: View {
    var style: IndicatorStyle
    var color: Color
    var iconSize: CGFloat

    var body: some View {
        let thickness = max(3, iconSize * 0.11)
        switch style {
        case .dot:
            Circle()
                .fill(color)
                .frame(width: thickness, height: thickness)
                .offset(y: thickness + 1)
        case .line:
            Capsule()
                .fill(color)
                .frame(width: max(8, iconSize * 0.38), height: max(2, thickness * 0.7))
                .offset(y: thickness + 1)
        case .hidden:
            EmptyView()
        }
    }
}

/// The icon's motion while its app launches. Only the icon moves: the
/// indicator is drawn outside this modifier.
struct LaunchMotion: ViewModifier {
    var animation: LaunchAnimation
    var size: CGFloat

    func body(content: Content) -> some View {
        switch animation {
        case .none:
            content
        case .bounce:
            content.phaseAnimator([0.0, 1.0]) { view, height in
                view.offset(y: -size * 0.45 * height)
            } animation: { height in
                height == 1 ? .easeOut(duration: 0.26) : .easeIn(duration: 0.26)
            }
        case .pulse:
            content.phaseAnimator([1.0, 1.16]) { view, scale in
                view.scaleEffect(scale).opacity(scale > 1 ? 0.8 : 1)
            } animation: { _ in
                .easeInOut(duration: 0.42)
            }
        case .shake:
            // Three quick twists, then a rest.
            content.phaseAnimator([0.0, -1.0, 1.0, -1.0, 1.0, 0.0, 0.0]) { view, angle in
                view.rotationEffect(.degrees(9 * angle), anchor: .bottom)
            } animation: { angle in
                angle == 0 ? .linear(duration: 0.35) : .easeInOut(duration: 0.07)
            }
        }
    }
}

/// macOS-style magnification for a row of equal icons: the icon under the
/// pointer grows the most, its neighbors less, and nothing past `reach`.
struct Magnifier: Equatable {
    var size: CGFloat
    var spacing: CGFloat
    var maxScale: CGFloat
    /// Distance from the pointer, in icons, at which growth reaches zero.
    var reach: CGFloat = 2

    private var slot: CGFloat { size + spacing }

    func center(of index: Int) -> CGFloat { CGFloat(index) * slot + size / 2 }

    /// `pointer` is in the row's coordinates; `nil` means not hovering.
    func scales(count: Int, pointer: CGFloat?) -> [CGFloat] {
        (0..<count).map { index in
            guard let pointer else { return 1 }
            let distance = abs(center(of: index) - pointer) / slot / reach
            return 1 + (maxScale - 1) * max(0, 1 - distance * distance)
        }
    }

    /// Horizontal shifts that keep grown icons `spacing` apart, spreading the
    /// extra width evenly to both sides of the row.
    func offsets(scales: [CGFloat]) -> [CGFloat] {
        let extra = scales.map { size * ($0 - 1) }
        let total = extra.reduce(0, +)
        var before: CGFloat = 0
        return extra.map { grown in
            defer { before += grown }
            return before + grown / 2 - total / 2
        }
    }

    /// The most a grown row reaches past either end, which it needs as padding.
    func overflow(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let width = CGFloat(count) * slot - spacing
        return stride(from: 0, through: width, by: 1).map { pointer in
            scales(count: count, pointer: pointer).reduce(0) { $0 + size * ($1 - 1) } / 2
        }.max() ?? 0
    }
}

/// A row of icons that grow under the pointer. With `spreads`, neighbors move
/// apart and the row keeps room for that at both ends, so its layout never
/// changes while hovering; without it, icons only grow in place.
struct MagnifyingRow<Item: Identifiable, Content: View>: View {
    var items: [Item]
    /// Every item is `size` wide.
    var size: CGFloat
    var spacing: CGFloat
    /// `nil` turns magnification off.
    var maxScale: CGFloat?
    var spreads = true
    @ViewBuilder var content: (Item) -> Content
    @ViewState private var pointer: CGFloat?

    private var magnifier: Magnifier? {
        maxScale.map { Magnifier(size: size, spacing: spacing, maxScale: $0) }
    }

    var body: some View {
        let magnifier = magnifier
        let scales = magnifier?.scales(count: items.count, pointer: pointer) ?? items.map { _ in 1 }
        let offsets = spreads ? (magnifier?.offsets(scales: scales) ?? []) : []
        HStack(spacing: spacing) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                content(item)
                    .scaleEffect(scales[index], anchor: .bottom)
                    .offset(x: offsets.isEmpty ? 0 : offsets[index])
                    .zIndex(Double(scales[index]))
            }
        }
        .onContinuousHover { phase in
            guard magnifier != nil else { return }
            switch phase {
            case .active(let location):
                withAnimation(.easeOut(duration: 0.12)) { pointer = location.x }
            case .ended:
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { pointer = nil }
            }
        }
        .padding(.horizontal, spreads ? (magnifier?.overflow(count: items.count) ?? 0) : 0)
    }
}

/// Clickable icon: launches or focuses on click, full app menu on right-click.
struct AppIconButton: View {
    @Environment(AppModel.self) private var model
    let app: DockApp
    let group: DockGroup
    let size: CGFloat
    @ViewState private var isHovering = false

    var body: some View {
        Button {
            model.open(app)
        } label: {
            AppIconView(app: app, size: size, tint: model.tint(for: group), reflects: true)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Magnification is the row's job (`MagnifyingRow`).
        .scaleEffect(isHovering && model.theme.hoverEffect == .scale ? 1.14 : 1, anchor: .bottom)
        .animation(model.spring, value: isHovering)
        .onHover { isHovering = $0 }
        .appMenu(app, group: group)
        .help(app.name)
    }
}

extension BarItem {
    /// Only collapsed group capsules share a width (`CapsuleRow`).
    func equalizesWidth(expandedGroupID: String?) -> Bool {
        if case .group(let group) = self { return group.id != expandedGroupID }
        return false
    }
}

/// An app on the bar on its own, as a plain icon, like in the macOS Dock.
/// Its windows minimize into it, and clicking it restores the latest one.
struct PinnedAppView: View {
    @Environment(AppModel.self) private var model
    let app: DockApp
    var density: DockDensity = .regular
    @ViewState private var isHovering = false
    @ViewState private var isPulsing = false

    var body: some View {
        let theme = model.theme
        // As tall as a capsule; the running indicator sits in the bar's padding below.
        let size = density.capsuleHeight(iconSize: theme.iconSize)
        let itemID = DockConfig.itemID(forPinned: app)
        let minimized = model.minimizedWindows.count(in: itemID)
        let hoverScale: CGFloat = switch theme.hoverEffect {
        case .none: 1
        case .scale: 1.14
        case .magnify: 1.3
        }
        Button {
            model.open(app)
        } label: {
            AppIconView(app: app, size: size, reflects: true)
                .overlay(alignment: .bottomTrailing) {
                    if minimized > 0 {
                        MinimizedBadge(count: minimized)
                            .offset(x: 5, y: 3)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovering ? hoverScale : 1, anchor: .bottom)
        .scaleEffect(isPulsing ? 1.16 : 1, anchor: .bottom)
        .animation(model.spring, value: isHovering)
        .animation(model.spring, value: minimized)
        .onHover { isHovering = $0 }
        .onChange(of: model.pulseTokens[itemID] ?? 0) { _, _ in pulse() }
        .appMenu(app, group: nil)
        .accessibilityLabel(model.workspace.displayName(for: app))
        .help(model.workspace.displayName(for: app))
    }

    /// A window just minimized into this icon.
    private func pulse() {
        withAnimation(.spring(response: 0.16, dampingFraction: 0.55)) { isPulsing = true }
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            withAnimation(.spring(response: 0.38, dampingFraction: 0.5)) { isPulsing = false }
        }
    }
}
