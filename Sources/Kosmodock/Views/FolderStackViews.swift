import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Folder stacks, the Trash and spacers: on the bar, in the folder popover
// and in Settings › Dock.

// MARK: - On the bar

/// A folder, the Trash or a spacer on the bar.
struct BarExtraView: View {
    let extra: BarExtra
    let density: DockDensity

    var body: some View {
        switch extra {
        case .folder(let folder): FolderStackDockView(folder: folder, density: density)
        case .trash: TrashDockView(density: density)
        case .spacer(let spacer): SpacerDockView(spacer: spacer)
        }
    }
}

/// A file's icon at a pinned app's size, with the style's reflection.
struct DockFileIcon: View {
    @Environment(AppModel.self) private var model
    let image: NSImage
    let size: CGFloat

    var body: some View {
        icon.background(alignment: .bottom) {
            if model.theme.surface.reflection {
                Reflection(height: size, margin: size * 0.09) { icon }
            }
        }
    }

    private var icon: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }
}

extension HoverEffect {
    /// How much a plain icon on the bar grows under the pointer, as `PinnedAppView`.
    var iconScale: CGFloat {
        switch self {
        case .none: 1
        case .scale: 1.14
        case .magnify: 1.3
        }
    }
}

/// A folder on the bar. Downloads shows how many files arrived since its
/// popover was last opened.
struct FolderStackDockView: View {
    @Environment(AppModel.self) private var model
    let folder: DockFolder
    var density: DockDensity = .regular
    @ViewState private var isHovering = false

    var body: some View {
        let theme = model.theme
        // As tall as a capsule, like pinned apps.
        let size = density.capsuleHeight(iconSize: theme.iconSize)
        let count = model.folderStacks.newCount(for: folder.id)
        Button {
            model.tap(folder)
        } label: {
            DockFileIcon(image: model.folderStacks.icon(for: folder), size: size)
                .modifier(NotificationBadge(label: count > 0 ? Self.badgeText(count) : nil, iconSize: size))
                .frame(height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovering ? theme.hoverEffect.iconScale : 1, anchor: .bottom)
        .animation(model.spring, value: isHovering)
        .onHover { isHovering = $0 }
        .contextMenu { FolderStackMenu(folder: folder) }
        .accessibilityLabel(folder.displayName)
        .help(help(count: count))
    }

    static func badgeText(_ count: Int) -> String {
        count > 99 ? "99+" : "\(count)"
    }

    private func help(count: Int) -> String {
        switch count {
        case 0: folder.displayName
        case 1: L10n.tr("%@ — 1 new item", folder.displayName)
        default: L10n.tr("%@ — %lld new items", folder.displayName, count)
        }
    }
}

private struct FolderStackMenu: View {
    @Environment(AppModel.self) private var model
    let folder: DockFolder

    var body: some View {
        Button("Open in Finder") { model.openInFinder(folder) }
        Picker("View as", selection: layout) {
            ForEach(FolderLayout.allCases) { Text($0.title).tag($0) }
        }
        Picker("Sort By", selection: sort) {
            ForEach(FolderSort.allCases) { Text($0.title).tag($0) }
        }
        Divider()
        Button("Remove from Dock") { model.removeFolder(id: folder.id) }
    }

    private var layout: Binding<FolderLayout> {
        Binding(get: { folder.layout }, set: { value in model.updateFolder(id: folder.id) { $0.layout = value } })
    }

    private var sort: Binding<FolderSort> {
        Binding(get: { folder.sort }, set: { value in model.updateFolder(id: folder.id) { $0.sort = value } })
    }
}

enum TrashIcon {
    static func image(full: Bool) -> NSImage {
        NSImage(named: full ? NSImage.trashFullName : NSImage.trashEmptyName) ?? NSWorkspace.shared.icon(for: .folder)
    }
}

/// The Trash, at the end of the bar. Files dropped on it go to the Trash.
struct TrashDockView: View {
    @Environment(AppModel.self) private var model
    var density: DockDensity = .regular
    @ViewState private var isHovering = false
    @ViewState private var isTargeted = false

