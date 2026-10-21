import SwiftUI

/// A group on the dock. Collapsed it shows the group glyph, live telemetry
/// badge and mini app icons; in accordion mode it expands inline, morphing the
/// mini icons into full-size launchers with `matchedGeometryEffect`.
struct GroupCapsuleView: View {
    @Environment(AppModel.self) private var model
    let group: DockGroup
    var density: DockDensity = .regular
    /// Tells apart `ViewThatFits` candidates with the same density.
    var variant = 0
    /// Fewer mini icons than the density shows.
    var maxMiniIcons: Int?
    let namespace: Namespace.ID
    @ViewState private var isHovering = false
    @ViewState private var isPulsing = false

    private var miniIconLimit: Int { maxMiniIcons ?? density.miniIconLimit }
    private var showsLabel: Bool { density == .regular && model.theme.showGroupLabels }

    private var isExpanded: Bool { model.expandedGroupID == group.id }
    private var isHighlighted: Bool { isExpanded || model.popoverItemID == group.id }

    var body: some View {
        let theme = model.theme
        let tint = model.tint(for: group)
        let iconSize = CGFloat(theme.iconSize)
        let radius = theme.capsuleRadius
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        HStack(spacing: density == .minimal ? 6 : 10) {
            if density == .compact, !isExpanded {
                compactStack(tint: tint, iconSize: iconSize)
            } else {
                header(tint: tint)
                if isExpanded {
                    expandedApps(iconSize: iconSize, tint: tint)
                } else {
                    collapsedApps(iconSize: iconSize * 0.62)
                }
            }
        }
        // Collapsed, fill the width `CapsuleRow` proposes, so capsules match.
        .frame(maxWidth: isExpanded ? nil : .infinity, alignment: .leading)
        .padding(.leading, 7)
        .padding(.trailing, density == .minimal ? 7 : 10)
        .padding(.vertical, 6)
        .frame(minHeight: (isExpanded ? iconSize : iconSize * 0.62) + 18)
        .background {
            shape.fill(tint.opacity(isHighlighted ? 0.24 : (isHovering ? 0.16 : 0.09)))
        }
        .overlay {
            shape.strokeBorder(tint.opacity(isHighlighted ? 0.55 : 0.18), lineWidth: isHighlighted ? 1 : 0.5)
        }
        .modifier(FloatingGlass(cornerRadius: radius))
        .contentShape(shape)
        .onTapGesture { model.tap(group) }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
        }
        .scaleEffect(isHovering && !isExpanded && theme.hoverEffect != .none ? 1.025 : 1, anchor: .bottom)
        .scaleEffect(isPulsing ? 1.12 : 1, anchor: .bottom)
        .onChange(of: model.pulseTokens[group.id] ?? 0) { _, _ in pulse() }
        .contextMenu { GroupContextMenu(group: group) }
        .help(group.name)
    }

    /// A window just landed in this group: a quick squash-and-settle bounce.
    private func pulse() {
        withAnimation(.spring(response: 0.16, dampingFraction: 0.55)) { isPulsing = true }
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            withAnimation(.spring(response: 0.38, dampingFraction: 0.5)) { isPulsing = false }
        }
    }

    /// Group glyph with the minimized-windows counter in its corner.
    private func glyph(tint: Color) -> some View {
        let minimized = model.minimizedWindows.count(in: group.id)
        return GroupGlyph(symbol: group.symbol, tint: tint, size: 26)
            .overlay(alignment: .bottomTrailing) {
                if minimized > 0 {
                    MinimizedBadge(count: minimized)
                        .offset(x: 6, y: 5)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(model.spring, value: minimized)
            .help(minimized > 0 ? (minimized == 1 ? L10n.tr("1 minimized window") : L10n.tr("%lld minimized windows", minimized)) : group.name)
    }

    @ViewBuilder
    private func header(tint: Color) -> some View {
        let badge = model.badge(for: group)
        HStack(spacing: 8) {
            glyph(tint: tint)
                .overlay(alignment: .topTrailing) {
                    if density == .minimal, let level = badge?.level {
                        StatusDot(level: level, size: 7)
                            .overlay(Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 0.5))
                            .offset(x: 2, y: -2)
                    }
                }
            if density != .minimal, showsLabel || badge != nil {
                VStack(alignment: .leading, spacing: 1) {
                    if showsLabel {
                        Text(group.name)
                            .font(.system(size: 11.5, weight: .semibold))
                            .lineLimit(1)
                    }
                    if let badge {
                        BadgeView(badge: badge)
                    }
                }
                .fixedSize()
            }
        }
    }

    /// Compact density: mini icons stacked above the badge, so the live
    /// telemetry survives on narrow screens at the same capsule height.
    private func compactStack(tint: Color, iconSize: CGFloat) -> some View {
        HStack(spacing: 8) {
            glyph(tint: tint)
            VStack(alignment: .leading, spacing: 5) {
                collapsedApps(iconSize: iconSize * 0.5)
                if let badge = model.badge(for: group) {
                    BadgeView(badge: badge)
                }
            }
            .fixedSize()
        }
    }

    private func collapsedApps(iconSize: CGFloat) -> some View {
        HStack(spacing: 3) {
            // Grow in place only: spreading would widen the capsule, and with
            // it every capsule (`CapsuleRow`).
            MagnifyingRow(
                items: Array(group.apps.prefix(miniIconLimit)), size: iconSize, spacing: 3,
                maxScale: model.theme.hoverEffect == .magnify ? 1.3 : nil, spreads: false
            ) { app in
                // In compact density the badge sits right under the icons.
                AppIconView(app: app, size: iconSize, tint: model.tint(for: group), badgeStyle: .dot, reflects: density != .compact)
                    .matchedGeometryEffect(id: iconID(app), in: namespace)
            }
            if group.apps.count > miniIconLimit {
                Text(verbatim: "+\(group.apps.count - miniIconLimit)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }
        }
    }

    private func expandedApps(iconSize: CGFloat, tint: Color) -> some View {
        HStack(spacing: 6) {
            // The expanded capsule keeps its own width, so its row can spread.
            MagnifyingRow(
                items: group.apps, size: iconSize, spacing: 6,
                maxScale: model.theme.hoverEffect == .magnify ? 1.5 : nil
            ) { app in
                AppIconButton(app: app, group: group, size: iconSize)
                    .matchedGeometryEffect(id: iconID(app), in: namespace)
            }
            Divider()
                .frame(height: iconSize * 0.7)
                .padding(.horizontal, 2)
            VStack(spacing: 4) {
                IconButton(symbol: "rectangle.3.group.fill", help: L10n.tr("Launch & Tile (%@)", group.layout.title), size: 22) {
                    model.launchAndTile(group)
                }
                IconButton(symbol: "square.grid.2x2", help: L10n.tr("Details"), size: 22) {
                    model.showDetails(group)
                }
            }
        }
        .transition(.opacity)
    }

    /// Density and variant are part of the id: `ViewThatFits` keeps every
    /// candidate bar in the graph, and matched-geometry ids must be unique
    /// among them.
    private func iconID(_ app: DockApp) -> String {
        "\(density.rawValue).\(variant)/\(group.id)/\(app.id)"
    }
}

struct GroupContextMenu: View {
    @Environment(AppModel.self) private var model
    let group: DockGroup

    var body: some View {
        Button("Launch & Tile") { model.launchAndTile(group) }
        Button("Launch All") { model.launchAll(group) }
        Button("Show Details") { model.showDetails(group) }
        Menu("Layout") {
            ForEach(TilingLayout.allCases) { layout in
                Button {
                    model.selectLayout(layout, for: group)
                } label: {
                    if group.layout == layout {
                        Label(layout.title, systemImage: "checkmark")
                    } else {
                        Text(layout.title)
                    }
                }
            }
        }
        Divider()
        Button("Edit Group…") { model.openSettings(.group(group.id)) }
    }
}

/// Counter of windows minimized into a group or app.
struct MinimizedBadge: View {
    let count: Int

    var body: some View {
        HStack(spacing: 1.5) {
            Image(systemName: "rectangle.stack.fill")
                .font(.system(size: 6.5, weight: .bold))
            Text(verbatim: "\(count)")
                .font(.system(size: 8, weight: .heavy, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 3.5)
        .padding(.vertical, 1.5)
        .background(Capsule().fill(Color.black.opacity(0.72)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5))
        .fixedSize()
    }
}
