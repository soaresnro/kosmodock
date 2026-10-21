import SwiftUI

/// One dot per workspace at the bar's leading edge, in columns of three; the
/// active one is larger and ringed, and a click switches. Its size depends
/// only on the number of workspaces, and `CapsuleRow` counts it as an item
/// that keeps its own width.
struct WorkspaceDots: View {
    @Environment(AppModel.self) private var model

    private static let rows = 3
    private static let cell: CGFloat = 10

    var body: some View {
        let workspaces = model.config.workspaces
        let activeID = model.activeWorkspace?.id
        let columns = (workspaces.count + Self.rows - 1) / Self.rows
        HStack(alignment: .top, spacing: 1) {
            ForEach(0..<columns, id: \.self) { column in
                VStack(spacing: 0) {
                    ForEach(column * Self.rows ..< min(workspaces.count, (column + 1) * Self.rows), id: \.self) { index in
                        WorkspaceDot(workspace: workspaces[index], index: index, isActive: workspaces[index].id == activeID)
                            .frame(width: Self.cell, height: Self.cell)
                    }
                }
            }
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 2)
        .modifier(FloatingGlass(cornerRadius: model.theme.capsuleRadius))
        .contextMenu {
            Button("Edit Workspaces…") { model.openSettings(.workspaces) }
        }
    }
}

private struct WorkspaceDot: View {
    @Environment(AppModel.self) private var model
    let workspace: Workspace
    let index: Int
    let isActive: Bool
    @ViewState private var isHovering = false

    var body: some View {
        let color = Color(hex: workspace.colorHex) ?? model.accent
        let name = workspace.displayName
        Button {
            model.activateWorkspace(id: workspace.id)
        } label: {
            ZStack {
                if isActive {
                    Circle().strokeBorder(color.opacity(0.7), lineWidth: 1)
                }
                Circle()
                    .fill(color.opacity(isActive ? 1 : 0.5))
                    .frame(width: isActive ? 5 : 6, height: isActive ? 5 : 6)
            }
            .scaleEffect(isHovering && !isActive ? 1.3 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
        .help([name, Workspace.shortcut(index: index)].compactMap { $0 }.joined(separator: "  "))
        .accessibilityLabel(Text(verbatim: name))
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}