    var body: some View {
        let theme = model.theme
        let size = density.capsuleHeight(iconSize: theme.iconSize)
        let state = model.trash.state
        Button {
            model.dismissPopover?()
            model.trash.open()
        } label: {
            DockFileIcon(image: TrashIcon.image(full: state == .full), size: size)
                .frame(height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(isTargeted ? HoverEffect.scale.iconScale : (isHovering ? theme.hoverEffect.iconScale : 1), anchor: .bottom)
        .animation(model.spring, value: isHovering)
        .animation(model.spring, value: isTargeted)
        .onHover { isHovering = $0 }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            FileDrop.loadURLs(from: providers) { urls in model.moveToTrash(urls) }
            return true
        }
        .contextMenu { TrashMenu() }
        .accessibilityLabel(L10n.tr("Trash"))
        .help(state == .unreadable ? L10n.tr("Trash — Kosmodock needs Full Disk Access to see what's in it") : L10n.tr("Trash"))
    }
}

private struct TrashMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let trash = model.trash
        Button("Open Trash") { trash.open() }
        Button("Empty Trash…") { TrashActions.confirmEmpty(model) }
            .disabled(trash.state == .empty || trash.isEmptying)
        if trash.state == .unreadable {
            Divider()
            Text("Kosmodock needs Full Disk Access to see what's in the Trash, so its icon always looks empty.")
            Button("Open Full Disk Access Settings…") { PrivacyPane.open(PrivacyPane.fullDiskAccess) }
        }
        Divider()
        Button("Remove from Dock") { model.setShowsTrash(false) }
    }
}

@MainActor
enum TrashActions {
    /// Asks first, as the Finder does, then has the Finder empty the Trash.
    static func confirmEmpty(_ model: AppModel) {
        Task { @MainActor in
            NSApp.activate()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.tr("Empty the Trash?")
            alert.informativeText = L10n.tr("The items in the Trash are erased for good. You can't undo this.")
            alert.addButton(withTitle: L10n.tr("Empty Trash")).hasDestructiveAction = true
            alert.addButton(withTitle: L10n.tr("Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            do {
                try await model.trash.empty()
            } catch {
                let failure = NSAlert()
                failure.alertStyle = .warning
                failure.messageText = L10n.tr("The Trash wasn't emptied")
                failure.informativeText = (error as NSError).code == FinderTrash.notPermitted
                    ? L10n.tr("Kosmodock isn't allowed to control %@. Turn it on in System Settings › Privacy & Security › Automation.", "Finder")
                    : error.localizedDescription
                failure.runModal()
            }
        }
    }
}

enum PrivacyPane {
    static let fullDiskAccess = "Privacy_AllFiles"
    static let filesAndFolders = "Privacy_FilesAndFolders"

