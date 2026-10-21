import SwiftUI

/// Root of the popover panel: measures the Bento card and animates it in and
/// out from the capsule it belongs to.
struct PopoverRootView: View {
    @Environment(AppModel.self) private var model
    let state: PopoverState

    var body: some View {
        ZStack {
            if let id = state.itemID, model.group(id: id) != nil || model.tile(itemID: id) != nil {
                Group {
                    if let tile = model.tile(itemID: id) {
                        TilePopoverView(tileID: tile.id)
                    } else {
                        BentoPopoverView(groupID: id)
                    }
                }
                    .fixedSize()
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: MeasuredSizeKey.self, value: proxy.size)
                        }
                    }
                    .scaleEffect(state.isPresented ? 1 : 0.92, anchor: UnitPoint(x: state.anchorX, y: 1))
                    .opacity(state.isPresented ? 1 : 0)
                    .offset(y: state.isPresented ? 0 : 10)
            }
        }
        .padding(DockMetrics.shadowInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(model.spring, value: state.isPresented)
        .onPreferenceChange(MeasuredSizeKey.self) { size in
            MainActor.assumeIsolated { state.reportSize(size) }
        }
    }
}

struct BentoPopoverView: View {
    @Environment(AppModel.self) private var model
    let groupID: String

    var body: some View {
        if let group = model.group(id: groupID) {
            VStack(alignment: .leading, spacing: 12) {
                PopoverHeader(group: group)
                LayoutPillRow(group: group)
                if !model.windows.isTrusted {
                    AccessibilityBanner()
                }
                AppGridSection(group: group)
                MinimizedWindowsSection(group: group)
                TelemetrySection(group: group)
            }
            .padding(16)
            .frame(width: DockMetrics.popoverWidth)
            .background(SurfaceBackground(surface: model.theme.popoverSurface, cornerRadius: CGFloat(model.theme.popoverSurface.cornerRadius) + 4))
            .tint(model.tint(for: group))
        }
    }
}

// MARK: - Header

private struct PopoverHeader: View {
    @Environment(AppModel.self) private var model
    let group: DockGroup

    var body: some View {
        let tint = model.tint(for: group)
        HStack(spacing: 12) {
            GroupGlyph(symbol: group.symbol, tint: tint, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(group.name)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .layoutPriority(-1)
            Spacer(minLength: 8)
            IconButton(symbol: "gearshape", help: L10n.tr("Edit Group…"), size: 28) {
                model.openSettings(.group(group.id))
            }
            IconButton(symbol: "play.fill", help: L10n.tr("Launch All — open every app in the group"), size: 28) {
                model.launchAll(group)
            }
            Button {
                model.launchAndTile(group)
            } label: {
                Label("Launch & Tile", systemImage: "rectangle.3.group.fill")
                    .lineLimit(1)
                    .fixedSize()
            }
            .buttonStyle(GlassPillButtonStyle(tint: tint, prominent: true))
            .help(L10n.tr("Launch, unhide and tile using %@", group.layout.title))
        }
    }

    private var subtitle: String {
        let running = group.apps.filter { model.workspace.isRunning($0) }.count
        var parts = [L10n.tr("%lld of %lld running", running, group.apps.count)]
        let usage = model.usage(for: group)
        if usage.processCount > 0 {
            parts.append(Format.bytes(usage.memoryBytes))
            if usage.cpuPercent >= 0.05 { parts.append(L10n.tr("%@ CPU", Format.percent(usage.cpuPercent))) }
        }
        return parts.joined(separator: " · ")
    }
}

private struct LayoutPillRow: View {
    @Environment(AppModel.self) private var model
    let group: DockGroup

    var body: some View {
        // Longer languages (e.g. "Cuadrícula", "Concentración") drop the
        // Focus pill's label rather than wrapping or overflowing.
        ViewThatFits(in: .horizontal) {
            row(showsFocusLabel: true)
            row(showsFocusLabel: false)
        }
    }

    private func row(showsFocusLabel: Bool) -> some View {
        let tint = model.tint(for: group)
        return HStack(spacing: 5) {
            ForEach(TilingLayout.allCases) { layout in
                LayoutPill(layout: layout, isSelected: group.layout == layout, tint: tint) {
                    model.selectLayout(layout, for: group)
                }
            }
            Spacer(minLength: 4)
            FocusModePill(tint: tint, showsLabel: showsFocusLabel)
        }
    }
}

private struct LayoutPill: View {
    let layout: TilingLayout
    let isSelected: Bool
    let tint: Color
    let action: () -> Void
    @ViewState private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                LayoutGlyph(layout: layout)
                    .frame(width: 15, height: 10)
                Text(layout.shortTitle)
            }
            .lineLimit(1)
            .fixedSize()
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.secondary))
            .background {
                Capsule().fill(isSelected ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Color.primary.opacity(isHovering ? 0.11 : 0.05)))
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(L10n.tr("%@ — selecting re-tiles running apps", layout.title))
    }
}

private struct FocusModePill: View {
    @Environment(AppModel.self) private var model
    let tint: Color
    var showsLabel = true

    var body: some View {
        let enabled = model.config.behavior.focusMode
        Button {
            model.configService.update { $0.behavior.focusMode.toggle() }
        } label: {
            Label(L10n.tr("Focus mode (short)"), systemImage: enabled ? "eye.slash.fill" : "eye")
                .labelStyle(FocusPillLabelStyle(showsTitle: showsLabel))
                .lineLimit(1)
                .fixedSize()
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .foregroundStyle(enabled ? AnyShapeStyle(tint) : AnyShapeStyle(Color.secondary))
                .background {
                    Capsule().strokeBorder(enabled ? tint.opacity(0.8) : Color.primary.opacity(0.12), lineWidth: 1)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Focus Mode: Launch & Tile hides every app outside this group")
    }
}

private struct FocusPillLabelStyle: LabelStyle {
    let showsTitle: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            if showsTitle { configuration.title }
        }
    }
}

