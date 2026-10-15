import AppKit
import Observation

struct AppRuntimeState: Equatable, Sendable {
    var pids: [pid_t] = []
    var isHidden = false
    var isActive = false
}

/// Tracks running applications and performs lifecycle actions (launch, focus,
/// hide, quit) for dock entries.
@MainActor
@Observable
final class WorkspaceService {
    /// Running state keyed by bundle identifier.
    private(set) var states: [String: AppRuntimeState] = [:]

    @ObservationIgnored private var iconCache: [String: NSImage] = [:]
    @ObservationIgnored private var displayNameCache: [String: String] = [:]
    @ObservationIgnored private var bundleIDCache: [String: String] = [:]
    @ObservationIgnored private var tokens: [NSObjectProtocol] = []

    init() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didDeactivateApplicationNotification,
        ]
        for name in names {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    func refresh() {
        var next: [String: AppRuntimeState] = [:]
        for app in NSWorkspace.shared.runningApplications where !app.isTerminated {
            guard let id = app.bundleIdentifier else { continue }
            var state = next[id] ?? AppRuntimeState(isHidden: true)
            state.pids.append(app.processIdentifier)
            state.isHidden = state.isHidden && app.isHidden
            state.isActive = state.isActive || app.isActive
            next[id] = state
        }
        if next != states { states = next }
    }

    // MARK: Resolution

    func bundleID(for app: DockApp) -> String? {
        if let id = app.bundleId, !id.isEmpty { return id }
        guard let path = app.expandedPath else { return nil }
        if let cached = bundleIDCache[path] { return cached }
        let id = Bundle(path: path)?.bundleIdentifier
        if let id { bundleIDCache[path] = id }
        return id
    }

    func url(for app: DockApp) -> URL? {
        if let path = app.expandedPath, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        if let id = bundleID(for: app) {
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        }
        return nil
    }

    func state(for app: DockApp) -> AppRuntimeState? {
        bundleID(for: app).flatMap { states[$0] }
    }

    func isRunning(_ app: DockApp) -> Bool {
        state(for: app) != nil
    }

    func primaryPID(for app: DockApp) -> pid_t? {
        state(for: app)?.pids.first
    }

    func runningApplications(for app: DockApp) -> [NSRunningApplication] {
        guard let id = bundleID(for: app) else { return [] }
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
    }

    /// The name Finder shows, localized by macOS ("Ajustes do Sistema").
    func displayName(for app: DockApp) -> String {
        if let cached = displayNameCache[app.id] { return cached }
        var name = app.name
        if let url = url(for: app) {
            let display = FileManager.default.displayName(atPath: url.path)
            name = display.hasSuffix(".app") ? String(display.dropLast(4)) : display
        }
        displayNameCache[app.id] = name
        return name
    }

    func icon(for app: DockApp) -> NSImage {
        if let cached = iconCache[app.id] { return cached }
        let image: NSImage
        if let url = url(for: app) {
            image = NSWorkspace.shared.icon(forFile: url.path)
            image.size = NSSize(width: 256, height: 256)
        } else {
            image = NSImage(systemSymbolName: "questionmark.app.dashed", accessibilityDescription: app.name) ?? NSImage()
        }
        iconCache[app.id] = image
        return image
    }

    // MARK: Actions

    /// Launches (or, when already running, re-opens and activates) an app.
    @discardableResult
    func launch(_ app: DockApp, activate: Bool = true) async -> NSRunningApplication? {
        guard let url = url(for: app) else {
            NSLog("Kosmodock: cannot locate \(app.name)")
            return nil
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activate
        do {
            return try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        } catch {
            NSLog("Kosmodock: failed to open \(app.name): \(error.localizedDescription)")
            return nil
        }
    }

    /// Unhides and brings an app to the front. LaunchServices activation is
    /// used because direct activation from a background app is throttled by
    /// macOS 14's cooperative activation rules.
    func focus(_ app: DockApp) {
        for running in runningApplications(for: app) where running.isHidden {
            running.unhide()
        }
        Task { await launch(app, activate: true) }
    }

    func unhide(_ apps: [DockApp]) {
        for app in apps {
            for running in runningApplications(for: app) where running.isHidden {
                running.unhide()
            }
        }
    }

    func hide(_ app: DockApp) {
        runningApplications(for: app).forEach { $0.hide() }
    }

    func quit(_ app: DockApp) {
        runningApplications(for: app).forEach { $0.terminate() }
    }

    func forceQuit(_ app: DockApp) {
        runningApplications(for: app).forEach { $0.forceTerminate() }
    }

    /// Hides every regular app whose bundle id isn't in `keep` (Focus Mode).
    func hideApplications(excluding keep: Set<String>) {
        let me = NSRunningApplication.current.processIdentifier
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  app.processIdentifier != me,
                  let id = app.bundleIdentifier,
                  !keep.contains(id),
                  !app.isHidden
            else { continue }
            app.hide()
        }
    }

    func revealInFinder(_ app: DockApp) {
        guard let url = url(for: app) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Regular apps currently running, for the "Add Running App" menu.
    func runningRegularApps() -> [DockApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != NSRunningApplication.current.processIdentifier }
            .compactMap { $0.bundleURL.map(DockApp.init(url:)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
