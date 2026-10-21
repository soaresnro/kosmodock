import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var dockController: DockController?
    private var settingsController: SettingsWindowController?
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before anything reads ~/.config/kosmodock.
        LegacyMigration.run()
        // Installed first so the native Dock is restored even if setup fails.
        SystemDockManager.installTerminationFailsafes()

        if let other = otherRunningInstance() {
            NSLog("Kosmodock is already running (pid \(other.processIdentifier)); exiting.")
            NSApp.terminate(nil)
            return
        }

        MainMenuBuilder.install()

        let configService = ConfigService()
        configService.bootstrap()
        configService.backUp()

        let model = AppModel(configService: configService)
        self.model = model

        #if DEBUG
        if let directory = SnapshotRenderer.requestedDirectory {
            Task { await SnapshotRenderer.run(model: model, to: directory) }
            return
        }
        #endif

        let dock = DockController(model: model)
        let settings = SettingsWindowController(model: model)
        model.openSettingsHandler = { [weak settings] section in settings?.show(section: section) }
        let statusItem = StatusItemController(model: model)
        DockUndoCommand.installInMainMenu(model: model)

        dockController = dock
        settingsController = settings
        statusItemController = statusItem

        model.start()
        dock.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.stop()
        SystemDockManager.restoreNativeDockIfNeeded()
    }

    /// Re-opening the bundle (Finder / `open Kosmodock.app`) shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model?.openSettings(nil)
        return false
    }

    private func otherRunningInstance() -> NSRunningApplication? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let me = NSRunningApplication.current.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { $0.processIdentifier != me && !$0.isTerminated }
    }
}