    static func open(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Empty room on the bar. It shows a dashed outline only under the pointer,
/// so it can be found and removed.
struct SpacerDockView: View {
    @Environment(AppModel.self) private var model
    let spacer: DockSpacer
    @ViewState private var isHovering = false

    /// A large spacer is one square tile wide, a small one half that. A
    /// flexible one starts small and takes the bar's free width (`CapsuleRow`).
    static func width(_ size: SpacerSize, iconSize: Double) -> CGFloat {
        let unit = TileView.unit(iconSize: iconSize)
        return size == .large ? unit : (unit * 0.5).rounded()
    }

    var body: some View {
        let theme = model.theme
        let unit = TileView.unit(iconSize: theme.iconSize)
        let width = Self.width(spacer.size, iconSize: theme.iconSize)
        let shape = RoundedRectangle(cornerRadius: theme.capsuleRadius, style: .continuous)
        shape
            .strokeBorder(Color.primary.opacity(isHovering ? 0.3 : 0), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .frame(minWidth: width, idealWidth: width, maxWidth: spacer.size == .flexible ? .infinity : width)
            .frame(minHeight: unit, idealHeight: unit, maxHeight: .infinity)
            .contentShape(shape)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
            }
            .contextMenu { SpacerMenu(spacer: spacer) }
            .accessibilityHidden(true)
            .help(spacer.size.title)
    }
}

private struct SpacerMenu: View {
    @Environment(AppModel.self) private var model
    let spacer: DockSpacer

    var body: some View {
        Picker("Size", selection: Binding(get: { spacer.size }, set: { model.setSpacerSize(id: spacer.id, size: $0) })) {
            ForEach(SpacerSize.allCases) { Text($0.title).tag($0) }
        }
        Divider()
        Button("Remove Spacer") { model.removeSpacer(id: spacer.id) }
    }
}

// MARK: - Popover

/// A folder's contents, opened by clicking it on the bar.
struct FolderStackPopoverView: View {
    @Environment(AppModel.self) private var model
    let folderID: String

    static let width: CGFloat = 436
    /// The most items listed; the rest are a click away in the Finder.
    static let limit = 120

    var body: some View {
        if let folder = model.folder(id: folderID) {
            let stack = model.folderStacks.stack(for: folder.id)
            VStack(alignment: .leading, spacing: 12) {
                FolderPopoverHeader(folder: folder, stack: stack)
                if !stack.isReadable {
                    FolderMessage(
                        symbol: "lock.fill",
                        title: L10n.tr("Kosmodock can't read this folder"),
                        detail: L10n.tr("It may have moved, or Kosmodock needs permission for it. Turn it on in System Settings › Privacy & Security › Files and Folders.")
                    ) {
                        Button("Open Privacy Settings…") { PrivacyPane.open(PrivacyPane.filesAndFolders) }
                            .buttonStyle(GlassPillButtonStyle(tint: model.accent))
                    }
                } else if !stack.isLoaded {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                } else if stack.entries.isEmpty {
                    FolderMessage(symbol: "folder", title: L10n.tr("This folder is empty"), detail: nil) { EmptyView() }
                } else {
                    let entries = FolderListing.sorted(stack.entries, by: folder.sort)
                    let shown = Array(entries.prefix(Self.limit))
                    switch folder.layout {
                    case .grid: FolderGrid(entries: shown)
                    case .list: FolderList(entries: shown)
                    }
                    if entries.count > shown.count {
                        Text(L10n.tr("%lld more in the Finder", entries.count - shown.count))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(16)
            .frame(width: Self.width)
            .background(SurfaceBackground(surface: model.theme.popoverSurface, cornerRadius: CGFloat(model.theme.popoverSurface.cornerRadius) + 4))
            .tint(model.accent)
        }
    }
}

private struct FolderPopoverHeader: View {
    @Environment(AppModel.self) private var model
    let folder: DockFolder
    let stack: FolderStackService.Stack

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: model.folderStacks.icon(for: folder))
                .resizable()
                .interpolation(.high)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: folder.displayName)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .lineLimit(1)
                Text(verbatim: subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .layoutPriority(-1)
            .help(folder.path)
            Spacer(minLength: 8)
            FolderLayoutSwitch(folder: folder)
            FolderSortMenu(folder: folder)
            Button {
                model.openInFinder(folder)
            } label: {
                Label("Open in Finder", systemImage: "folder")
                    .lineLimit(1)
                    .fixedSize()
            }
            .buttonStyle(GlassPillButtonStyle(tint: model.accent, prominent: true))
        }
    }

    private var subtitle: String {
        guard stack.isLoaded, stack.isReadable else { return folder.path }
        let count = stack.entries.count
        return count == 1 ? L10n.tr("1 item") : L10n.tr("%lld items", count)
    }
}

/// Grid or list, as two small segments.
private struct FolderLayoutSwitch: View {
    @Environment(AppModel.self) private var model
    let folder: DockFolder

    var body: some View {
        HStack(spacing: 2) {
            ForEach(FolderLayout.allCases) { layout in
                let isSelected = folder.layout == layout
                Button {
                    model.updateFolder(id: folder.id) { $0.layout = layout }
                } label: {
                    Image(systemName: layout.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 22)
                        .foregroundStyle(isSelected ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Color.secondary))
                        .background(Capsule().fill(Color.primary.opacity(isSelected ? 0.16 : 0)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(layout.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .help(layout.title)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }
}

private struct FolderSortMenu: View {
    @Environment(AppModel.self) private var model
    let folder: DockFolder

    var body: some View {
        Menu {
            Picker(selection: Binding(get: { folder.sort }, set: { value in model.updateFolder(id: folder.id) { $0.sort = value } })) {
                ForEach(FolderSort.allCases) { Text($0.title).tag($0) }
            } label: {
                Text("Sort By")
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 11, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 26, height: 26)
        .background(Circle().fill(Color.primary.opacity(0.07)))
        .help(L10n.tr("Sort By"))
    }
}

private struct FolderMessage<Accessory: View>: View {
    let symbol: String
    let title: String
    let detail: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: title)
                    .font(.system(size: 12, weight: .semibold))
                if let detail {
                    Text(verbatim: detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                accessory
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        }
    }
}

private struct FolderGrid: View {
    let entries: [FolderEntry]

    static let columns = 5
    static let cell = CGSize(width: 76, height: 86)
    static let spacing: CGFloat = 4
    /// Three and a half rows, so a longer folder shows that it scrolls.
    static let maxHeight = cell.height * 3.5 + spacing * 3

    var body: some View {
        let rows = (entries.count + Self.columns - 1) / Self.columns
        let height = CGFloat(rows) * Self.cell.height + CGFloat(max(0, rows - 1)) * Self.spacing
        let grid = LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.cell.width), spacing: Self.spacing), count: Self.columns), spacing: Self.spacing) {
            ForEach(entries) { FolderEntryCell(entry: $0) }
        }
        // Scrolls only when it's taller than the popover allows.
        if height > Self.maxHeight {
            ScrollView(.vertical) { grid }
                .frame(height: Self.maxHeight)
        } else {
            grid
        }
    }
}

private struct FolderList: View {
    let entries: [FolderEntry]

    static let rowHeight: CGFloat = 36
    static let spacing: CGFloat = 2
    static let maxHeight = rowHeight * 8.5 + spacing * 8

    var body: some View {
        let height = CGFloat(entries.count) * Self.rowHeight + CGFloat(max(0, entries.count - 1)) * Self.spacing
        let list = LazyVStack(spacing: Self.spacing) {
            ForEach(entries) { FolderEntryRow(entry: $0) }
        }
        if height > Self.maxHeight {
            ScrollView(.vertical) { list }
                .frame(height: Self.maxHeight)
        } else {
            list
        }
    }
}

private struct FolderEntryCell: View {
    @Environment(AppModel.self) private var model
    let entry: FolderEntry
    @ViewState private var isHovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Button {
            model.open(entry)
        } label: {
            VStack(spacing: 4) {
                Image(nsImage: model.folderStacks.icon(for: entry))
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 44, height: 44)
                Text(verbatim: entry.name)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 3)
            .frame(width: FolderGrid.cell.width, height: FolderGrid.cell.height)
            .background(shape.fill(Color.primary.opacity(isHovering ? 0.1 : 0)))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .onDrag { NSItemProvider(object: entry.url as NSURL) }
        .contextMenu { FolderEntryMenu(entry: entry) }
        .help(entry.name)
    }
}

private struct FolderEntryRow: View {
    @Environment(AppModel.self) private var model
    let entry: FolderEntry
    @ViewState private var isHovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        Button {
            model.open(entry)
        } label: {
            HStack(spacing: 9) {
                Image(nsImage: model.folderStacks.icon(for: entry))
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: entry.name)
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(verbatim: detail)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
            }
            .padding(.horizontal, 9)
            .frame(height: FolderList.rowHeight)
            .background(shape.fill(Color.primary.opacity(isHovering ? 0.1 : 0.04)))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .onDrag { NSItemProvider(object: entry.url as NSURL) }
        .contextMenu { FolderEntryMenu(entry: entry) }
        .help(entry.name)
    }

    /// "PDF document · 2 hours ago".
    private var detail: String {
        var parts = [entry.kind].filter { !$0.isEmpty }
        if entry.dateAdded > .distantPast {
            parts.append(entry.dateAdded.formatted(Date.RelativeFormatStyle(presentation: .named, unitsStyle: .abbreviated, locale: L10n.locale)))
        }
        return parts.joined(separator: " · ")
    }
}

private struct FolderEntryMenu: View {
    @Environment(AppModel.self) private var model
    let entry: FolderEntry

