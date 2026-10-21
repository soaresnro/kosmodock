#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only: `Kosmodock --render-snapshots <dir>` samples live
/// telemetry for a few seconds, renders the dock (bento + accordion) and every
/// group's popover to PNG, then exits. `ImageRenderer` can't draw behind-window
/// vibrancy, so a gradient stands in for the desktop.
@MainActor
enum SnapshotRenderer {
    static var requestedDirectory: URL? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--render-snapshots"), index + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[index + 1])
    }

    /// `--language pt-BR|es-ES|en-US` (in-memory only; config.json is untouched).
    static var requestedLanguage: AppLanguage? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--language"), index + 1 < arguments.count else { return nil }
        return AppLanguage(rawValue: arguments[index + 1])
    }

    private static var language: AppLanguage = .system

    static func run(model: AppModel, to directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // UserDefaults ignores CFFIXED_USER_HOME: keep the snapshot's state in memory.
        model.fileWidgets.persistsSeenDates = false
        if let requested = requestedLanguage {
            language = requested
            L10n.setLanguage(requested)
        }
        // The config's tiles, or one of each kind, sampled before rendering.
        let tiles = model.config.tiles
        model.configService.preview { config in
            guard config.tiles.isEmpty else { return }
            config.tiles = TileKind.allCases.map { kind in
                var tile = DockTile(id: kind.rawValue, kind: kind)
                if kind == .command { tile.label = "Build"; tile.command = "echo 'All green'" }
                return tile
            }
        }
        model.telemetry.start()
        model.containers.setEnabled(true)
        // Folder stacks, kept off UserDefaults: what arrived today is new.
        model.folderStacks.seen = FolderSeenStore(defaults: nil)
        for folder in model.config.folders { model.folderStacks.seen.markSeen(folder.id, at: Date().addingTimeInterval(-86_400)) }
        model.startDockItems()
        model.fileWidgets.update(tiles: model.config.tiles)
        try? await Task.sleep(for: .seconds(7))

        injectSampleMinimizedWindows(into: model)
        injectSampleNotificationBadges(into: model)
        let width = model.dockMaxWidth + DockMetrics.shadowInset * 2
        let geometry = GroupGeometryTracker()

        write(DockRootView(geometry: geometry), model: model, proposed: CGSize(width: width, height: 150), name: "dock-tiles", in: directory)
        for tile in model.config.tiles {
            write(TilePopoverView(tileID: tile.id).fixedSize(), model: model, proposed: nil, name: "popover-tile-\(tile.id)", in: directory)
        }
        model.configService.preview { config in
            for index in config.tiles.indices { config.tiles[index].width = .square }
        }
        write(DockRootView(geometry: geometry), model: model, proposed: CGSize(width: width, height: 150), name: "dock-tiles-square", in: directory)
        model.configService.preview { $0.tiles = tiles }
        write(DockRootView(geometry: geometry), model: model, proposed: CGSize(width: width, height: 150), name: "dock", in: directory)
        let folders = model.config.folders
        for folder in folders {
            for layout in FolderLayout.allCases {
                model.configService.preview { config in
                    guard let index = config.folders.firstIndex(where: { $0.id == folder.id }) else { return }
                    config.folders[index].layout = layout
                }
                write(FolderStackPopoverView(folderID: folder.id).fixedSize(), model: model, proposed: nil, name: "popover-folder-\(folder.id)-\(layout.rawValue)", in: directory)
            }
        }
        model.configService.preview { $0.folders = folders }
        model.keyboardFocusItemID = model.barItems.dropFirst().first?.id
        write(DockRootView(geometry: geometry), model: model, proposed: CGSize(width: width, height: 150), name: "dock-focus", in: directory)
        model.keyboardFocusItemID = nil
        if let app = model.config.groups.first?.apps.first {
            write(WindowPreviewCardsView.sample(app: app), model: model, proposed: nil, name: "window-previews", in: directory)
        }

        let theme = model.config.theme
        for style in DockStyle.allCases {
            model.configService.preview { $0.theme.apply(style) }
            write(DockRootView(geometry: geometry), model: model, proposed: CGSize(width: width, height: 150), name: "dock-style-\(style.rawValue)", in: directory)
        }
        model.configService.preview { $0.theme = theme }
        write(
            HStack(spacing: 10) { ForEach(DockStyle.allCases) { DockStylePreview(surface: $0.surface, accent: model.accent).frame(width: 140) } },
            model: model, proposed: nil, name: "style-previews", in: directory
        )

        for group in model.config.groups {
            write(BentoPopoverView(groupID: group.id).fixedSize(), model: model, proposed: nil, name: "popover-\(group.id)", in: directory)
        }
        write(DropZoneTrayView(state: DropZoneState()), model: model, proposed: nil, name: "drop-zone", in: directory)

        if let first = model.config.groups.first {
            model.expandedGroupID = first.id
            write(DockRootView(geometry: geometry), model: model, proposed: CGSize(width: width, height: 150), name: "dock-accordion", in: directory)
        }
        print("Snapshots written to \(directory.path)")
        exit(0)
    }

    private static func injectSampleMinimizedWindows(into model: AppModel) {
        guard let first = model.config.groups.first, let app = first.apps.first,
              let bundleID = model.workspace.bundleID(for: app) else { return }
        let titles = ["Kosmodock – DockController.swift", "Terminal — podman ps", "Pull Request #42"]
        let entries = titles.enumerated().map { index, title in
            MinimizedWindow(
                ref: AXElementRef(AXUIElementCreateApplication(pid_t(90_000 + index))),
                pid: pid_t(90_000 + index), bundleID: bundleID, groupID: first.id, title: title,
                frame: CGRect(x: 100, y: 100, width: 1000, height: 700),
                minimizedAt: Date().addingTimeInterval(TimeInterval(-60 * (index + 1)))
            )
        }
        model.minimizedWindows.injectPreviewEntries(entries)
    }

    /// A count, a dot and a long text on the first apps of the first groups.
    private static func injectSampleNotificationBadges(into model: AppModel) {
        let apps = model.config.groups.prefix(3).flatMap { $0.apps.prefix(3) }
        let samples = ["3", "•", "12345678", "27", "New"]
        var badges: [String: String] = [:]
        for (app, label) in zip(apps, samples) {
            if let bundleID = model.workspace.bundleID(for: app) { badges[bundleID] = label }
        }
        model.dockBadges.injectPreviewBadges(badges)
    }

    private static func write<V: View>(_ view: V, model: AppModel, proposed: CGSize?, name: String, in directory: URL) {
        let content = view
            .environment(model)
            .environment(\.locale, language == .system ? model.locale : language.locale)
            .padding(24)
            .background(
                LinearGradient(
                    colors: [Color(red: 0.13, green: 0.17, blue: 0.32), Color(red: 0.42, green: 0.22, blue: 0.40)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        if let proposed {
            renderer.proposedSize = ProposedViewSize(width: proposed.width + 48, height: proposed.height + 48)
        }
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            print("Failed to render \(name)")
            return
        }
        try? png.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
#endif
