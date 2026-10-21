import AppKit

// Actions of the file and sharing widgets: what a click does, files dropped
// on a tile, the shelf and app collections.

extension AppModel {
    /// A click on a tile: a shortcut runs and AirDrop opens; the other tiles
    /// show their details.
    func activate(_ tile: DockTile) {
        switch tile.kind {
        case .shortcut where !(tile.shortcutName?.isBlank ?? true):
            fileWidgets.shortcuts.run(tile)
        case .airDrop:
            dismissPopover?()
            FileActions.openAirDrop()
        default:
            tap(tile)
        }
    }

    /// Files dropped on a tile that takes them. Returns whether it did.
    @discardableResult
    func dropFiles(_ urls: [URL], on tile: DockTile) -> Bool {
        let urls = urls.filter(\.isFileURL)
        guard !urls.isEmpty else { return false }
        switch tile.kind {
        case .shelf:
            addToShelf(urls, tileID: tile.id)
        case .airDrop:
            return FileActions.sendViaAirDrop(urls)
        case .appCollection:
            let apps = urls.filter { $0.pathExtension.lowercased() == "app" }.map(DockApp.init(url:))
            guard !apps.isEmpty else { return false }
            addApps(apps, toCollection: tile.id)
        default:
            return false
        }
        return true
    }

    /// `tileID` nil is the Drop Zone's shelf, added to the bar when missing.
    func addToShelf(_ urls: [URL], tileID: String? = nil) {
        let paths = urls.filter(\.isFileURL).map(\.path)
        guard !paths.isEmpty else { return }
        configService.update { $0.addToShelf(paths, tileID: tileID) }
    }

    func removeFromShelf(_ urls: [URL], tileID: String) {
        updateTile(tileID) { tile in
            let rest = Shelf.removing(urls.map(\.path), from: tile.shelfItems ?? [])
            tile.shelfItems = rest.isEmpty ? nil : rest
        }
    }

    func clearShelf(tileID: String) {
        updateTile(tileID) { $0.shelfItems = nil }
    }

    /// A file dragged out of a shelf leaves it when the shelf says so.
    func shelfDragEnded(_ urls: [URL], tileID: String, accepted: Bool) {
        guard accepted, tile(id: tileID)?.removesOnDragOut == true else { return }
        removeFromShelf(urls, tileID: tileID)
    }

    func addApps(_ apps: [DockApp], toCollection tileID: String) {
        updateTile(tileID) { tile in
            var current = tile.collectionApps ?? []
            for app in apps where !current.contains(where: { $0.id == app.id }) {
                current.append(app)
            }
            tile.collectionApps = current
        }
    }

    /// The pinned app's "Create Collection": the app moves into a new
    /// collection in its place, and Settings opens to add more apps.
    func createCollection(from app: DockApp) {
        editBar { $0.makeCollection(from: app) }
        openSettings(.tiles)
    }

    private func updateTile(_ id: String, _ change: (inout DockTile) -> Void) {
        configService.update { config in
            guard let index = config.tiles.firstIndex(where: { $0.id == id }) else { return }
            change(&config.tiles[index])
        }
    }
}
