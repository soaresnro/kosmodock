import AppKit
import OSLog
import SwiftUI

// Folder stacks, the Trash, spacers and undoing the last bar edit.

extension BarItem {
    /// A flexible spacer takes the row's free width (`CapsuleRow`).
    var isFlexibleSpacer: Bool {
        if case .extra(.spacer(let spacer)) = self { return spacer.size == .flexible }
        return false
    }
}

extension AppModel {
    func folder(id: String) -> DockFolder? {
        config.folders.first { $0.id == id }
    }

    func folder(itemID: String) -> DockFolder? {
        config.folders.first { DockConfig.itemID(for: $0) == itemID }
    }

    /// Items after the ordered ones: the Trash, when it's shown.
    var trailingBarItems: [BarItem] {
        config.showsTrash ? [.extra(.trash)] : []
    }

    /// Folders and spacers by item id, for `barItems(for:)`.
    func extraBarItems(in config: DockConfig) -> [String: BarItem] {
        var items: [String: BarItem] = [:]
        for folder in config.folders { items[DockConfig.itemID(for: folder)] = .extra(.folder(folder)) }
        for spacer in config.spacers { items[DockConfig.itemID(for: spacer)] = .extra(.spacer(spacer)) }
        return items
    }

    // MARK: Lifecycle

    func startDockItems() {
        folderStacks.isShowing = { [weak self] folderID in
            self?.popoverItemID == "folder:\(folderID)"
        }
        folderStacks.update(folders: config.folders)
        trash.setEnabled(config.showsTrash)
        configService.addObserver { [weak self] old, new in
            guard let self else { return }
            if old.folders != new.folders { self.folderStacks.update(folders: new.folders) }
            if old.showsTrash != new.showsTrash { self.trash.setEnabled(new.showsTrash) }
        }
    }

    func stopDockItems() {
        folderStacks.stopAll()
        trash.setEnabled(false)
    }

    // MARK: Folders

    func tap(_ folder: DockFolder) {
        presentPopover?(DockConfig.itemID(for: folder))
    }

    /// Puts folders chosen in an Open panel on the bar, at the end.
    func addFolders(_ urls: [URL]) {
        editBar { $0.addFolders(urls.map(DockFolder.init(chosen:))) }
    }

    func addDownloads() {
        editBar { $0.addFolders([.downloads()]) }
    }

    func removeFolder(id: String) {
        editBar { config in
            config.removeFromBar("folder:\(id)")
            config.folders.removeAll { $0.id == id }
        }
    }

    /// How the popover lists the folder; not a bar edit.
    func updateFolder(id: String, _ change: (inout DockFolder) -> Void) {
        configService.update { config in
            guard let index = config.folders.firstIndex(where: { $0.id == id }) else { return }
            change(&config.folders[index])
        }
    }

    func openInFinder(_ folder: DockFolder) {
        dismissPopover?()
        NSWorkspace.shared.open(folder.url)
    }

    func open(_ entry: FolderEntry) {
        dismissPopover?()
        NSWorkspace.shared.open(entry.url)
    }

    func revealInFinder(_ entry: FolderEntry) {
        dismissPopover?()
        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
    }

    /// Moves files to the Trash, as dropping them on it does.
    func moveToTrash(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.recycle(urls) { [weak self] _, error in
            if let error {
                Logger.dockItems.error("Move to Trash failed: \(error.localizedDescription, privacy: .public)")
            }
            Task { @MainActor in self?.trash.refresh() }
        }
    }

    // MARK: Spacers and Trash

    func addSpacer(_ size: SpacerSize) {
        editBar { config in
            config.addToBar { $0.spacers = DockConfig.normalizedSpacerIDs($0.spacers + [DockSpacer(id: "", size: size)]) }
        }
    }

    func removeSpacer(id: String) {
        editBar { config in
            config.removeFromBar("spacer:\(id)")
            config.spacers.removeAll { $0.id == id }
        }
    }

    func setSpacerSize(id: String, size: SpacerSize) {
        editBar { config in
            guard let index = config.spacers.firstIndex(where: { $0.id == id }) else { return }
            config.spacers[index].size = size
        }
    }

    func setShowsTrash(_ shows: Bool) {
        editBar { $0.showsTrash = shows }
    }

    // MARK: Undo

    /// A bar edit: adding, removing or moving items, pinning, what a workspace
    /// shows. The bar as it was is kept for "Undo Last Dock Change".
    func editBar(_ mutate: (inout DockConfig) -> Void) {
        let before = config
        configService.update(mutate)
        dockUndo.record(before: before, after: config)
    }

    var canUndoDockChange: Bool { dockUndo.canUndo(config) }

    func undoLastDockChange() {
        guard let restored = dockUndo.undone(config) else { return }
        dockUndo = DockBarUndo()
        withAnimation(spring) {
            configService.update { $0 = restored }
        }
    }
}
