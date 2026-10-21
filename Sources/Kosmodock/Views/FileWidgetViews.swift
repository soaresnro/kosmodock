import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Tiles and details of the file and sharing widgets: screenshots, shelf,
// recent files, bookmarks, app collection, shortcut and AirDrop (their
// settings are in FileWidgetViews+Settings.swift). Files are dragged out
// through `FileDragSource` (AppKit, so a shelf learns whether the drop was
// taken) and dropped in through `fileWidgetDropTarget`.

// MARK: - Bar tiles

struct FileWidgetTile: View {
    let tile: DockTile
    let isWide: Bool

    var body: some View {
        switch tile.kind {
        case .screenshots: ScreenshotsTile(tile: tile, isWide: isWide)
        case .shelf: ShelfTile(tile: tile, isWide: isWide)
        case .files: RecentFilesTile(tile: tile, isWide: isWide)
        case .bookmarks: BookmarksTile(tile: tile, isWide: isWide)
        case .appCollection: CollectionTile(tile: tile, isWide: isWide)
        case .shortcut: ShortcutTile(tile: tile, isWide: isWide)
        case .airDrop: AirDropTile(isWide: isWide)
        default: EmptyView()
        }
    }
}

/// A wide tile's two lines: a small title and its reading.
private struct TileCaption: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased())
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 10.5, weight: .semibold))
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CountBadge: View {
    let count: Int
    let color: Color

    var body: some View {
        Text(verbatim: count > 99 ? "99+" : "\(count)")
            .font(.system(size: 8.5, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 3.5)
            .frame(minWidth: 14, minHeight: 14)
            .background(Capsule().fill(color))
    }
}

private struct PlaceholderSymbol: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 26, height: 26)
    }
}

private struct ScreenshotsTile: View {
    @Environment(AppModel.self) private var model
    let tile: DockTile
    let isWide: Bool

    var body: some View {
        let latest = model.fileWidgets.feeds[tile.id]?.entries.first
        let preview = Group {
            if let latest {
                FileThumbnail(url: latest.url, side: 28)
            } else {
                PlaceholderSymbol(symbol: tile.kind.symbol)
            }
        }
        if isWide {
            HStack(spacing: 7) {
                preview
                TileCaption(
                    title: L10n.tr("Screenshots"),
                    value: latest.map { $0.date.formatted(.dateTime.hour().minute().locale(L10n.locale)) } ?? L10n.tr("None yet")
                )
            }
        } else {
            preview
        }
    }
}

private struct ShelfTile: View {
    @Environment(AppModel.self) private var model
    let tile: DockTile
    let isWide: Bool

    var body: some View {
        let urls = tile.shelfURLs
        Group {
            if isWide {
                HStack(spacing: 7) {
                    StackedFileIcons(urls: urls, size: 24)
                    TileCaption(
                        title: L10n.tr("Shelf"),
                        value: urls.isEmpty ? L10n.tr("Drop files here") : (urls.count == 1 ? L10n.tr("1 file") : L10n.tr("%lld files", urls.count))
                    )
                }
            } else {
                StackedFileIcons(urls: urls, size: 24)
                    .overlay(alignment: .topTrailing) {
                        if urls.count > 1 { CountBadge(count: urls.count, color: model.accent).offset(x: 5, y: -4) }
                    }
            }
        }
        // Drag the whole shelf out of the tile.
        .overlay {
            if !urls.isEmpty {
                FileDragSource(urls: urls, help: tile.title, onClick: { model.activate(tile) }, onEnded: { accepted in
                    model.shelfDragEnded(urls, tileID: tile.id, accepted: accepted)
                })
            }
        }
    }
}

/// Up to three file icons, fanned out; a tray when there's none.
private struct StackedFileIcons: View {
    let urls: [URL]
    let size: CGFloat

