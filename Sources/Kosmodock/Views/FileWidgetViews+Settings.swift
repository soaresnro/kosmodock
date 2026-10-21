import AppKit
import SwiftUI

// Settings of the file and sharing widgets: their options in Settings ›
// Widgets and the Drop Zone in Settings › Behavior.

/// The options of a file or sharing widget in Settings › Widgets.
struct FileWidgetEditor: View {
    @Environment(AppModel.self) private var model
    let tile: Binding<DockTile>

    var body: some View {
        let current = tile.wrappedValue
        switch current.kind {
        case .screenshots:
            LabeledContent("Folder") {
                Text(verbatim: (ScreenshotDetector.currentFolder().path as NSString).abbreviatingWithTildeInPath)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            countStepper(current)
            Picker("Click a screenshot to", selection: action) {
                ForEach(FileClickAction.allCases) { Text($0.title).tag($0) }
            }
            caption(L10n.tr("Follows the location chosen in the Screenshot app (⇧⌘5 › Options) and lists the newest screenshots there. Drag one out of the details to drop it anywhere."))
        case .files:
            LabeledContent("Folder") {
                HStack {
                    Text(verbatim: (current.folderURL.path as NSString).abbreviatingWithTildeInPath)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose…") { chooseFolder() }
                    if current.filesFolder != nil {
                        Button("Use Downloads") { tile.wrappedValue.filesFolder = nil }
                    }
                }
            }
            countStepper(current)
            Picker("Click a file to", selection: action) {
                ForEach([FileClickAction.open, .reveal]) { Text($0.title).tag($0) }
            }
            caption(L10n.tr("The tile counts files added since you last opened its details."))
        case .shelf:
            Toggle("Take a file off the Shelf when it's dragged out", isOn: removesOnDragOut)
            LabeledContent("Files") {
                HStack {
                    Text(L10n.tr("%lld of %lld", current.shelfURLs.count, DockTile.shelfLimit))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Button("Clear Shelf") { model.clearShelf(tileID: current.id) }
                        .disabled(current.shelfURLs.isEmpty)
                }
            }
            caption(L10n.tr("Drop files on the tile, or on the Drop Zone (Settings › Behavior). Only their locations are kept, in config.json: the files stay where they are, and dragging one out copies it."))
        case .bookmarks:
            BookmarksEditor(tile: tile)
        case .appCollection:
            CollectionEditor(tile: tile)
        case .shortcut:
            ShortcutEditor(tile: tile)
        case .airDrop:
            caption(L10n.tr("Drop files on the tile to send them with AirDrop. Clicking it opens AirDrop in the Finder."))
        default:
            EmptyView()
        }
    }

    private func countStepper(_ current: DockTile) -> some View {
        Stepper(value: count, in: DockTile.fileCountRange) {
            Text(L10n.tr("Show the newest %lld", current.shownFileCount))
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var count: Binding<Int> {
        Binding(get: { tile.wrappedValue.shownFileCount }, set: { tile.wrappedValue.fileCount = $0 })
    }

    private var action: Binding<FileClickAction> {
        Binding(get: { tile.wrappedValue.clickAction }, set: { tile.wrappedValue.fileAction = $0 })
    }

    private var removesOnDragOut: Binding<Bool> {
        Binding(get: { tile.wrappedValue.removesOnDragOut ?? false }, set: { tile.wrappedValue.removesOnDragOut = $0 ? true : nil })
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = tile.wrappedValue.folderURL
        panel.prompt = L10n.tr("Choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        tile.wrappedValue.filesFolder = (url.path as NSString).abbreviatingWithTildeInPath
    }
}

private struct BookmarksEditor: View {
    let tile: Binding<DockTile>
    @ViewState private var browsers: [FileActions.Browser] = []

    var body: some View {
        let bookmarks = tile.wrappedValue.bookmarks ?? []
        if bookmarks.isEmpty {
            Text("No links in this widget yet.").foregroundStyle(.secondary)
        }
        ForEach(Array(bookmarks.enumerated()), id: \.offset) { index, _ in
            HStack(spacing: 8) {
                Image(systemName: "link").foregroundStyle(.secondary)
                TextField("Title", text: field(index, \.title))
                    .frame(maxWidth: 140)
                TextField("Address", text: field(index, \.url), prompt: Text(verbatim: "example.com"))
                Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0)
                Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(index == bookmarks.count - 1)
                Button(role: .destructive) { remove(index) } label: { Image(systemName: "trash") }
            }
            .labelsHidden()
            .buttonStyle(.borderless)
        }
        Button("Add Link") {
            tile.wrappedValue.bookmarks = bookmarks + [Bookmark(title: "", url: "")]
        }
        Picker("Open in", selection: browser) {
            Text("Default browser").tag(String?.none)
            ForEach(browserChoices) { Text(verbatim: $0.name).tag(String?.some($0.id)) }
        }
        .onAppear { browsers = FileActions.browsers() }
        Text("The wide tile shows the first two links as buttons; click the tile for all of them.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// The installed browsers, plus the chosen one when it's gone.
    private var browserChoices: [FileActions.Browser] {
        guard let chosen = tile.wrappedValue.bookmarkBrowser, !browsers.contains(where: { $0.id == chosen }) else { return browsers }
        return browsers + [FileActions.Browser(id: chosen, name: chosen)]
    }

    private var browser: Binding<String?> {
        Binding(get: { tile.wrappedValue.bookmarkBrowser }, set: { tile.wrappedValue.bookmarkBrowser = $0 })
    }

    private func field(_ index: Int, _ keyPath: WritableKeyPath<Bookmark, String>) -> Binding<String> {
        Binding(
            get: {
                let bookmarks = tile.wrappedValue.bookmarks ?? []
                return bookmarks.indices.contains(index) ? bookmarks[index][keyPath: keyPath] : ""
            },
            set: { value in
                guard var bookmarks = tile.wrappedValue.bookmarks, bookmarks.indices.contains(index) else { return }
                bookmarks[index][keyPath: keyPath] = value
                tile.wrappedValue.bookmarks = bookmarks
            }
        )
    }

    private func move(_ index: Int, by offset: Int) {
        guard var bookmarks = tile.wrappedValue.bookmarks, bookmarks.indices.contains(index), bookmarks.indices.contains(index + offset) else { return }
        bookmarks.swapAt(index, index + offset)
        tile.wrappedValue.bookmarks = bookmarks
    }

    private func remove(_ index: Int) {
        guard var bookmarks = tile.wrappedValue.bookmarks, bookmarks.indices.contains(index) else { return }
        bookmarks.remove(at: index)
        tile.wrappedValue.bookmarks = bookmarks.isEmpty ? nil : bookmarks
    }
}

private struct CollectionEditor: View {
    @Environment(AppModel.self) private var model
    let tile: Binding<DockTile>

    var body: some View {
        let apps = tile.wrappedValue.collectionApps ?? []
        Picker("Layout", selection: layout) {
            ForEach(CollectionLayout.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        if apps.isEmpty {
            Text("No apps in this collection yet.").foregroundStyle(.secondary)
        }
        ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
            HStack(spacing: 10) {
                AppIconView(app: app, size: 22, showsIndicator: false, badgeStyle: .hidden)
                Text(verbatim: model.workspace.displayName(for: app))
                Spacer()
                Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0)
                Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(index == apps.count - 1)
                Button(role: .destructive) {
                    var next = apps
                    next.remove(at: index)
                    tile.wrappedValue.collectionApps = next
                } label: { Image(systemName: "trash") }
            }
            .buttonStyle(.borderless)
        }
        HStack {
            Button("Add Application…") { chooseApps() }
            Menu("Add Running App") {
                ForEach(model.workspace.runningRegularApps()) { app in
                    Button(app.name) { model.addApps([app], toCollection: tile.wrappedValue.id) }
                }
            }
            .fixedSize()
        }
        Text("You can also drop apps on the tile, or right-click an app on the Dock and choose Create Collection.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var layout: Binding<CollectionLayout> {
        Binding(get: { tile.wrappedValue.collectionLayout ?? .grid }, set: { tile.wrappedValue.collectionLayout = $0 })
    }

    private func move(_ index: Int, by offset: Int) {
        guard var apps = tile.wrappedValue.collectionApps, apps.indices.contains(index), apps.indices.contains(index + offset) else { return }
        apps.swapAt(index, index + offset)
        tile.wrappedValue.collectionApps = apps
    }

    private func chooseApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = L10n.tr("Add")
        guard panel.runModal() == .OK else { return }
        model.addApps(panel.urls.map(DockApp.init(url:)), toCollection: tile.wrappedValue.id)
    }
}

private struct ShortcutEditor: View {
    @Environment(AppModel.self) private var model
    let tile: Binding<DockTile>

    static let symbols = [
        "square.3.layers.3d", "bolt.fill", "wand.and.stars", "sparkles", "play.fill", "house.fill",
        "lightbulb.fill", "moon.fill", "sun.max.fill", "cup.and.saucer.fill", "timer", "envelope.fill",
    ]

    var body: some View {
        let runner = model.fileWidgets.shortcuts
        LabeledContent("Shortcut") {
            HStack {
                TextField("Shortcut", text: text(\.shortcutName), prompt: Text("Name in the Shortcuts app"))
                    .labelsHidden()
                Menu("Choose") {
                    if runner.names.isEmpty {
                        Text(runner.isLoadingNames ? L10n.tr("Loading…") : L10n.tr("No shortcuts found"))
                    }
                    ForEach(runner.names, id: \.self) { name in
                        Button(name) { tile.wrappedValue.shortcutName = name }
                    }
                }
                .fixedSize()
            }
        }
        .task { await runner.loadNames() }
        LabeledContent("Symbol") {
            HStack(spacing: 6) {
                ForEach(Self.symbols, id: \.self) { symbol in
                    Button {
                        tile.wrappedValue.shortcutSymbol = symbol
                    } label: {
                        Image(systemName: symbol)
                            .frame(width: 20, height: 20)
                            .background {
                                if tile.wrappedValue.shortcutSymbolName == symbol {
                                    RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.25))
                                }
                            }
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        TextField("SF Symbol name", text: text(\.shortcutSymbol), prompt: Text(verbatim: tile.wrappedValue.kind.symbol))
        ColorPicker("Color", selection: tint, supportsOpacity: false)
        Text("Clicking the tile runs the shortcut in the background, like `shortcuts run` in Terminal. Right-click › Show Details to see how it went.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func text(_ keyPath: WritableKeyPath<DockTile, String?>) -> Binding<String> {
        Binding(
            get: { tile.wrappedValue[keyPath: keyPath] ?? "" },
            set: { tile.wrappedValue[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }

    private var tint: Binding<Color> {
        Binding(
            get: { Color(hex: tile.wrappedValue.shortcutTintHex) ?? model.accent },
            set: { tile.wrappedValue.shortcutTintHex = $0.hexString }
        )
    }
}

/// Settings › Behavior: the Drop Zone.
struct DropZoneSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            Toggle(isOn: model.binding(\.behavior.dropZone)) {
                Text("Show a Drop Zone while you drag files")
                Text("A tray appears while you drag files from any app. Drop them on it to keep them on the Shelf; it goes away when you let go.")
            }
            Picker("Position", selection: model.binding(\.behavior.dropZonePlacement)) {
                ForEach(DropZonePlacement.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(!model.config.behavior.dropZone)
        } header: {
            Text("Drop Zone")
        }
    }
}
