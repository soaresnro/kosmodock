import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SettingsSidebar(selection: $model.settingsSelection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            detail
                .frame(minWidth: 560, minHeight: 520)
        }
        .tint(model.accent)
    }

    @ViewBuilder
    private var detail: some View {
        switch model.settingsSelection {
        case .group(let id):
            if model.group(id: id) != nil {
                GroupEditorView(groupID: id).id(id)
            } else {
                ContentUnavailableView("Select a group", systemImage: "square.stack.3d.up")
            }
        case .dock: DockLayoutSettingsView()
        case .appearance: AppearanceSettingsView()
        case .tiles: TilesSettingsView()
        case .behavior: BehaviorSettingsView()
        case .telemetry: TelemetrySettingsView()
        case .permissions: PermissionsSettingsView()
        case .config, .none: ConfigFileSettingsView()
        }
    }
}

// MARK: - Sidebar

private struct SettingsSidebar: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SettingsSection?

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("Dock", systemImage: "dock.rectangle").tag(SettingsSection.dock)
            }
            Section("Dock Groups") {
                ForEach(model.orderedGroups) { group in
                    Label {
                        Text(group.name)
                    } icon: {
                        Image(systemName: group.symbol).foregroundStyle(model.tint(for: group))
                    }
                    .tag(SettingsSection.group(group.id))
                }
                .onMove { model.moveGroups(fromOffsets: $0, toOffset: $1) }
            }
            Section("Preferences") {
                Label("Appearance", systemImage: "paintbrush.fill").tag(SettingsSection.appearance)
                Label("Widgets", systemImage: "square.grid.2x2.fill").tag(SettingsSection.tiles)
                Label("Behavior", systemImage: "slider.horizontal.3").tag(SettingsSection.behavior)
                Label("Telemetry", systemImage: "waveform.path.ecg").tag(SettingsSection.telemetry)
                Label("Permissions", systemImage: "lock.shield").tag(SettingsSection.permissions)
                Label("Config File", systemImage: "doc.text").tag(SettingsSection.config)
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 4) {
                Button {
                    selection = .group(model.addGroup())
                } label: {
                    Image(systemName: "plus").frame(width: 22, height: 22)
                }
                .help("Add group")
                Button {
                    if case .group(let id) = selection { model.deleteGroup(id: id) }
                } label: {
                    Image(systemName: "minus").frame(width: 22, height: 22)
                }
                .disabled(!isGroupSelected)
                .help("Delete selected group")
                Spacer()
                Text("Drag to reorder")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    private var isGroupSelected: Bool {
        if case .group = selection { return true }
        return false
    }
}

// MARK: - Group editor

private struct GroupEditorView: View {
    @Environment(AppModel.self) private var model
    let groupID: String
    @ViewState private var portsText = ""
    @ViewState private var confirmDelete = false

    private var group: Binding<DockGroup> { model.groupBinding(id: groupID) }

