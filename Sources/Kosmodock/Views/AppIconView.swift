import SwiftUI

/// Real app icon, dimmed when hidden, with the running indicator under it and
/// the launch animation while the app starts.
struct AppIconView: View {
    @Environment(AppModel.self) private var model
    let app: DockApp
    let size: CGFloat
    var showsIndicator = true
    /// The group's tint, for `IndicatorColor.group`.
    var tint: Color?

    var body: some View {
        let state = model.workspace.state(for: app)
        let theme = model.theme
        Image(nsImage: model.workspace.icon(for: app))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .opacity(state?.isHidden == true ? 0.55 : 1)
            .modifier(LaunchMotion(animation: model.workspace.isLaunching(app) ? theme.launchAnimation : .none, size: size))
            .overlay(alignment: .bottom) {
                if showsIndicator, let state {
                    RunningIndicator(style: theme.indicatorStyle, color: indicatorColor(isActive: state.isActive), iconSize: size)
                }
            }
    }

    private func indicatorColor(isActive: Bool) -> Color {
        switch model.theme.indicatorColor {
        case .accent: isActive ? model.accent : Color.primary.opacity(0.8)
        case .group: (tint ?? model.accent).opacity(isActive ? 1 : 0.7)
        }
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
            AppIconView(app: app, size: size, tint: model.tint(for: group))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Magnification is the row's job (`MagnifyingRow`).
        .scaleEffect(isHovering && model.theme.hoverEffect == .scale ? 1.14 : 1, anchor: .bottom)
        .animation(model.spring, value: isHovering)
        .onHover { isHovering = $0 }
        .contextMenu { AppContextMenu(app: app, group: group) }
        .help(app.name)
    }
}

struct AppContextMenu: View {
    @Environment(AppModel.self) private var model
    let app: DockApp
    let group: DockGroup

    var body: some View {
        if model.workspace.isRunning(app) {
            Button("Focus") { model.workspace.focus(app) }
            Button("Minimize to Group") { model.minimizeToGroup(app) }
            Button("Hide") { model.workspace.hide(app) }
            Divider()
            Button("Tile Left") { model.tile(app, region: .left) }
            Button("Tile Right") { model.tile(app, region: .right) }
            Button("Maximize") { model.tile(app, region: .maximize) }
            Divider()
            Button("Quit") { model.workspace.quit(app) }
            Button("Force Quit") { model.workspace.forceQuit(app) }
        } else {
            Button("Launch") { model.open(app) }
        }
        Divider()
        Button("Show in Finder") { model.workspace.revealInFinder(app) }
        Button(L10n.tr("Remove from %@", group.name)) { model.remove(app, from: group) }
    }
}