private struct AccessibilityBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(HealthLevel.warning.color)
            VStack(alignment: .leading, spacing: 2) {
                Text("Window tiling needs Accessibility access")
                    .font(.system(size: 11.5, weight: .semibold))
                Text("Privacy & Security → Accessibility. Already on? Remove Kosmodock with − and add it again.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Button("Grant Access") { model.windows.requestAccess() }
                .buttonStyle(GlassPillButtonStyle(tint: HealthLevel.warning.color, prominent: true))
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(HealthLevel.warning.color.opacity(0.12))
        }
    }
}

// MARK: - App grid

private struct AppGridSection: View {
    @Environment(AppModel.self) private var model
    let group: DockGroup
    private let columns = 5

    var body: some View {
        if group.apps.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "square.dashed")
                Text("No apps yet — add some in Settings.")
                Spacer()
                Button("Edit Group…") { model.openSettings(.group(group.id)) }
                    .buttonStyle(GlassPillButtonStyle(tint: model.tint(for: group)))
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(10)
        } else {
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(rows, id: \.first?.id) { row in
                    GridRow {
                        ForEach(row) { app in
                            AppTile(app: app, group: group)
                        }
                        ForEach(0..<(columns - row.count), id: \.self) { _ in
                            Color.clear.frame(height: 1)
                        }
                    }
                }
            }
        }
    }

    private var rows: [[DockApp]] {
        stride(from: 0, to: group.apps.count, by: columns).map {
            Array(group.apps[$0..<min($0 + columns, group.apps.count)])
        }
    }
}

private struct AppTile: View {
    @Environment(AppModel.self) private var model
    let app: DockApp
    let group: DockGroup
    @ViewState private var isHovering = false

    var body: some View {
        let running = model.workspace.isRunning(app)
        let tint = model.tint(for: group)
        Button {
            model.open(app)
        } label: {
            VStack(spacing: 5) {
                AppIconView(app: app, size: 42, tint: tint)
                    .scaleEffect(isHovering && model.theme.hoverEffect == .magnify ? 1.18 : 1, anchor: .bottom)
                    .overlay(alignment: .topTrailing) {
                        let minimized = model.workspace.bundleID(for: app)
                            .map { model.minimizedWindows.windows(forBundleID: $0).count } ?? 0
                        if minimized > 0 {
                            MinimizedBadge(count: minimized).offset(x: 6, y: -4)
                        }
                    }
                    .padding(.bottom, 2)
                Text(model.workspace.displayName(for: app))
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Group {
                    if running, let usage = model.usage(for: app) {
                        Text(Format.bytes(usage.memoryBytes))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(tint.opacity(0.22)))
                    } else {
                        Text(running ? L10n.tr("Running") : L10n.tr("Not running"))
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 1.5)
                    }
                }
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .monospacedDigit()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.10 : 0.045))
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovering && model.theme.hoverEffect == .scale ? 1.03 : 1)
        .animation(model.spring, value: isHovering)
        .onHover { isHovering = $0 }
        .contextMenu { AppContextMenu(app: app, group: group) }
        .help(running ? L10n.tr("Focus %@", model.workspace.displayName(for: app)) : L10n.tr("Launch %@", model.workspace.displayName(for: app)))
    }
}

// MARK: - Minimized windows

/// Windows minimized into this group; clicking one plays the reverse
/// animation (capsule → window) and restores it.
private struct MinimizedWindowsSection: View {
    @Environment(AppModel.self) private var model
    let group: DockGroup

    var body: some View {
        let items = model.minimizedWindows.windows(in: group.id)
        if !items.isEmpty {
            BentoCard(title: L10n.tr("Minimized Windows"), symbol: "rectangle.stack.fill") {
                VStack(spacing: 5) {
                    ForEach(items) { window in
                        MinimizedWindowRow(window: window)
                    }
                }
            } accessory: {
                Button("Restore All") { model.restoreAll(in: group) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(model.tint(for: group))
            }
        }
    }
}

private struct MinimizedWindowRow: View {
    @Environment(AppModel.self) private var model
    let window: MinimizedWindow
    @ViewState private var isHovering = false

    var body: some View {
        let app = DockApp(name: appName, bundleId: window.bundleID)
        Button {
            model.restore(window)
        } label: {
            HStack(spacing: 9) {
                AppIconView(app: app, size: 22, showsIndicator: false)
                VStack(alignment: .leading, spacing: 1) {
                    Text(window.title.isEmpty ? appName : window.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 4) {
                        Text(appName)
                        if window.minimizedAt > .distantPast {
                            Text(verbatim: "·")
                            Text(window.minimizedAt, style: .relative)
                        }
                    }
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 6)
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isHovering ? AnyShapeStyle(model.tint(for: model.group(id: window.groupID) ?? DockGroup(id: "", name: ""))) : AnyShapeStyle(Color.secondary))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.10 : 0.045))
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(L10n.tr("Restore “%@”", window.title.isEmpty ? appName : window.title))
    }

    private var appName: String {
        model.workspace.displayName(for: DockApp(name: window.bundleID, bundleId: window.bundleID))
    }
}