    var body: some View {
        if urls.isEmpty {
            PlaceholderSymbol(symbol: "tray.and.arrow.down")
        } else {
            ZStack {
                ForEach(Array(urls.prefix(3).enumerated().reversed()), id: \.offset) { index, url in
                    FileIcon(url: url, size: size)
                        .rotationEffect(.degrees(Double(index) * 8))
                        .offset(x: CGFloat(index) * 3, y: CGFloat(index) * -1.5)
                }
            }
            .frame(width: size + 6, height: size)
        }
    }
}

private struct RecentFilesTile: View {
    @Environment(AppModel.self) private var model
    let tile: DockTile
    let isWide: Bool

    var body: some View {
        let service = model.fileWidgets
        let newCount = service.newCount(for: tile)
        let icon = FileIcon(url: tile.folderURL, size: 26)
            .overlay(alignment: .topTrailing) {
                if newCount > 0 { CountBadge(count: newCount, color: HealthLevel.critical.color).offset(x: 5, y: -4) }
            }
        if isWide {
            let latest = service.feeds[tile.id]?.entries.first
            HStack(spacing: 7) {
                icon
                TileCaption(
                    title: FileManager.default.displayName(atPath: tile.folderURL.path),
                    value: newCount > 0 ? L10n.tr("%lld new", newCount) : (latest?.name ?? L10n.tr("Empty"))
                )
            }
        } else {
            icon
        }
    }
}

private struct BookmarksTile: View {
    @Environment(AppModel.self) private var model
    let tile: DockTile
    let isWide: Bool