    var body: some View {
        let current = group.wrappedValue
        Form {
            Section("Identity") {
                TextField("Name", text: group.name)
                LabeledContent("SF Symbol") {
                    HStack(spacing: 8) {
                        GroupGlyph(symbol: current.symbol, tint: model.tint(for: current), size: 24)
                        TextField("", text: group.symbol, prompt: Text("shippingbox.fill"))
                            .labelsHidden()
                        Menu {
                            ForEach(SymbolCatalog.suggestions, id: \.self) { symbol in
                                Button {
                                    group.wrappedValue.symbol = symbol
                                } label: {
                                    Label(symbol, systemImage: symbol)
                                }
                            }
                        } label: {
                            Image(systemName: "square.grid.3x3")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
                ColorPicker("Tint", selection: tintBinding, supportsOpacity: false)
                Picker("Click opens", selection: group.expansionMode) {
                    Text(L10n.tr("Default (%@)", model.config.behavior.expansionMode.title)).tag(ExpansionMode?.none)
                    ForEach(ExpansionMode.allCases) { mode in
                        Text(mode.title).tag(ExpansionMode?.some(mode))
                    }
                }
            }

            Section("Window Tiling") {
                LayoutChooser(selection: group.layout, tint: model.tint(for: current))
                HStack {
                    Button("Apply Layout Now") { model.applyLayout(current) }
                    Button("Launch & Tile") { model.launchAndTile(current) }
                    Spacer()
                    if !model.windows.isTrusted {
                        Label("Needs Accessibility access", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(HealthLevel.warning.color)
                            .font(.caption)
                    }
                }
            }

            Section("Widget") {
                Picker("Type", selection: group.widget.type) {
                    ForEach(WidgetType.allCases) { type in
                        Label(type.title, systemImage: type.symbol).tag(type)
                    }
                }
                switch current.widget.type {
                case .none:
                    Text("No live widget. Health probes below still drive the status dot.")
                        .foregroundStyle(.secondary)
                case .cpuRam:
                    Text("Shows CPU and memory of the group's apps (including helper processes), or system totals when none are running.")
                        .foregroundStyle(.secondary)
                case .podman:
                    Text("Shows the Podman machine and containers, with start/stop/restart controls in the popover. Runtime options live in Telemetry.")
                        .foregroundStyle(.secondary)
                case .portProbe:
                    TextField("Ports", text: $portsText, prompt: Text("5432, 6379, 8080"))
                        .onChange(of: portsText) { _, text in
                            let ports = Self.parsePorts(text)
                            if ports != group.wrappedValue.widget.ports { group.wrappedValue.widget.ports = ports }
                        }
                    Text("🟢 all listening · 🟡 some · 🔴 none — checked with `lsof -iTCP -sTCP:LISTEN`.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .customCommand:
                    TextField("Command", text: optionalText(group.widget.command), prompt: Text("curl -fsS localhost:8080/health && echo healthy"), axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1...5)
                    TextField("Label", text: optionalText(group.widget.label), prompt: Text("API"))
                    Text("Runs via /bin/sh with Homebrew on PATH. Exit 0 = 🟢, 1 = 🟡, anything else = 🔴. The first line of output becomes the badge text.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if current.widget.type == .customCommand || !current.widget.probes.isEmpty {
                    LabeledContent("Run every") {
                        HStack {
                            TextField("", value: intervalBinding, format: .number.precision(.fractionLength(0...1)))
                                .labelsHidden()
                                .frame(width: 60)
                            Text("seconds").foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                ForEach(Array(current.widget.probes.enumerated()), id: \.offset) { index, probe in
                    ProbeRow(probe: probeBinding(index)) {
                        group.wrappedValue.widget.probes.remove(at: index)
                    }
                }
                HStack {
                    Button("Add Port Check") {
                        group.wrappedValue.widget.probes.append(HealthProbe(name: "Postgres", port: 5432))
                    }
                    Button("Add Command Check") {
                        group.wrappedValue.widget.probes.append(HealthProbe(name: "API", command: "curl -fsS http://localhost:8080/health"))
                    }
                }
            } header: {
                Text("Health Probes")
            } footer: {
                Text("Extra checks shown in the popover; the worst result colours the capsule's status dot.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Apps") {
                if current.apps.isEmpty {
                    Text("No apps in this group yet.").foregroundStyle(.secondary)
                }
                ForEach(Array(current.apps.enumerated()), id: \.element.id) { index, app in
                    HStack(spacing: 10) {
                        AppIconView(app: app, size: 24, showsIndicator: false)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(model.workspace.displayName(for: app))
                            Text(app.path ?? app.bundleId ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button {
                            moveApp(from: index, by: -1)
                        } label: { Image(systemName: "chevron.up") }
                            .disabled(index == 0)
                        Button {
                            moveApp(from: index, by: 1)
                        } label: { Image(systemName: "chevron.down") }
                            .disabled(index == current.apps.count - 1)
                        Button(role: .destructive) {
                            group.wrappedValue.apps.remove(at: index)
                        } label: { Image(systemName: "trash") }
                    }
                    .buttonStyle(.borderless)
                }
                .onMove { group.wrappedValue.apps.move(fromOffsets: $0, toOffset: $1) }
                HStack {
                    Button("Add Application…") { addApplications() }
                    Menu("Add Running App") {
                        ForEach(model.workspace.runningRegularApps()) { app in
                            Button(app.name) { add([app]) }
                        }
                    }
                    .fixedSize()
                }
            }

            Section {
                Button("Delete Group", role: .destructive) { confirmDelete = true }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(current.name.isEmpty ? L10n.tr("Group") : current.name)
        .onAppear { portsText = current.widget.ports.map(String.init).joined(separator: ", ") }
        .confirmationDialog(L10n.tr("Delete “%@”?", current.name), isPresented: $confirmDelete) {
            Button("Delete Group", role: .destructive) { model.deleteGroup(id: groupID) }
        } message: {
            Text("The group is removed from the dock and config.json. Apps aren't affected.")
        }
    }

    // MARK: Bindings

    private var tintBinding: Binding<Color> {
        Binding(
            get: { model.tint(for: group.wrappedValue) },
            set: { group.wrappedValue.tintHex = $0.hexString }
        )
    }

    private var intervalBinding: Binding<Double> {
        Binding(
            get: { group.wrappedValue.widget.interval ?? model.config.telemetry.pollInterval },
            set: { group.wrappedValue.widget.interval = max(1, $0) }
        )
    }

    private func optionalText(_ binding: Binding<String?>) -> Binding<String> {
        Binding(
            get: { binding.wrappedValue ?? "" },
            set: { binding.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }

    private func probeBinding(_ index: Int) -> Binding<HealthProbe> {
        Binding(
            get: {
                let probes = group.wrappedValue.widget.probes
                return probes.indices.contains(index) ? probes[index] : HealthProbe(name: "")
            },
            set: { newValue in
                guard group.wrappedValue.widget.probes.indices.contains(index) else { return }
                group.wrappedValue.widget.probes[index] = newValue
            }
        )
    }

    // MARK: Actions

    private func moveApp(from index: Int, by offset: Int) {
        var apps = group.wrappedValue.apps
        let target = index + offset
        guard apps.indices.contains(index), apps.indices.contains(target) else { return }
        apps.swapAt(index, target)
        group.wrappedValue.apps = apps
    }

    private func addApplications() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = L10n.tr("Add")
        panel.message = L10n.tr("Choose apps to add to %@", group.wrappedValue.name)
        guard panel.runModal() == .OK else { return }
        add(panel.urls.map(DockApp.init(url:)))
    }

    private func add(_ apps: [DockApp]) {
        var current = group.wrappedValue.apps
        for app in apps where !current.contains(where: { $0.id == app.id }) {
            current.append(app)
        }
        group.wrappedValue.apps = current
    }

    static func parsePorts(_ text: String) -> [Int] {
        text.split(whereSeparator: { $0 == "," || $0 == " " })
            .compactMap { Int($0) }
            .filter { (1...65535).contains($0) }
    }
}

private struct ProbeRow: View {
    @Binding var probe: HealthProbe
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("Name", text: $probe.name)
                .frame(width: 120)
            if probe.port != nil {
                TextField("Port", value: Binding(
                    get: { probe.port ?? 0 },
                    set: { probe.port = $0 }
                ), format: .number.grouping(.never))
                .frame(width: 80)
                Text("port").foregroundStyle(.secondary)
            } else {
                TextField("Command", text: Binding(
                    get: { probe.command ?? "" },
                    set: { probe.command = $0 }
                ))
                .font(.system(.body, design: .monospaced))
            }
            Spacer(minLength: 0)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .labelsHidden()
    }
}

private struct LayoutChooser: View {
    @Binding var selection: TilingLayout
    var tint: Color

    var body: some View {
        HStack(spacing: 10) {
            ForEach(TilingLayout.allCases) { layout in
                let selected = layout == selection
                Button {
                    selection = layout
                } label: {
                    VStack(spacing: 6) {
                        LayoutGlyph(layout: layout)
                            .foregroundStyle(selected ? AnyShapeStyle(tint) : AnyShapeStyle(Color.secondary))
                            .frame(width: 54, height: 34)
                        Text(layout.shortTitle)
                            .font(.caption.weight(.semibold))
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(selected ? tint.opacity(0.15) : Color.primary.opacity(0.04))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(selected ? tint : Color.clear, lineWidth: 1.5)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(layout.title)
            }
        }
    }
}

// MARK: - Dock

/// The bar as a list: every group, pinned app and widget in order, to drag
/// into place, and everything that adds to it.
private struct DockLayoutSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let items = model.barItems
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    model.settingsSelection = .group(model.addGroup())
                } label: {
                    Label("New Group", systemImage: "square.stack.3d.up.fill")
                }
                Menu {
                    Button("Choose App…") { chooseApps() }
                    let running = model.workspace.runningRegularApps()
                    if !running.isEmpty {
                        Divider()
                        ForEach(running) { app in
                            Button(app.name) { model.pinApp(app) }
                        }
                    }
                } label: {
                    Label("Add App", systemImage: "app.badge")
                }
                .fixedSize()
                Menu {
                    AddWidgetMenuItems()
                } label: {
                    Label("Add Widget", systemImage: "square.grid.2x2")
                }
                .fixedSize()
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            List {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    DockItemRow(item: item, isFirst: index == 0, isLast: index == items.count - 1)
                }
                .onMove { model.moveBarItems(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            Text("Drag to reorder. Groups, apps and widgets go in any order, as on the Dock from left to right.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
        }
        .navigationTitle("Dock")
    }

    private func chooseApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = L10n.tr("Add")
        panel.message = L10n.tr("Choose apps to put on the Dock on their own")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { model.pinApp(DockApp(url: url)) }
    }
}

private struct DockItemRow: View {
    @Environment(AppModel.self) private var model
    let item: BarItem
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Group {
                Button { model.moveBarItem(id: item.id, by: -1) } label: { Label("Move up", systemImage: "chevron.up") }
                    .disabled(isFirst)
                    .help("Move up")
                Button { model.moveBarItem(id: item.id, by: 1) } label: { Label("Move down", systemImage: "chevron.down") }
                    .disabled(isLast)
                    .help("Move down")
                switch item {
                case .group(let group):
                    Button { model.settingsSelection = .group(group.id) } label: { Label("Edit Group…", systemImage: "slider.horizontal.3") }
                        .help("Edit Group…")
                case .app:
                    Button(role: .destructive) { model.unpinApp(itemID: item.id) } label: { Label("Remove from Dock", systemImage: "trash") }
                        .help("Remove from Dock")
                case .tile(let tile):
                    Button { model.settingsSelection = .tiles } label: { Label("Edit Widgets…", systemImage: "slider.horizontal.3") }
                        .help("Edit Widgets…")
                    Button(role: .destructive) { model.deleteTile(id: tile.id) } label: { Label("Remove from Dock", systemImage: "trash") }
                        .help("Remove from Dock")
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var icon: some View {
        switch item {
        case .group(let group): GroupGlyph(symbol: group.symbol, tint: model.tint(for: group), size: 24)
        case .app(let app): AppIconView(app: app, size: 26, showsIndicator: false)
        case .tile(let tile): GroupGlyph(symbol: tile.kind.symbol, tint: model.accent, size: 24)
        }
    }

    private var title: String {
        switch item {
        case .group(let group): group.name
        case .app(let app): model.workspace.displayName(for: app)
        case .tile(let tile): tile.title
        }
    }

    private var subtitle: String {
        switch item {
        case .group(let group): group.apps.count == 1 ? L10n.tr("Group · 1 app") : L10n.tr("Group · %lld apps", group.apps.count)
        case .app: L10n.tr("App")
        case .tile(let tile): L10n.tr("Widget · %@", tile.width.title)
        }
    }
}

// MARK: - Widgets

/// The tiles on the bar, in order, each with its size and options.
private struct TilesSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let tiles = model.config.tiles
        Form {
            Section {
                Text("Click a widget on the Dock to see its details. Arrange it among groups and apps in Settings › Dock.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Menu {
                    AddWidgetMenuItems()
                } label: {
                    Label("Add Widget", systemImage: "plus")
                }
                .fixedSize()
            }
            ForEach(tiles) { tile in
                TileEditorSection(tileID: tile.id)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Widgets")
    }
}

/// Widget kinds by category, for the "Add Widget" menus.
private struct AddWidgetMenuItems: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ForEach(TileKind.Category.allCases, id: \.self) { category in
            Section(category.title) {
                ForEach(TileKind.allCases.filter { $0.category == category }) { kind in
                    Button {
                        model.addTile(kind)
                    } label: {
                        Label(kind.title, systemImage: kind.symbol)
                    }
                }
            }
        }
    }
}

/// Plan limits need Kosmodock's status line in Claude Code.
private struct ClaudeStatusLineRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let service = model.claude
        LabeledContent("Plan limits") {
            switch service.statusLine {
            case .notSet:
                Button("Set Up in Claude Code") { service.installStatusLine() }
            case .kosmodock:
                Button("Remove from Claude Code") { service.removeStatusLine() }
            case .other:
                Text("Your own status line").foregroundStyle(.secondary)
            }
        }
        Text("Tokens come from Claude Code's files on this Mac. The 5-hour and weekly limits come from a status line Kosmodock adds to ~/.claude/settings.json (a copy is kept next to it) and only update while Claude Code runs.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .task { await service.refresh() }
    }
}

private struct CalendarAccessRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        LabeledContent("Calendar access") {
            switch model.calendar.access {
            case .granted: Text("Allowed").foregroundStyle(.secondary)
            case .unknown: Button("Allow") { Task { await model.calendar.requestAccessIfNeeded() } }
            case .denied:
                Button("Open Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                        NSWorkspace.shared.open(url)
                    }
                }
            case .unavailable: Text("Not in this build").foregroundStyle(.secondary)
            }
        }
        Text("Read-only: Kosmodock shows today's and tomorrow's events and never changes them.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

private struct TileEditorSection: View {
    @Environment(AppModel.self) private var model
    let tileID: String

    private var tile: Binding<DockTile> { model.tileBinding(id: tileID) }

    var body: some View {
        let current = tile.wrappedValue
        Section {
            Picker("Size", selection: tile.width) {
                ForEach(TileWidth.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            switch current.kind {
            case .clock:
                Toggle("Show seconds", isOn: tile.showsSeconds)
            case .command:
                TextField("Label", text: optionalText(\.label))
                TextField("Command", text: optionalText(\.command), prompt: Text(verbatim: "uptime"))
                    .font(.system(.body, design: .monospaced))
                Stepper(value: interval, in: 5...3600, step: 5) {
                    Text(L10n.tr("Every %lld s", Int(interval.wrappedValue)))
                }
                Text("The first line of the output goes on the tile. Exit 0 is green, 1 is yellow, anything else red.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("To design the tile, print a JSON object instead: `{\"text\": \"Deploy\", \"detail\": \"2 min ago\", \"symbol\": \"cloud.fill\", \"color\": \"#2EC27E\", \"progress\": 0.6, \"status\": \"ok\", \"url\": \"https://…\"}`. Every field is optional.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            case .claudeCode:
                ClaudeStatusLineRow()
            case .calendar:
                CalendarAccessRow()
            case .nowPlaying:
                Text("Shows Music or Spotify while one of them plays. The first time, macOS asks to let Kosmodock control the player.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .github:
                Text("Uses the `gh` command and its login, so Kosmodock holds no token. It checks every two minutes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .battery, .activity, .network:
                EmptyView()
            }
        } header: {
            HStack {
                Label(current.title, systemImage: current.kind.symbol)
                Spacer()
                Button(role: .destructive) { model.deleteTile(id: tileID) } label: { Label("Remove from Dock", systemImage: "trash") }
                    .help("Remove from Dock")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        }
    }

    private func optionalText(_ keyPath: WritableKeyPath<DockTile, String?>) -> Binding<String> {
        Binding(
            get: { tile.wrappedValue[keyPath: keyPath] ?? "" },
            set: { tile.wrappedValue[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }

    private var interval: Binding<Double> {
        Binding(
            get: { tile.wrappedValue.interval ?? model.config.telemetry.pollInterval },
            set: { tile.wrappedValue.interval = $0 }
        )
    }
}

// MARK: - Appearance

private struct AppearanceSettingsView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var previewBounce = false

    var body: some View {
        Form {
            Section("Theme") {
                DockStylePicker()
                Picker("Appearance", selection: model.binding(\.theme.appearance)) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                ColorPicker("Accent", selection: accentBinding, supportsOpacity: false)
            }
            Section {
                surfaceControls
            } header: {
                Text("Customize this theme")
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    Text(model.theme.style.summary)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.tr("Restore %@", model.theme.style.title)) {
                        model.configService.update { $0.theme.apply($0.theme.style) }
                    }
                    .disabled(!model.theme.isCustomized)
                }
            }
            Section("Effects") {
                Picker("Hover effect", selection: model.binding(\.theme.hoverEffect)) {
                    ForEach(HoverEffect.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if model.theme.hoverEffect == .magnify {
                    Text("Icons under the pointer grow with their neighbors, like the macOS Dock. Small icons on capsules grow in place, so capsules keep their size.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Picker("Launch animation", selection: model.binding(\.theme.launchAnimation)) {
                    ForEach(LaunchAnimation.allCases) { Text($0.title).tag($0) }
                }
                Picker("Running indicator", selection: model.binding(\.theme.indicatorStyle)) {
                    ForEach(IndicatorStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Indicator color", selection: model.binding(\.theme.indicatorColor)) {
                    ForEach(IndicatorColor.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(model.theme.indicatorStyle == .hidden)
                EffectsPreview()
            }
            Section("Layout") {
                SliderRow(title: L10n.tr("Icon size"), value: model.binding(\.theme.iconSize), range: 20...64, step: 1, format: Self.points)
                SliderRow(title: L10n.tr("Dock margin"), value: model.binding(\.theme.dockMargin), range: 0...80, step: 1, format: Self.points)
                SliderRow(title: L10n.tr("Tiling gap"), value: model.binding(\.theme.tileGap), range: 0...32, step: 1, format: Self.points)
                SliderRow(title: L10n.tr("Window clearance above dock"), value: model.binding(\.theme.dockClearance), range: 0...24, step: 1, format: Self.points)
                Toggle("Show group names on capsules", isOn: model.binding(\.theme.showGroupLabels))
            }
            Section("Motion") {
                SliderRow(title: L10n.tr("Stiffness (spring response)"), value: model.binding(\.theme.springResponse), range: 0.12...0.8, format: { String(format: "%.2f s", locale: L10n.locale, $0) })
                SliderRow(title: L10n.tr("Damping"), value: model.binding(\.theme.springDamping), range: 0.4...1, format: { String(format: "%.2f", locale: L10n.locale, $0) })
                HStack {
                    Text("Preview")
                    Spacer()
                    Capsule()
                        .fill(model.accent.gradient)
                        .frame(width: previewBounce ? 140 : 44, height: 22)
                        .animation(model.spring, value: previewBounce)
                    Button("Play") { previewBounce.toggle() }
                }
                Text("Lower response = stiffer, snappier springs. Defaults: 0.32s / 0.78.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Restore Default Theme") {
                    model.configService.update { $0.theme = ThemeConfig() }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Appearance")
    }

    /// Only the values the current style draws with.
    @ViewBuilder private var surfaceControls: some View {
        let surface = model.theme.surface
        if model.theme.style != .floating {
            Toggle("Background blur", isOn: surfaceBinding(\.blur))
            if surface.blur {
                Picker("Material", selection: surfaceBinding(\.material)) {
                    ForEach(GlassMaterial.allCases) { Text($0.title).tag($0) }
                }
            }
            if surface.fillTopHex != nil {
                ColorPicker("Top color", selection: colorBinding(\.fillTopHex), supportsOpacity: false)
                ColorPicker("Bottom color", selection: colorBinding(\.fillBottomHex), supportsOpacity: false)
                SliderRow(title: L10n.tr("Fill opacity"), value: surfaceBinding(\.fillOpacity), range: 0...1, format: Self.percent)
            } else {
                SliderRow(title: L10n.tr("Glass tint"), value: surfaceBinding(\.fillOpacity), range: 0...1, format: Self.percent)
            }
            ColorPicker("Border color", selection: colorBinding(\.borderHex), supportsOpacity: false)
            SliderRow(title: L10n.tr("Border opacity"), value: surfaceBinding(\.borderOpacity), range: 0...1, format: Self.percent)
            SliderRow(title: L10n.tr("Border width"), value: surfaceBinding(\.borderWidth), range: 0...3, step: 0.5, format: Self.fractionalPoints)
            ColorPicker("Glow color", selection: colorBinding(\.glowHex), supportsOpacity: false)
            SliderRow(title: L10n.tr("Glow"), value: surfaceBinding(\.glowOpacity), range: 0...1, format: Self.percent)
            Toggle("Top highlight", isOn: surfaceBinding(\.sheen))
        }
        SliderRow(title: L10n.tr("Corner radius"), value: surfaceBinding(\.cornerRadius), range: 6...40, step: 1, format: Self.points)
    }

    private func surfaceBinding<Value: Sendable>(_ keyPath: WritableKeyPath<DockSurface, Value>) -> Binding<Value> {
        model.binding((\DockConfig.theme.surface).appending(path: keyPath))
    }

    private func colorBinding(_ keyPath: WritableKeyPath<DockSurface, String>) -> Binding<Color> {
        Binding(
            get: { Color(hex: model.theme.surface[keyPath: keyPath]) ?? .white },
            set: { color in model.configService.update { $0.theme.surface[keyPath: keyPath] = color.hexString } }
        )
    }

    private func colorBinding(_ keyPath: WritableKeyPath<DockSurface, String?>) -> Binding<Color> {
        Binding(
            get: { Color(hex: model.theme.surface[keyPath: keyPath]) ?? .white },
            set: { color in model.configService.update { $0.theme.surface[keyPath: keyPath] = color.hexString } }
        )
    }

    private var accentBinding: Binding<Color> {
        Binding(
            get: { model.accent },
            set: { color in model.configService.update { $0.theme.accentHex = color.hexString } }
        )
    }

    static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
    static func points(_ value: Double) -> String { "\(Int(value.rounded())) pt" }
    static func fractionalPoints(_ value: Double) -> String { String(format: "%.1f pt", locale: L10n.locale, value) }
}

/// Kosmodock's own icon with the chosen effects: hover it, or play the launch.
private struct EffectsPreview: View {
    @Environment(AppModel.self) private var model
    @ViewState private var isLaunching = false
    @ViewState private var isHovering = false

    var body: some View {
        let theme = model.theme
        let size: CGFloat = 32
        let hoverScale: CGFloat = switch theme.hoverEffect {
        case .none: 1
        case .scale: 1.14
        case .magnify: 1.5
        }
        let indicator = theme.indicatorColor == .group
            ? (model.config.groups.first.map(model.tint) ?? model.accent)
            : model.accent
        HStack {
            Text("Preview")
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: size, height: size)
                .modifier(LaunchMotion(animation: isLaunching ? theme.launchAnimation : .none, size: size))
                .scaleEffect(isHovering ? hoverScale : 1, anchor: .bottom)
                .animation(model.spring, value: isHovering)
                .overlay(alignment: .bottom) {
                    RunningIndicator(style: theme.indicatorStyle, color: indicator, iconSize: size)
                }
                .onHover { isHovering = $0 }
                .padding(.top, 16)
                .padding(.bottom, 8)
                .padding(.horizontal, 12)
            Button("Play") {
                isLaunching = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    isLaunching = false
                }
            }
            .disabled(theme.launchAnimation == .none || isLaunching)
        }
    }
}

/// The styles as cards, each a miniature bar over a stand-in wallpaper.
private struct DockStylePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
            ForEach(DockStyle.allCases) { style in
                let isSelected = model.theme.style == style
                Button {
                    model.configService.update { $0.theme.apply(style) }
                } label: {
                    VStack(spacing: 6) {
                        DockStylePreview(surface: isSelected ? model.theme.surface : style.surface, accent: model.accent)
                            .overlay {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(isSelected ? model.accent : Color.primary.opacity(0.12), lineWidth: isSelected ? 2 : 1)
                            }
                        HStack(spacing: 4) {
                            Text(style.title)
                                .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                            if isSelected, model.theme.isCustomized {
                                Text("Customized")
                                    .font(.system(size: 9.5, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(style.summary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// A short bar of four icon placeholders drawn with `surface`.
struct DockStylePreview: View {
    var surface: DockSurface
    var accent: Color

    var body: some View {
        let scale: CGFloat = 0.5
        let radius = CGFloat(surface.cornerRadius) * scale
        ZStack(alignment: .bottom) {
            LinearGradient(
                colors: [Color(red: 0.30, green: 0.36, blue: 0.62), Color(red: 0.20, green: 0.14, blue: 0.34)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            RadialGradient(colors: [Color.orange.opacity(0.35), .clear], center: .topTrailing, startRadius: 4, endRadius: 90)
            HStack(spacing: 5) {
                ForEach(Array([accent, .orange, .teal, .pink].enumerated()), id: \.offset) { _, color in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(color.gradient)
                        .frame(width: 15, height: 15)
                        .background {
                            if !surface.isVisible {
                                SurfaceBackground(surface: DockStyle.glass.surface, cornerRadius: 6, blending: .withinWindow, scale: 0.25)
                                    .padding(-3)
                            }
                        }
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(SurfaceBackground(surface: surface, cornerRadius: radius, blending: .withinWindow, scale: scale))
            .padding(.bottom, 9)
        }
        .frame(height: 62)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct SliderRow: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double?
    var format: (Double) -> String

    init(title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double? = nil, format: @escaping (Double) -> String) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
        self.format = format
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                if let step {
                    Slider(value: $value, in: range, step: step)
                } else {
                    Slider(value: $value, in: range)
                }
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
            }
            .frame(minWidth: 240)
        }
    }
}

// MARK: - Behavior

private struct BehaviorSettingsView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @ViewState private var loginError: String?

    var body: some View {
        let dock = model.systemDock
        Form {
            Section("Language") {
                Picker("Interface language", selection: model.binding(\.behavior.language)) {
                    ForEach(AppLanguage.allCases) { Text(verbatim: $0.nativeName).tag($0) }
                }
                Text("Changes apply immediately to the dock, popovers, menus and this window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Dock") {
                Picker("Clicking a group opens", selection: model.binding(\.behavior.expansionMode)) {
                    ForEach(ExpansionMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle(isOn: model.binding(\.behavior.focusMode)) {
                    Text("Focus Mode")
                    Text("Launch & Tile hides every app outside the group.")
                }
                Toggle("Show menu bar icon", isOn: model.binding(\.behavior.showMenuBarIcon))
            }
            Section {
                Toggle(isOn: model.binding(\.behavior.reserveScreenSpace)) {
                    Text("Reserve screen space (push windows above the dock)")
                    Text("Windows that reach into the dock's band are moved up or shrunk to stop at its top edge, like the native Dock. Turn off to use Intellihide: the dock slides away while a window overlaps it and returns when the pointer touches the bottom edge.")
                }
                if model.config.behavior.reserveScreenSpace, let area = model.safeWorkAreaProvider?() {
                    LabeledContent("Reserved height", value: "\(Int(area.reservedBottomHeight.rounded())) pt")
                }
                if !model.windows.isTrusted {
                    Label("Needs Accessibility access (Permissions)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(HealthLevel.warning.color)
                        .font(.caption)
                }
            } header: {
                Text("Screen Space")
            }
            Section {
                Toggle(isOn: model.binding(\.behavior.minimizeToGroups)) {
                    Text("Minimize windows into their group")
                    Text("Minimized windows fly into their group's capsule (yellow button, ⌘M or Kosmodock clicks) and are listed in the group's popover for one-click restore.")
                }
                Toggle(isOn: model.binding(\.behavior.clickActiveAppToMinimize)) {
                    Text("Clicking the frontmost app's icon minimizes its window")
                }
                .disabled(!model.config.behavior.minimizeToGroups)
            } header: {
                Text("Minimize")
            }
            Section {
                Toggle(isOn: model.binding(\.behavior.suppressNativeDock)) {
                    Text("Hide the native macOS Dock while Kosmodock runs")
                    Text("Sets autohide with a 1000s delay, minimize-to-application and the short “scale” minimize effect. Your original settings are restored on quit, crash, SIGINT/SIGTERM, or force quit.")
                }
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        if dock.isBusy { ProgressView().controlSize(.small) }
                        Text(dock.isSuppressed ? L10n.tr("Native Dock hidden") : L10n.tr("Native Dock visible"))
                            .foregroundStyle(.secondary)
                    }
                }
                if let error = dock.lastError {
                    Text(error).foregroundStyle(HealthLevel.critical.color).font(.caption)
                }
            } header: {
                Text("Native Dock")
            }
            Section("Startup") {
                Toggle("Launch Kosmodock at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let loginError {
                    Text(loginError).foregroundStyle(HealthLevel.critical.color).font(.caption)
                }
                Text("Requires running the bundled Kosmodock.app (scripts/bundle.sh).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Behavior")
    }
}

// MARK: - Telemetry

private struct TelemetrySettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let system = model.telemetry.system
        let containers = model.containers
        Form {
            Section("Polling") {
                SliderRow(title: L10n.tr("Poll interval"), value: model.binding(\.telemetry.pollInterval), range: 1...30, step: 1, format: { "\(Int($0))s" })
                SliderRow(title: L10n.tr("Command timeout"), value: model.binding(\.telemetry.commandTimeout), range: 2...60, step: 1, format: { "\(Int($0))s" })
            }
            Section("Container Runtime") {
                Picker("Runtime", selection: model.binding(\.telemetry.containerRuntime)) {
                    ForEach(ContainerRuntimeKind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                TextField("Binary path", text: runtimePathBinding, prompt: Text("Auto-detect (/opt/homebrew/bin/podman, /usr/local/bin/podman…)"))
                Toggle("Fall back to the other runtime when not found", isOn: model.binding(\.telemetry.fallbackToDocker))
                LabeledContent("Detected") {
                    Text(containers.runtime?.path ?? (containers.isEnabled ? L10n.tr("Not found") : L10n.tr("Inactive (no Podman widget)")))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                LabeledContent("Machine") {
                    HStack(spacing: 6) {
                        StatusDot(level: containers.status.level, size: 7)
                        Text(containers.status.title).foregroundStyle(.secondary)
                    }
                }
                Button("Refresh Now") { Task { await containers.refresh() } }
            }
            Section("Live Readings") {
                LabeledContent("CPU", value: Format.percent(system.cpuPercent))
                LabeledContent("Memory", value: L10n.tr("%@ of %@", Format.bytes(system.memoryUsed), Format.bytes(system.memoryTotal)))
                LabeledContent("Memory pressure", value: system.pressure.title)
                LabeledContent("Swap", value: Format.bytes(system.swapUsed))
                LabeledContent("Load average", value: String(format: "%.2f", locale: L10n.locale, system.loadAverage))
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Telemetry")
    }

    private var runtimePathBinding: Binding<String> {
        Binding(
            get: { model.config.telemetry.runtimePath ?? "" },
            set: { value in model.configService.update { $0.telemetry.runtimePath = value.isBlank ? nil : value } }
        )
    }
}

// MARK: - Permissions

private struct PermissionsSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let trusted = model.windows.isTrusted
        Form {
            Section("Accessibility") {
                HStack(spacing: 12) {
                    Image(systemName: trusted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(trusted ? HealthLevel.ok.color : HealthLevel.warning.color)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(trusted ? L10n.tr("Accessibility access granted") : L10n.tr("Accessibility access required"))
                            .font(.headline)
                        Text("Used only to move and resize windows for tiling, and to raise a group's windows together.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                if !trusted {
                    HStack {
                        Button("Request Access") { model.windows.requestAccess() }
                            .buttonStyle(.borderedProminent)
                        Button("Open System Settings") { model.windows.openAccessibilitySettings() }
                    }
                }
                if !trusted {
                    Text("Already switched on but still “required”? That entry belongs to an older build. In System Settings select Kosmodock, remove it with −, then click Request Access and switch the new entry on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if WindowManagerService.isAdHocSigned {
                    Label("This build is ad-hoc signed, so macOS forgets the permission on every rebuild. Run `bash scripts/setup-signing.sh` once, then rebuild with `scripts/bundle.sh`.", systemImage: "signature")
                        .font(.caption)
                        .foregroundStyle(HealthLevel.warning.color)
                } else {
                    Label("Signed with a stable identity — the permission survives rebuilds.", systemImage: "checkmark.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Permissions")
    }
}

// MARK: - Config file

private struct ConfigFileSettingsView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var confirmReset = false

    var body: some View {
        let service = model.configService
        Form {
            Section {
                LabeledContent("Location") {
                    Text(service.fileURL.path)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Open in Editor") { service.openInEditor() }
                    Button("Reveal in Finder") { service.revealInFinder() }
                    Button("Reload") { service.reloadFromDisk(force: true) }
                }
                if let error = service.lastError {
                    Label(error, systemImage: "exclamationmark.octagon.fill")
                        .foregroundStyle(HealthLevel.critical.color)
                        .textSelection(.enabled)
                } else {
                    Label("Valid — edits are hot-reloaded as soon as you save.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(HealthLevel.ok.color)
                }
            } header: {
                Text("config.json")
            } footer: {
                Text("Kosmodock watches the file; an invalid edit keeps the last good config active and shows the error here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Reset") {
                Button("Regenerate from Installed Apps…", role: .destructive) { confirmReset = true }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Config File")
        .confirmationDialog("Replace your configuration?", isPresented: $confirmReset) {
            Button("Regenerate", role: .destructive) { service.resetToDefaults() }
        } message: {
            Text("Groups are rebuilt by scanning /Applications. Your current groups and theme are overwritten.")
        }
    }
}

enum SymbolCatalog {
    static let suggestions = [
        "chevron.left.forwardslash.chevron.right", "hammer.fill", "terminal.fill", "shippingbox.fill",
        "cylinder.split.1x2.fill", "server.rack", "network", "globe", "safari.fill", "sparkles",
        "brain.head.profile", "bubble.left.and.bubble.right.fill", "envelope.fill", "music.note",
        "paintbrush.fill", "photo.fill", "film.fill", "gamecontroller.fill", "doc.text.fill",
        "folder.fill", "gearshape.2.fill", "chart.bar.fill", "creditcard.fill", "lock.shield.fill",
        "cloud.fill", "bolt.fill", "flame.fill", "leaf.fill", "star.fill", "cube.fill",
    ]
}