    var body: some View {
        Button("Open") { model.open(entry) }
        Button("Show in Finder") { model.revealInFinder(entry) }
        Divider()
        Button("Move to Trash") { model.moveToTrash([entry.url]) }
    }
}

// MARK: - Settings › Dock

/// A folder's, the Trash's or a spacer's icon in Settings' lists.
struct BarExtraIcon: View {
    @Environment(AppModel.self) private var model
    let extra: BarExtra
    var size: CGFloat

    var body: some View {
        switch extra {
        case .folder(let folder):
            Image(nsImage: model.folderStacks.icon(for: folder)).resizable().interpolation(.high).frame(width: size, height: size)
        case .trash:
            Image(nsImage: TrashIcon.image(full: model.trash.state == .full)).resizable().interpolation(.high).frame(width: size, height: size)
        case .spacer(let spacer):
            GroupGlyph(symbol: spacer.size.symbol, tint: .gray, size: size - 2)
        }
    }
}

extension BarExtra {
    var title: String {
        switch self {
        case .folder(let folder): folder.displayName
        case .trash: L10n.tr("Trash")
        case .spacer(let spacer): spacer.size.title
        }
    }

    var subtitle: String {
        switch self {
        case .folder(let folder): L10n.tr("Folder · %@", folder.path)
        case .trash: L10n.tr("Always at the end of the Dock")
        case .spacer(let spacer): spacer.size == .flexible ? L10n.tr("Spacer · takes the free width") : L10n.tr("Spacer")
        }
    }
}

/// The row actions of a folder, the Trash or a spacer in Settings › Dock.
struct BarExtraRowButtons: View {
    @Environment(AppModel.self) private var model
    let extra: BarExtra