    var body: some View {
        let bookmarks = tile.bookmarks ?? []
        if isWide, !bookmarks.isEmpty {
            VStack(spacing: 3) {
                ForEach(Array(bookmarks.prefix(2).enumerated()), id: \.offset) { _, bookmark in
                    Button {
                        model.dismissPopover?()
                        FileActions.open(bookmark, browser: tile.bookmarkBrowser)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "link").font(.system(size: 8, weight: .bold)).foregroundStyle(model.accent)
                            Text(bookmark.displayTitle).font(.system(size: 9.5, weight: .semibold)).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 5)
                        .frame(height: 15)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(bookmark.resolvedURL?.absoluteString ?? bookmark.url)
                }
            }
        } else if isWide {
            HStack(spacing: 7) {
                PlaceholderSymbol(symbol: tile.kind.symbol)
                TileCaption(title: L10n.tr("Bookmarks"), value: L10n.tr("No links yet"))
            }
        } else {
            VStack(spacing: 1) {
                Image(systemName: "link")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(model.accent)
                Text(verbatim: "\(bookmarks.count)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct CollectionTile: View {
    @Environment(AppModel.self) private var model
    let tile: DockTile
    let isWide: Bool

    var body: some View {
        let apps = tile.collectionApps ?? []
        if apps.isEmpty {
            PlaceholderSymbol(symbol: tile.kind.symbol)
        } else if isWide {
            HStack(spacing: 4) {
                ForEach(apps.prefix(3)) { app in
                    AppIconView(app: app, size: 24, showsIndicator: false, badgeStyle: .hidden)
                }
                if apps.count > 3 {
                    Text(verbatim: "+\(apps.count - 3)")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        } else {
            // A 2 × 2 preview, like a folder.
            let preview = Array(apps.prefix(4))
            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                ForEach([0, 2], id: \.self) { start in
                    GridRow {
                        ForEach(start..<start + 2, id: \.self) { index in
                            if index < preview.count {
                                AppIconView(app: preview[index], size: 14, showsIndicator: false, badgeStyle: .hidden)
                            } else {
                                Color.clear.frame(width: 14, height: 14)
                            }
                        }
                    }
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.08)))
        }
    }
}

private struct ShortcutTile: View {
    @Environment(AppModel.self) private var model
    let tile: DockTile
    let isWide: Bool

    var body: some View {
        let glyph = ShortcutGlyph(tile: tile, size: 26)
        if isWide {
            HStack(spacing: 7) {
                glyph
                TileCaption(title: L10n.tr("Shortcut"), value: tile.shortcutName.flatMap { $0.isBlank ? nil : $0 } ?? L10n.tr("Choose one"))
            }
        } else {
            glyph
        }
    }
}

/// The shortcut's symbol on its color, with its run's state.
private struct ShortcutGlyph: View {
    @Environment(AppModel.self) private var model
    let tile: DockTile
    let size: CGFloat

    var body: some View {
        let state = model.fileWidgets.shortcuts.state(for: tile.id)
        let tint = Color(hex: tile.shortcutTintHex) ?? model.accent
        ZStack {
            switch state {
            case .running:
                GroupGlyph(symbol: tile.shortcutSymbolName, tint: tint, size: size).opacity(0.45)
                ProgressView().controlSize(.small).scaleEffect(0.7)
            case .succeeded:
                GroupGlyph(symbol: "checkmark", tint: HealthLevel.ok.color, size: size)
            case .failed(let message):
                GroupGlyph(symbol: "exclamationmark.triangle.fill", tint: HealthLevel.critical.color, size: size)
                    .help(message)
            case .idle:
                GroupGlyph(symbol: tile.shortcutSymbolName, tint: tint, size: size)
            }
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.2), value: state)
    }
}

extension DockTile {
    /// The chosen SF Symbol when it exists, otherwise the kind's.
    var shortcutSymbolName: String {
        if let symbol = shortcutSymbol?.trimmingCharacters(in: .whitespaces), !symbol.isEmpty,
           NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil {
            return symbol
        }
        return kind.symbol
    }
}

private struct AirDropTile: View {
    let isWide: Bool

    var body: some View {
        let glyph = AirDropGlyph(size: 26)
        if isWide {
            HStack(spacing: 7) {
                glyph
                TileCaption(title: "AirDrop", value: L10n.tr("Drop to send"))
            }
        } else {
            glyph
        }
    }
}

private struct AirDropGlyph: View {
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(LinearGradient(colors: [Color(red: 0.25, green: 0.65, blue: 1), Color(red: 0.05, green: 0.4, blue: 0.95)], startPoint: .top, endPoint: .bottom))
            .overlay {
                Image(systemName: TileKind.airDrop.symbol)
                    .font(.system(size: size * 0.44, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
    }
}

// MARK: - Details

/// The popover content of a file or sharing widget.
struct FileWidgetDetails: View {
    let tile: DockTile

    var body: some View {
        switch tile.kind {
        case .screenshots: ScreenshotsDetails(tile: tile)
        case .shelf: ShelfDetails(tile: tile)
        case .files: RecentFilesDetails(tile: tile)
        case .bookmarks: BookmarksDetails(tile: tile)
        case .appCollection: CollectionDetails(tile: tile)
        case .shortcut: ShortcutDetails(tile: tile)
        case .airDrop: AirDropDetails()
        default: EmptyView()
        }
    }
}

/// The content as it is while it fits `maxHeight`; past that, a scroll view
/// that tall. The popover is sized from its content, so a scroll view needs a
/// fixed height, and short lists shouldn't get one.
private struct CappedScroll<Content: View>: View {
    let contentHeight: CGFloat
    let maxHeight: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        if contentHeight > maxHeight {
            ScrollView(.vertical) { content }
                .frame(height: maxHeight)
        } else {
            content
        }
    }
}

private struct DetailsHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The folder a widget reads, with a button to open it.
private struct FolderFooter: View {
    @Environment(AppModel.self) private var model
    let folder: URL

    var body: some View {
        HStack(spacing: 6) {
            FileIcon(url: folder, size: 16)
            Text(verbatim: (folder.path as NSString).abbreviatingWithTildeInPath)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            Button("Open Folder") {
                model.dismissPopover?()
                NSWorkspace.shared.open(folder)
            }
            .buttonStyle(GlassPillButtonStyle(tint: model.accent))
        }
    }
}

private struct ScreenshotsDetails: View {
    @Environment(AppModel.self) private var model
    let tile: DockTile
    private let columns = 4
    private let spacing: CGFloat = 8
    private let side: CGFloat = 71

    var body: some View {
        let feed = model.fileWidgets.feeds[tile.id]
        let entries = model.fileWidgets.entries(for: tile)
        let folder = feed?.folder ?? ScreenshotDetector.currentFolder()
        VStack(alignment: .leading, spacing: 10) {
            if entries.isEmpty {
                DetailsHint(text: feed?.isReadable == false
                    ? L10n.tr("Kosmodock can't read %@. Allow it in System Settings › Privacy & Security › Files and Folders.", folder.lastPathComponent)
                    : L10n.tr("No screenshots yet. Press ⇧⌘3 for the screen or ⇧⌘4 for an area."))
            } else {
                let rows = (entries.count + columns - 1) / columns
                CappedScroll(contentHeight: CGFloat(rows) * (side + spacing) - spacing, maxHeight: 4 * (side + spacing) - spacing + side / 2) {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(side), spacing: spacing), count: columns), spacing: spacing) {
                        ForEach(entries) { entry in
                            ScreenshotCell(entry: entry, tile: tile, side: side)
                        }
                    }
                }
                Text(Self.hint(for: tile.clickAction))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            FolderFooter(folder: folder)
        }
    }

    static func hint(for action: FileClickAction) -> String {
        switch action {
        case .open: L10n.tr("Click a screenshot to open it, or drag it anywhere.")
        case .reveal: L10n.tr("Click a screenshot to show it in the Finder, or drag it anywhere.")
        case .copy: L10n.tr("Click a screenshot to copy it, or drag it anywhere.")
        }
    }
}

private struct ScreenshotCell: View {
    @Environment(AppModel.self) private var model
    let entry: FileEntry
    let tile: DockTile
    let side: CGFloat
    @ViewState private var isHovering = false

