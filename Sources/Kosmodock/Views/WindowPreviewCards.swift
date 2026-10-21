import SwiftUI

// MARK: - Hover hook

extension View {
    /// Shows the app's window cards after the pointer rests on it
    /// (`WindowPreviewController`). For full-size icons: the dock's pinned
    /// apps, the accordion row and the Bento tiles.
    func windowPreviews(for app: DockApp) -> some View {
        modifier(WindowPreviewHover(app: app))
    }
}

/// The icon's frame in its window, kept without re-rendering on every move.
private final class FrameBox {
    var rect: CGRect = .zero
}

private struct WindowPreviewHover: ViewModifier {
    @Environment(AppModel.self) private var model
    let app: DockApp
    @ViewState private var frame = FrameBox()

    func body(content: Content) -> some View {
        let box = frame
        content
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { rect in
                box.rect = rect
            }
            .onHover { hovering in
                model.windowPreviewHover?(app, box.rect, hovering)
            }
    }
}

// MARK: - Cards panel

struct WindowPreviewHost: View {
    let model: AppModel
    let state: WindowPreviewState

    var body: some View {
        WindowPreviewRootView(state: state)
            .environment(model)
            .environment(\.locale, model.locale)
            .id(model.language)
    }
}

/// Root of the cards panel: the cards sit at its bottom, over the icon.
struct WindowPreviewRootView: View {
    @Environment(AppModel.self) private var model
    let state: WindowPreviewState

    var body: some View {
        ZStack {
            if let app = state.app, !state.cards.isEmpty {
                WindowPreviewCardsView(app: app, cards: state.cards, columns: state.columns, thumbnails: state.thumbnails) { card in
                    state.onSelect?(card)
                }
                .onHover { state.onHover?($0) }
                .scaleEffect(state.isPresented ? 1 : 0.96, anchor: .bottom)
                .opacity(state.isPresented ? 1 : 0)
                .offset(y: state.isPresented ? 0 : 6)
            }
        }
        .padding([.horizontal, .top], DockMetrics.shadowInset)
        .padding(.bottom, WindowPreviewMetrics.bottomInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.easeOut(duration: 0.16), value: state.isPresented)
    }
}

/// The app's name, then a card per window, in rows of `columns`. Every part
/// has a fixed size (`WindowPreviewMetrics`), so the panel can be placed
/// before it's drawn.
struct WindowPreviewCardsView: View {
    @Environment(AppModel.self) private var model
    let app: DockApp
    let cards: [WindowPreviewCard]
    let columns: Int
    let thumbnails: [String: NSImage]
    var onSelect: (WindowPreviewCard) -> Void

    var body: some View {
        let size = WindowPreviewMetrics.contentSize(count: cards.count, columns: columns)
        let surface = model.theme.popoverSurface
        VStack(alignment: .leading, spacing: WindowPreviewMetrics.spacing) {
            HStack(spacing: 6) {
                Text(model.workspace.displayName(for: app))
                    .font(.system(size: 11, weight: .bold))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(cards.count == 1 ? L10n.tr("1 window") : L10n.tr("%lld windows", cards.count))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 3)
            .frame(height: WindowPreviewMetrics.headerHeight)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: WindowPreviewMetrics.spacing) {
                    ForEach(row) { card in
                        WindowPreviewCardView(app: app, card: card, thumbnail: thumbnails[card.id]) { onSelect(card) }
                    }
                }
            }
        }
        .padding(WindowPreviewMetrics.padding)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        // A shorter shadow, to fit the small margin under the cards.
        .background(SurfaceBackground(surface: surface, cornerRadius: CGFloat(surface.cornerRadius) + 2, scale: 0.7))
        .tint(model.accent)
    }

    private var rows: [[WindowPreviewCard]] {
        let columns = max(1, columns)
        return stride(from: 0, to: cards.count, by: columns).map { Array(cards[$0..<min($0 + columns, cards.count)]) }
    }

    #if DEBUG
    /// Snapshot rendering only: three windows, one minimized, no thumbnails.
    static func sample(app: DockApp) -> WindowPreviewCardsView {
        let titles = ["Kosmodock – WindowPreviews.swift", "Pull Request #42", "Release notes"]
        let cards = titles.enumerated().map { index, title in
            WindowPreviewCard(
                window: AXWindowSnapshot(
                    ref: AXElementRef(AXUIElementCreateApplication(pid_t(91_000 + index))), pid: pid_t(91_000 + index),
                    title: title, frame: CGRect(x: 0, y: 0, width: 1200, height: 800)
                ),
                isMinimized: index == 2
            )
        }
        return WindowPreviewCardsView(app: app, cards: cards, columns: 3, thumbnails: [:]) { _ in }
    }
    #endif
}

