import SwiftUI

/// Real app icon with a running indicator dot (accent when frontmost, dimmed
/// when hidden).
struct AppIconView: View {
    @Environment(AppModel.self) private var model
    let app: DockApp
    let size: CGFloat
    var showsIndicator = true

    var body: some View {
        let state = model.workspace.state(for: app)
        Image(nsImage: model.workspace.icon(for: app))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .opacity(state?.isHidden == true ? 0.55 : 1)
            .overlay(alignment: .bottom) {
                if showsIndicator, let state {
                    Circle()
                        .fill(state.isActive ? model.accent : Color.primary.opacity(0.8))
                        .frame(width: max(3, size * 0.11), height: max(3, size * 0.11))
                        .offset(y: max(3, size * 0.11) + 1)
                }
            }
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
            AppIconView(app: app, size: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovering ? 1.14 : 1, anchor: .bottom)
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