    var body: some View {
        FileThumbnail(url: entry.url, side: side)
            .overlay {
                RoundedRectangle(cornerRadius: side * 0.16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isHovering ? 0.45 : 0.12), lineWidth: isHovering ? 1.5 : 0.5)
            }
            .overlay {
                FileDragSource(urls: [entry.url], help: helpText, onClick: open)
            }
            .onHover { isHovering = $0 }
            .contextMenu { FileContextMenu(url: entry.url, isImage: true) }
    }

    private var helpText: String {
        "\(entry.name)\n\(entry.date.formatted(date: .abbreviated, time: .shortened))"
    }

    private func open() {
        if tile.clickAction != .copy { model.dismissPopover?() }
        FileActions.perform(tile.clickAction, on: entry.url)
    }
}

/// Right-click actions shared by the file lists.
private struct FileContextMenu: View {
    @Environment(AppModel.self) private var model
    let url: URL
    var isImage = false

    var body: some View {
        Button("Open") {
            model.dismissPopover?()
            NSWorkspace.shared.open(url)
        }
        Button("Show in Finder") {
            model.dismissPopover?()
            FileActions.reveal([url])
        }
        if isImage {
            Button("Copy Image") { FileActions.copyImage(at: url) }
        }
        Divider()
        Button("Send with AirDrop") { FileActions.sendViaAirDrop([url]) }
    }
}

private struct RecentFilesDetails: View {
    @Environment(AppModel.self) private var model
    let tile: DockTile
    private let rowHeight: CGFloat = 34

    var body: some View {
        let service = model.fileWidgets
        let entries = service.entries(for: tile)
        VStack(alignment: .leading, spacing: 10) {
            if entries.isEmpty {
                DetailsHint(text: service.feeds[tile.id]?.isReadable == false
                    ? L10n.tr("Kosmodock can't read %@. Allow it in System Settings › Privacy & Security › Files and Folders.", tile.folderURL.lastPathComponent)
                    : L10n.tr("This folder is empty."))
            } else {
                CappedScroll(contentHeight: CGFloat(entries.count) * (rowHeight + 2), maxHeight: 8.5 * (rowHeight + 2)) {
                    LazyVStack(spacing: 2) {
                        ForEach(entries) { entry in
                            FileRow(
                                url: entry.url,
                                detail: entry.date.formatted(.relative(presentation: .named).locale(L10n.locale)),
                                isNew: service.isNew(entry, in: tile),
                                onClick: {
                                    model.dismissPopover?()
                                    FileActions.perform(tile.clickAction, on: entry.url)
                                }
                            )
                        }
                    }
                }
            }
            FolderFooter(folder: tile.folderURL)
        }
        .onAppear { service.markSeen(tileID: tile.id) }
        .onDisappear { service.detailsClosed(tileID: tile.id) }
    }
}