private struct WindowPreviewCardView: View {
    @Environment(AppModel.self) private var model
    let app: DockApp
    let card: WindowPreviewCard
    let thumbnail: NSImage?
    var onSelect: () -> Void
    @ViewState private var isHovering = false

    var body: some View {
        let title = card.window.title.isEmpty ? model.workspace.displayName(for: app) : card.window.title
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        Button(action: onSelect) {
            VStack(spacing: WindowPreviewMetrics.titleSpacing) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                            .padding(4)
                    } else {
                        Image(nsImage: model.workspace.icon(for: app))
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 54, height: 54)
                    }
                }
                .frame(width: WindowPreviewMetrics.thumbnail.width, height: WindowPreviewMetrics.thumbnail.height)
                HStack(spacing: 4) {
                    if card.isMinimized {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    Text(title)
                        .font(.system(size: 10.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(width: WindowPreviewMetrics.thumbnail.width, height: WindowPreviewMetrics.titleHeight)
            }
            .padding(WindowPreviewMetrics.cardPadding)
            .background(shape.fill(Color.primary.opacity(isHovering ? 0.12 : 0.04)))
            .overlay(shape.strokeBorder(model.accent.opacity(isHovering ? 0.65 : 0), lineWidth: 1))
            // Minimized windows are dimmed; a click restores them.
            .opacity(card.isMinimized ? (isHovering ? 0.8 : 0.55) : 1)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help(card.isMinimized ? L10n.tr("Restore “%@”", title) : L10n.tr("Show “%@”", title))
        .accessibilityLabel(title)
    }
}

// MARK: - Settings

/// Settings › Behavior: window previews.
struct WindowPreviewSettingsSection: View {
    @Environment(AppModel.self) private var model
    @ViewState private var screenRecording = ScreenRecordingAccess.isGranted

    var body: some View {
        let behavior = model.config.behavior
        Section {
            Toggle(isOn: model.binding(\.behavior.showsWindowPreviews)) {
                Text("Show window previews")
                Text("Resting the pointer on a running app's icon shows its windows above it. Click one to bring it to the front; minimized windows are dimmed and come back when clicked.")
            }
            .onAppear { screenRecording = ScreenRecordingAccess.isGranted }
            LabeledContent("Delay") {
                HStack(spacing: 10) {
                    Slider(value: model.binding(\.behavior.windowPreviewDelay), in: WindowPreviewRules.delayRange, step: 0.1)
                    Text(String(format: "%.1f s", locale: L10n.locale, behavior.windowPreviewDelay))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .trailing)
                }
                .frame(minWidth: 240)
            }
            .disabled(!behavior.showsWindowPreviews)
            Toggle("Only for apps with 2 or more windows", isOn: model.binding(\.behavior.windowPreviewsNeedTwoWindows))
                .disabled(!behavior.showsWindowPreviews)
            if behavior.showsWindowPreviews, !model.windows.isTrusted {
                Label("Needs Accessibility access (Permissions)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(HealthLevel.warning.color)
                    .font(.caption)
            } else if behavior.showsWindowPreviews, !screenRecording {
                Label("Thumbnails need Screen Recording (Permissions). Until then the cards show the app's icon.", systemImage: "rectangle.dashed")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        } header: {
            Text("Window Previews")
        }
    }
}

/// Settings › Permissions: Screen Recording, for the previews' thumbnails.
struct ScreenRecordingPermissionSection: View {
    @ViewState private var granted = ScreenRecordingAccess.isGranted
    @ViewState private var hasRequested = false

    var body: some View {
        Section("Screen Recording") {
            HStack(spacing: 12) {
                Image(systemName: granted ? "checkmark.seal.fill" : "rectangle.dashed")
                    .font(.system(size: 26))
                    .foregroundStyle(granted ? HealthLevel.ok.color : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(granted ? L10n.tr("Screen Recording access granted") : L10n.tr("Screen Recording not allowed"))
                        .font(.headline)
                    Text("Optional. Window previews show a thumbnail of each window. Kosmodock captures a window only while you rest the pointer on its app's icon, keeps the picture for a few seconds in memory and never captures its own windows. Without it, the previews show the app's icon and the window titles.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            // macOS sends no notification when the permission changes.
            .task {
                while !Task.isCancelled {
                    granted = ScreenRecordingAccess.isGranted
                    try? await Task.sleep(for: .seconds(2))
                }
            }
            if !granted {
                HStack {
                    Button("Request Access") {
                        // The system prompt shows once; after that, the pane.
                        if hasRequested {
                            ScreenRecordingAccess.openSettings()
                        } else {
                            granted = ScreenRecordingAccess.request()
                        }
                        hasRequested = true
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Open System Settings") { ScreenRecordingAccess.openSettings() }
                }
                Text("After you switch it on, macOS may ask you to quit and reopen Kosmodock.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
