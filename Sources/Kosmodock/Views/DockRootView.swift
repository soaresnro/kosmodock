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

/// Widest natural capsule content in a bar, so every capsule can match it.
struct CapsuleContentWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
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
    /// Group names, badge text, four mini icons.
    case regular
    /// Three mini icons stacked above the badge, no names.
    case compact
    /// Status dot and two mini icons.
    case minimal

    var miniIconLimit: Int {
        switch self {
        case .regular: 4
        case .compact: 3
        case .minimal: 2
        }
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
            DockBar(density: .regular, namespace: iconNamespace, maxWidth: maxWidth, scrolls: false)
            DockBar(density: .compact, namespace: iconNamespace, maxWidth: maxWidth, scrolls: false)
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
    let namespace: Namespace.ID
    let maxWidth: CGFloat
    let scrolls: Bool
    @ViewState private var capsuleWidth: CGFloat = 0

    var body: some View {
        let shape = CGFloat(model.theme.cornerRadius)
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
        .background(GlassBackground(cornerRadius: shape))
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: MeasuredSizeKey.self, value: proxy.size)
            }
        }
    }

    private var content: some View {
        HStack(alignment: .center, spacing: density == .minimal ? 4 : 6) {
            ForEach(model.config.groups) { group in
                GroupCapsuleView(group: group, density: density, namespace: namespace, uniformWidth: capsuleWidth)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: CapsuleFramesKey.self,
                                value: [group.id: proxy.frame(in: .named(DockSpace.name))]
                            )
                        }
                    }
            }
            if model.config.groups.isEmpty {
                EmptyDockHint()
            }
            DockUtilityButton()
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .onPreferenceChange(CapsuleContentWidthKey.self) { width in
            MainActor.assumeIsolated {
                if abs(width - capsuleWidth) > 0.5 { capsuleWidth = width }
            }
        }
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
                        RoundedRectangle(cornerRadius: max(6, CGFloat(model.theme.cornerRadius) - 9), style: .continuous)
                            .fill(Color.primary.opacity(isHovering ? 0.12 : 0.05))
                    }
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