/// A file: icon, name and a detail line; it opens on click and drags out.
private struct FileRow<Trailing: View>: View {
    let url: URL
    let detail: String
    var isNew = false
    var isMissing = false
    var onClick: () -> Void
    var onDragEnded: ((Bool) -> Void)?
    @ViewBuilder var trailing: Trailing
    @ViewState private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                FileIcon(url: url, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: url.lastPathComponent)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(detail)
                        .font(.system(size: 9.5))
                        .foregroundStyle(isMissing ? AnyShapeStyle(HealthLevel.warning.color) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if isNew {
                    Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                }
            }
            .contentShape(Rectangle())
            .overlay {
                FileDragSource(urls: [url], help: url.path, onClick: onClick, onEnded: onDragEnded)
            }
            trailing
        }
        .opacity(isMissing ? 0.55 : 1)
        .padding(.horizontal, 6)
        .frame(height: 34)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(isHovering ? 0.08 : 0))
        }
        .onHover { isHovering = $0 }
        .contextMenu { FileContextMenu(url: url) }
    }
}

extension FileRow where Trailing == EmptyView {
    init(url: URL, detail: String, isNew: Bool = false, isMissing: Bool = false, onClick: @escaping () -> Void, onDragEnded: ((Bool) -> Void)? = nil) {
        self.init(url: url, detail: detail, isNew: isNew, isMissing: isMissing, onClick: onClick, onDragEnded: onDragEnded) { EmptyView() }
    }
}

private struct ShelfDetails: View {
    @Environment(AppModel.self) private var model
    let tile: DockTile

