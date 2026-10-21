import SwiftUI

// MARK: - Settings › Workspaces

/// The workspaces, and for the selected one: its bar, what happens to other
/// apps when you switch to it, and its shortcut.
struct WorkspacesSettingsView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var selectedID: String?
    @ViewState private var confirmDelete = false
    @ViewState private var confirmSingleDock = false

    var body: some View {
        let workspaces = model.config.workspaces
        let selected = workspaces.first { $0.id == selectedID } ?? model.activeWorkspace
        Form {
            if workspaces.isEmpty {
                Section {
                    WorkspaceIntro()
                    Button("Create First Workspace") { selectedID = model.addWorkspace() }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                Section {
                    ForEach(Array(workspaces.enumerated()), id: \.element.id) { index, workspace in
                        WorkspaceRow(
                            workspace: workspace, index: index, count: workspaces.count,
                            isSelected: workspace.id == selected?.id
                        ) {
                            selectedID = workspace.id
                        }
                    }
                    .onMove { model.moveWorkspaces(fromOffsets: $0, toOffset: $1) }
                    HStack {
                        Button {
                            selectedID = model.addWorkspace()
                        } label: {
                            Label("Add Workspace", systemImage: "plus")
                        }
                        Spacer()
                        Button("Use a Single Dock…") { confirmSingleDock = true }
                    }
                } header: {
                    Text("Workspaces")
                } footer: {
                    Text("A new workspace starts as a copy of the current Dock. Switch with the shortcuts, the dots at the left end of the Dock, a two-finger swipe over it, ⌘ + scroll, or the Kosmodock menu.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let selected {
                    WorkspaceEditor(workspaceID: selected.id, index: workspaces.firstIndex(of: selected) ?? 0)
                        .id(selected.id)
                    WorkspaceItemsSection(workspaceID: selected.id)
                    Section {
                        Button("Delete Workspace…", role: .destructive) { confirmDelete = true }
                            .disabled(workspaces.count < 2)
                        if workspaces.count < 2 {
                            Text("The last workspace can't be deleted. To go back to one Dock with everything on it, use a single Dock.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Workspaces")
        .confirmationDialog(L10n.tr("Delete “%@”?", selected?.displayName ?? ""), isPresented: $confirmDelete) {
            Button("Delete Workspace", role: .destructive) {
                guard let id = selected?.id else { return }
                model.deleteWorkspace(id: id)
                selectedID = nil
            }
        } message: {
            Text("Its groups, apps and widgets stay in Kosmodock and in the other workspaces.")
        }
        .confirmationDialog("Use a single Dock?", isPresented: $confirmSingleDock) {
            Button("Use a Single Dock") {
                model.useSingleDock()
                selectedID = nil
            }
        } message: {
            Text("Workspaces are removed and the Dock shows every group, app and widget again, in this workspace's order first. Apps Kosmodock hid come back.")
        }
    }
}

private struct WorkspaceIntro: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("A Dock for each thing you do", systemImage: "rectangle.stack")
                .font(.headline)
            Text("A workspace shows only the groups, apps and widgets it needs. Switching to another one can hide or quit the apps you leave behind, and brings back the ones it hid.")
                .foregroundStyle(.secondary)
            Text("The first workspace starts as a copy of your current Dock, so nothing changes until you edit it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct WorkspaceRow: View {
    @Environment(AppModel.self) private var model
    let workspace: Workspace
    let index: Int
    let count: Int
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        let isActive = workspace.id == model.activeWorkspace?.id
        HStack(spacing: 10) {
            Circle()
                .fill(Color(hex: workspace.colorHex) ?? model.accent)
                .frame(width: 12, height: 12)
            Text(verbatim: workspace.displayName)
                .fontWeight(isSelected ? .semibold : .regular)
                .lineLimit(1)
            if isActive {
                Text("Active")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
            Spacer()
            if let shortcut = Workspace.shortcut(index: index) {
                Text(verbatim: shortcut)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }
            Group {
                Button { model.activateWorkspace(id: workspace.id) } label: { Label("Switch to This Workspace", systemImage: "arrow.right.circle") }
                    .disabled(isActive)
                    .help("Switch to This Workspace")
                Button { model.moveWorkspace(id: workspace.id, by: -1) } label: { Label("Move up", systemImage: "chevron.up") }
                    .disabled(index == 0)
                    .help("Move up")
                Button { model.moveWorkspace(id: workspace.id, by: 1) } label: { Label("Move down", systemImage: "chevron.down") }
                    .disabled(index == count - 1)
                    .help("Move down")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? model.accent.opacity(0.14) : .clear)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
    }
}

/// Name, color, shortcut and the other-apps policy of one workspace.
private struct WorkspaceEditor: View {
    @Environment(AppModel.self) private var model
    let workspaceID: String
    let index: Int

    private var workspace: Binding<Workspace> { model.workspaceBinding(id: workspaceID) }

    var body: some View {
        let current = workspace.wrappedValue
        Section {
            TextField("Name", text: nameBinding)
            LabeledContent("Color") {
                HStack(spacing: 6) {
                    ForEach(Workspace.colors, id: \.self) { hex in
                        let isChosen = current.colorHex.caseInsensitiveCompare(hex) == .orderedSame
                        Button {
                            workspace.wrappedValue.colorHex = hex
                        } label: {
                            Circle()
                                .fill(Color(hex: hex) ?? .gray)
                                .frame(width: 16, height: 16)
                                .overlay {
                                    Circle().strokeBorder(Color.primary.opacity(isChosen ? 0.8 : 0), lineWidth: 2).padding(-3)
                                }
                                .padding(3)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    ColorPicker("", selection: colorBinding, supportsOpacity: false)
                        .labelsHidden()
                }
            }
            LabeledContent("Shortcut") {
                Text(Workspace.shortcut(index: index) ?? L10n.tr("None — only the first nine workspaces have one"))
                    .foregroundStyle(.secondary)
            }
            Picker("Apps left behind", selection: workspace.otherApps) {
                ForEach(OtherWorkspaceApps.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(policySummary(current.otherApps))
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text(verbatim: current.displayName)
        }
    }

    private func policySummary(_ policy: OtherWorkspaceApps) -> String {
        switch policy {
        case .keep: L10n.tr("When you switch here, the apps of the workspace you leave stay as they are.")
        case .hide: L10n.tr("When you switch here, apps of the workspace you leave that this one doesn't have are hidden. They come back when you switch to a workspace that has them.")
        case .quit: L10n.tr("When you switch here, apps of the workspace you leave that this one doesn't have are asked to quit, as with ⌘Q, so they can still ask to save. The Finder stays open.")
        }
    }

    /// Shows a name Kosmodock gave in the interface language, and keeps it
    /// a config text until you type another.
    private var nameBinding: Binding<String> {
        Binding(
            get: { workspace.wrappedValue.displayName },
            set: { text in
                guard text != workspace.wrappedValue.displayName else { return }
                workspace.wrappedValue.name = text
            }
        )
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: workspace.wrappedValue.colorHex) ?? model.accent },
            set: { workspace.wrappedValue.colorHex = $0.hexString }
        )
    }
}

/// Every group, pinned app and tile, checked when the workspace shows it.
private struct WorkspaceItemsSection: View {
    @Environment(AppModel.self) private var model
    let workspaceID: String

    var body: some View {
        let config = model.config
        let shownIDs = config.shownItemIDs(inWorkspace: workspaceID)
        let shown = Set(shownIDs)
        let shownItems = model.barItems(for: shownIDs)
        let otherItems = model.barItems(for: config.allItemIDs.filter { !shown.contains($0) })
        Section {
            if shownItems.isEmpty {
                Text("Nothing on this workspace's Dock yet.").foregroundStyle(.secondary)
            }
            ForEach(Array(shownItems.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 8) {
                    checkbox(item, isOn: true)
                    BarItemLabel(item: item)
                    Spacer()
                    Group {
                        Button { model.moveItem(item.id, by: -1, inWorkspace: workspaceID) } label: { Label("Move up", systemImage: "chevron.up") }
                            .disabled(index == 0)
                            .help("Move up")
                        Button { model.moveItem(item.id, by: 1, inWorkspace: workspaceID) } label: { Label("Move down", systemImage: "chevron.down") }
                            .disabled(index == shownItems.count - 1)
                            .help("Move down")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                }
            }
            ForEach(otherItems) { item in
                HStack(spacing: 8) {
                    checkbox(item, isOn: false)
                    BarItemLabel(item: item).opacity(0.6)
                    Spacer()
                }
            }
        } header: {
            Text("On the Dock")
        } footer: {
            Text("Checked items are on this workspace's Dock, in this order. Add groups, apps and widgets in Settings › Dock; each one exists once, so editing it changes it in every workspace.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func checkbox(_ item: BarItem, isOn: Bool) -> some View {
        Toggle("", isOn: Binding(
            get: { isOn },
            set: { model.setItem(item.id, included: $0, inWorkspace: workspaceID) }
        ))
        .toggleStyle(.checkbox)
        .labelsHidden()
    }
}

// MARK: - Settings › Dock

/// Above Settings › Dock's list while workspaces exist: whose bar it edits.
struct WorkspaceDockHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let workspace = model.activeWorkspace {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(hex: workspace.colorHex) ?? model.accent)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.tr("Workspace “%@”", workspace.displayName))
                        .font(.headline)
                    Text("This list is the active workspace's Dock. Items only other workspaces have are listed at the end.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Workspaces…") { model.settingsSelection = .workspaces }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
        }
    }
}

/// The items the active workspace leaves out, to add back.
struct WorkspaceOtherItemsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let items = model.itemsOutsideActiveWorkspace
        if let workspace = model.activeWorkspace, !items.isEmpty {
            Section {
                ForEach(items) { item in
                    HStack(spacing: 10) {
                        BarItemLabel(item: item)
                        Spacer()
                        Button {
                            model.setItem(item.id, included: true, inWorkspace: workspace.id)
                        } label: {
                            Label("Add to This Workspace", systemImage: "plus.circle")
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Add to This Workspace")
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Not in This Workspace")
            }
        }
    }
}

/// A bar item's icon, name and kind, as Settings lists it.
struct BarItemLabel: View {
    @Environment(AppModel.self) private var model
    let item: BarItem

    var body: some View {
        HStack(spacing: 10) {
            Group {
                switch item {
                case .group(let group): GroupGlyph(symbol: group.symbol, tint: model.tint(for: group), size: 22)
                case .app(let app): AppIconView(app: app, size: 24, showsIndicator: false, badgeStyle: .hidden)
                case .tile(let tile): GroupGlyph(symbol: tile.kind.symbol, tint: model.accent, size: 22)
                case .extra(let extra): BarExtraIcon(extra: extra, size: 24)
                }
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: title).lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var title: String {
        switch item {
        case .group(let group): group.name
        case .app(let app): model.workspace.displayName(for: app)
        case .tile(let tile): tile.title
        case .extra(let extra): extra.title
        }
    }

    private var subtitle: String {
        switch item {
        case .group(let group): group.apps.count == 1 ? L10n.tr("Group · 1 app") : L10n.tr("Group · %lld apps", group.apps.count)
        case .app: L10n.tr("App")
        case .tile(let tile): L10n.tr("Widget · %@", tile.width.title)
        case .extra(let extra): extra.subtitle
        }
    }
}