    var body: some View {
        switch extra {
        case .folder(let folder):
            Button { model.openInFinder(folder) } label: { Label("Open in Finder", systemImage: "folder") }
                .help("Open in Finder")
            Button(role: .destructive) { model.removeFolder(id: folder.id) } label: { Label("Remove from Dock", systemImage: "trash") }
                .help("Remove from Dock")
        case .trash:
            Button(role: .destructive) { model.setShowsTrash(false) } label: { Label("Remove from Dock", systemImage: "trash") }
                .help("Remove from Dock")
        case .spacer(let spacer):
            Button(role: .destructive) { model.removeSpacer(id: spacer.id) } label: { Label("Remove Spacer", systemImage: "trash") }
                .help("Remove Spacer")
        }
    }
}

/// The Trash's row at the end of Settings › Dock's list, while it's shown.
/// It's outside the reorderable rows: the Trash is always last.
struct TrashSettingsRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.config.showsTrash {
            HStack(spacing: 10) {
                BarExtraIcon(extra: .trash, size: 26).frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: BarExtra.trash.title).lineLimit(1)
                    Text(verbatim: BarExtra.trash.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                BarExtraRowButtons(extra: .trash)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
            .padding(.vertical, 2)
        }
    }
}

/// Settings › Dock's menu for folders, Downloads and spacers.
struct AddDockItemMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Button("Add Folder…") { chooseFolders() }
            Button("Add Downloads") { model.addDownloads() }
            Divider()
            ForEach(SpacerSize.allCases) { size in
                Button {
                    model.addSpacer(size)
                } label: {
                    Label(size.title, systemImage: size.symbol)
                }
            }
        } label: {
            Label("Add Folder or Spacer", systemImage: "folder.badge.plus")
        }
        .fixedSize()
    }

    private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.prompt = L10n.tr("Add")
        panel.message = L10n.tr("Choose folders to put on the Dock")
        guard panel.runModal() == .OK else { return }
        model.addFolders(panel.urls)
    }
}

/// Under Settings › Dock's buttons: the Trash and undo.
struct DockItemsSettingsBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Toggle("Show Trash", isOn: Binding(get: { model.config.showsTrash }, set: { model.setShowsTrash($0) }))
            Spacer()
            Button {
                model.undoLastDockChange()
            } label: {
                Label("Undo Last Dock Change", systemImage: "arrow.uturn.backward")
            }
            .disabled(!model.canUndoDockChange)
            .help("Brings back the Dock from before the last item was added, removed or moved. ⌘Z does it too.")
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }
}