    var body: some View {
        let urls = tile.shelfURLs
        VStack(alignment: .leading, spacing: 10) {
            if urls.isEmpty {
                DetailsHint(text: L10n.tr("Drop files on the Shelf to keep them at hand, then drag them out where you need them. The files stay where they are."))
            } else {
                HStack(spacing: 8) {
                    Label(L10n.tr("Drag All"), systemImage: "hand.draw")
                        .font(.system(size: 11.5, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                        .overlay {
                            FileDragSource(urls: urls, help: L10n.tr("Drag every file on the Shelf"), onEnded: { accepted in
                                model.shelfDragEnded(urls, tileID: tile.id, accepted: accepted)
                            })
                        }
                    Spacer()
                    Button("Clear Shelf") { model.clearShelf(tileID: tile.id) }
                        .buttonStyle(GlassPillButtonStyle(tint: model.accent))
                }
                CappedScroll(contentHeight: CGFloat(urls.count) * 36, maxHeight: 8.5 * 36) {
                    LazyVStack(spacing: 2) {
                        ForEach(urls, id: \.path) { url in
                            let exists = FileManager.default.fileExists(atPath: url.path)
                            FileRow(
                                url: url,
                                detail: exists ? (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath : L10n.tr("Moved or deleted"),
                                isMissing: !exists,
                                onClick: {
                                    model.dismissPopover?()
                                    NSWorkspace.shared.open(url)
                                },
                                onDragEnded: { accepted in model.shelfDragEnded([url], tileID: tile.id, accepted: accepted) }
                            ) {
                                Button {
                                    model.removeFromShelf([url], tileID: tile.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Remove from Shelf")
                            }
                        }
                    }
                }
                Text(tile.removesOnDragOut == true
                    ? L10n.tr("A file you drag out leaves the Shelf.")
                    : L10n.tr("Files stay on the Shelf after you drag them out."))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct BookmarksDetails: View {
    @Environment(AppModel.self) private var model
    let tile: DockTile

    var body: some View {
        let bookmarks = tile.bookmarks ?? []
        if bookmarks.isEmpty {
            DetailsHint(text: L10n.tr("Add links in Settings › Widgets."))
        } else {
            CappedScroll(contentHeight: CGFloat(bookmarks.count) * 36, maxHeight: 9.5 * 36) {
                LazyVStack(spacing: 2) {
                    ForEach(Array(bookmarks.enumerated()), id: \.offset) { _, bookmark in
                        BookmarkRow(bookmark: bookmark) {
                            model.dismissPopover?()
                            FileActions.open(bookmark, browser: tile.bookmarkBrowser)
                        }
                    }
                }
            }
        }
    }
}

private struct BookmarkRow: View {
    @Environment(AppModel.self) private var model
    let bookmark: Bookmark
    let action: () -> Void
    @ViewState private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: "link")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(model.accent.gradient))
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: bookmark.displayTitle)
                        .font(.system(size: 11.5, weight: .medium))
                    Text(verbatim: bookmark.resolvedURL?.host() ?? bookmark.url)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 6)
            .frame(height: 34)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.08 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(bookmark.resolvedURL == nil)
        .onHover { isHovering = $0 }
        .help(bookmark.resolvedURL?.absoluteString ?? bookmark.url)
    }
}

private struct CollectionDetails: View {
    @Environment(AppModel.self) private var model
    let tile: DockTile

    var body: some View {
        let apps = tile.collectionApps ?? []
        if apps.isEmpty {
            DetailsHint(text: L10n.tr("Add apps in Settings › Widgets, or drop them on the tile."))
        } else {
            switch tile.collectionLayout ?? .grid {
            case .grid:
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 8) {
                    ForEach(apps) { CollectionAppButton(app: $0, iconSize: 42, showsName: true) }
                }
            case .horizontal:
                let row = HStack(spacing: 6) {
                    ForEach(apps) { CollectionAppButton(app: $0, iconSize: 40, showsName: true).frame(width: 64) }
                }
                // Four fit the popover's width.
                if apps.count > 4 {
                    ScrollView(.horizontal) { row }
                } else {
                    row.frame(maxWidth: .infinity, alignment: .leading)
                }
            case .vertical:
                CappedScroll(contentHeight: CGFloat(apps.count) * 36, maxHeight: 8.5 * 36) {
                    LazyVStack(spacing: 2) {
                        ForEach(apps) { CollectionAppRow(app: $0) }
                    }
                }
            }
        }
    }
}

private struct CollectionAppButton: View {
    @Environment(AppModel.self) private var model
    let app: DockApp
    let iconSize: CGFloat
    let showsName: Bool
    @ViewState private var isHovering = false

    var body: some View {
        Button {
            model.open(app)
        } label: {
            VStack(spacing: 5) {
                AppIconView(app: app, size: iconSize, badgeStyle: .dot)
                    .scaleEffect(isHovering && model.theme.hoverEffect != .none ? 1.08 : 1, anchor: .bottom)
                if showsName {
                    Text(verbatim: model.workspace.displayName(for: app))
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.08 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(model.spring, value: isHovering)
        .onHover { isHovering = $0 }
        .help(model.workspace.displayName(for: app))
    }
}

private struct CollectionAppRow: View {
    @Environment(AppModel.self) private var model
    let app: DockApp
    @ViewState private var isHovering = false

    var body: some View {
        Button {
            model.open(app)
        } label: {
            HStack(spacing: 9) {
                AppIconView(app: app, size: 26, showsIndicator: false, badgeStyle: .dot)
                Text(verbatim: model.workspace.displayName(for: app))
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if model.workspace.isRunning(app) {
                    Circle().fill(model.accent).frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 34)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.08 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct ShortcutDetails: View {
    @Environment(AppModel.self) private var model
    let tile: DockTile

    var body: some View {
        let runner = model.fileWidgets.shortcuts
        let state = runner.state(for: tile.id)
        if let name = tile.shortcutName, !name.isBlank {
            BentoCard(title: L10n.tr("Shortcut"), symbol: tile.shortcutSymbolName) {
                VStack(alignment: .leading, spacing: 8) {
                    // The name is the popover's title already.
                    HStack(spacing: 10) {
                        ShortcutGlyph(tile: tile, size: 34)
                        Text(Self.status(state))
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(state.isFailure ? AnyShapeStyle(HealthLevel.critical.color) : AnyShapeStyle(.secondary))
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        Button("Run") { runner.run(tile) }
                            .buttonStyle(GlassPillButtonStyle(tint: Color(hex: tile.shortcutTintHex) ?? model.accent, prominent: true))
                            .disabled(state == .running)
                        Button("Open in Shortcuts") {
                            model.dismissPopover?()
                            ShortcutsRunner.edit(name)
                        }
                        .buttonStyle(GlassPillButtonStyle(tint: model.accent))
                    }
                }
            }
        } else {
            DetailsHint(text: L10n.tr("Choose a shortcut in Settings › Widgets. Clicking the tile then runs it."))
        }
    }

    static func status(_ state: ShortcutsRunner.RunState) -> String {
        switch state {
        case .idle: L10n.tr("Click the tile to run it.")
        case .running: L10n.tr("Running…")
        case .succeeded: L10n.tr("Done")
        case .failed(let message): message
        }
    }
}

private extension ShortcutsRunner.RunState {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

private struct AirDropDetails: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AirDropGlyph(size: 34)
                DetailsHint(text: L10n.tr("Drop files on the tile to send them with AirDrop. Clicking it opens AirDrop in the Finder."))
            }
            HStack(spacing: 8) {
                Button("Choose Files…") { chooseFiles() }
                    .buttonStyle(GlassPillButtonStyle(tint: model.accent, prominent: true))
                Button("Open AirDrop") {
                    model.dismissPopover?()
                    FileActions.openAirDrop()
                }
                .buttonStyle(GlassPillButtonStyle(tint: model.accent))
            }
        }
    }

    private func chooseFiles() {
        model.dismissPopover?()
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = L10n.tr("Send")
        guard panel.runModal() == .OK else { return }
        FileActions.sendViaAirDrop(panel.urls)
    }
}

// MARK: - Files and thumbnails

struct FileIcon: View {
    let url: URL
    let size: CGFloat

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }
}

/// A Quick Look thumbnail cropped to a square, the file's icon until it loads.
struct FileThumbnail: View {
    let url: URL
    let side: CGFloat
    @ViewState private var image: NSImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: side * 0.16, style: .continuous)
        Group {
            if let image = image ?? ThumbnailLoader.shared.cached(url, side: side) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                FileIcon(url: url, size: side * 0.8)
            }
        }
        .frame(width: side, height: side)
        .background(shape.fill(Color.primary.opacity(0.06)))
        .clipShape(shape)
        .task(id: url) {
            image = ThumbnailLoader.shared.cached(url, side: side)
            if image == nil { image = await ThumbnailLoader.shared.thumbnail(for: url, side: side) }
        }
    }
}

// MARK: - Dropping files on tiles

extension View {
    /// Shelf, AirDrop and app collection tiles take files dropped on them.
    func fileWidgetDropTarget(_ tile: DockTile) -> some View {
        modifier(FileDropTarget(tile: tile))
    }
}

private struct FileDropTarget: ViewModifier {
    @Environment(AppModel.self) private var model
    let tile: DockTile
    @ViewState private var isTargeted = false

    static let kinds: Set<TileKind> = [.shelf, .airDrop, .appCollection]

    func body(content: Content) -> some View {
        if Self.kinds.contains(tile.kind) {
            content
                .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                    FileDrop.loadURLs(from: providers) { urls in model.dropFiles(urls, on: tile) }
                    return true
                }
                .overlay {
                    if isTargeted {
                        RoundedRectangle(cornerRadius: model.theme.capsuleRadius, style: .continuous)
                            .strokeBorder(model.accent, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                            .allowsHitTesting(false)
                    }
                }
                .scaleEffect(isTargeted ? 1.08 : 1, anchor: .bottom)
                .animation(.easeOut(duration: 0.15), value: isTargeted)
        } else {
            content
        }
    }
}

enum FileDrop {
    /// File URLs of the dropped items, in their order, on the main actor.
    static func loadURLs(from providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
        final class Collected: @unchecked Sendable {
            let lock = NSLock()
            var urls: [Int: URL] = [:]
        }
        let collected = Collected()
        let group = DispatchGroup()
        for (index, provider) in providers.enumerated() where provider.canLoadObject(ofClass: NSURL.self) {
            group.enter()
            _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                // Finder may hand over file reference URLs (file:///.file/id=…).
                if let url = (object as? NSURL)?.filePathURL ?? (object as? NSURL).map({ $0 as URL }), url.isFileURL {
                    collected.lock.lock()
                    collected.urls[index] = url.standardizedFileURL
                    collected.lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated {
                completion(collected.urls.sorted { $0.key < $1.key }.map(\.value))
            }
        }
    }
}

// MARK: - Dragging files out

/// Makes the view it overlays a drag source for `urls`. A plain click calls
/// `onClick`; right and Control clicks fall through to SwiftUI's context menu.
/// `onEnded` learns whether another app took the files: a drop on Kosmodock's
/// own tiles (AirDrop, or the shelf itself) doesn't count as dragging out.
/// Files are offered as copies, so dropping them never moves the originals.
struct FileDragSource: NSViewRepresentable {
    var urls: [URL]
    var help: String?
    var onClick: (() -> Void)?
    var onEnded: ((Bool) -> Void)?

    func makeNSView(context: Context) -> DragSourceView {
        let view = DragSourceView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: DragSourceView, context: Context) {
        view.urls = urls
        view.onClick = onClick
        view.onEnded = onEnded
        view.toolTip = help
    }

    final class DragSourceView: NSView, NSDraggingSource {
        var urls: [URL] = []
        var onClick: (() -> Void)?
        var onEnded: ((Bool) -> Void)?
        private var mouseDown: NSEvent?
        private var isDragging = false

        override func hitTest(_ point: NSPoint) -> NSView? {
            if let event = NSApp.currentEvent, Self.passesThrough(event) { return nil }
            return super.hitTest(point)
        }

        static func passesThrough(_ event: NSEvent) -> Bool {
            switch event.type {
            case .rightMouseDown, .rightMouseUp, .rightMouseDragged, .otherMouseDown, .otherMouseUp, .otherMouseDragged:
                true
            case .leftMouseDown, .leftMouseUp:
                event.modifierFlags.contains(.control)
            default:
                false
            }
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            mouseDown = event
            isDragging = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard !isDragging, let start = mouseDown, !urls.isEmpty else { return }
            let distance = hypot(event.locationInWindow.x - start.locationInWindow.x, event.locationInWindow.y - start.locationInWindow.y)
            guard distance > 3 else { return }
            isDragging = true
            let point = convert(start.locationInWindow, from: nil)
            let side: CGFloat = 44
            let items = urls.prefix(DockTile.shelfLimit).enumerated().map { index, url -> NSDraggingItem in
                let item = NSDraggingItem(pasteboardWriter: url as NSURL)
                let offset = CGFloat(min(index, 4)) * 4
                item.setDraggingFrame(
                    NSRect(x: point.x - side / 2 + offset, y: point.y - side / 2 - offset, width: side, height: side),
                    contents: NSWorkspace.shared.icon(forFile: url.path)
                )
                return item
            }
            let session = beginDraggingSession(with: items, event: start, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = true
            session.draggingFormation = .pile
        }

        override func mouseUp(with event: NSEvent) {
            defer { mouseDown = nil }
            if !isDragging, mouseDown != nil { onClick?() }
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .copy
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            isDragging = false
            let ownWindow = NSApp.windows.contains { $0.isVisible && $0.frame.contains(screenPoint) }
            onEnded?(!operation.isEmpty && !ownWindow)
        }
    }
}
