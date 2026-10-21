import AppKit
import ApplicationServices
import Observation
import OSLog

/// One item of the native Dock's list, as read through Accessibility.
struct DockItemRecord: Equatable, Sendable {
    /// `AXApplicationDockItem` for apps; separators, folders, the Trash and
    /// Handoff items have their own subroles.
    var subrole: String?
    /// The app's file URL (`AXURL`).
    var url: URL?
    /// The badge text (`AXStatusLabel`), exactly as the app set it. The Dock
    /// reports no value at all for an app without a badge.
    var statusLabel: String?
}

/// Pure mapping from the native Dock's items to badges, testable without AX.
enum DockBadgeMapping {
    static let applicationSubrole = "AXApplicationDockItem"

    /// Bundle identifier → badge text, for app items that carry a badge.
    /// Other subroles are skipped: a Handoff item's `AXStatusLabel` holds a
    /// device identifier, not a badge.
    static func badges(from records: [DockItemRecord], bundleID: (URL) -> String?) -> [String: String] {
        var badges: [String: String] = [:]
        for record in records where record.subrole == applicationSubrole {
            guard let label = record.statusLabel, let url = record.url, let id = bundleID(url) else { continue }
            // An app is listed once; should it appear twice, keep a real text.
            if let existing = badges[id], !BadgeDisplay(label: existing).isDot { continue }
            badges[id] = label
        }
        return badges
    }
}

/// How a badge text is drawn on an icon.
enum BadgeDisplay: Equatable {
    /// "•", " " or an empty text: a plain red dot.
    case dot
    /// A red capsule with this (possibly shortened) text.
    case text(String)

    /// Longer texts are cut so a badge never covers more than its corner.
    static let maxLength = 5

    init(label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || Self.dotLabels.contains(trimmed) {
            self = .dot
        } else if trimmed.count > Self.maxLength {
            self = .text(String(trimmed.prefix(Self.maxLength - 1)) + "…")
        } else {
            self = .text(trimmed)
        }
    }

    var isDot: Bool { self == .dot }

    private static let dotLabels: Set<String> = ["•", "●", "·", "⦁", "∙"]
}

/// What the service publishes after each poll: new badges only when they
/// changed, and the old ones kept through a few failed polls (the Dock
/// restarts whenever native-Dock suppression is toggled).
struct DockBadgeState: Equatable {
    static let failuresBeforeClearing = 3

    private(set) var badges: [String: String] = [:]
    private(set) var consecutiveFailures = 0

    /// Applies one poll: its badges, or `nil` when the Dock couldn't be read.
    /// Returns the badges to publish, or `nil` when nothing changed.
    mutating func apply(_ polled: [String: String]?) -> [String: String]? {
        let next: [String: String]
        if let polled {
            consecutiveFailures = 0
            next = polled
        } else {
            consecutiveFailures += 1
            guard consecutiveFailures >= Self.failuresBeforeClearing else { return nil }
            next = [:]
        }
        guard next != badges else { return nil }
        badges = next
        return next
    }
}

/// Synchronous reads of the native Dock's AX tree. Call only off the main
/// thread (`WindowManagerService.performAX`). Never performs actions or sets
/// attributes: those would open menus or launch apps on the user's screen.
enum NativeDockAX {
    private static let itemAttributes = [kAXSubroleAttribute, "AXStatusLabel", "AXURL"] as CFArray

    /// Every item of the Dock's list (Dock app → `AXList` → `AXDockItem`s),
    /// or `nil` when the Dock doesn't answer (restarting, untrusted).
    static func items(pid: pid_t) -> [DockItemRecord]? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        guard let children = AXWindowOps.copy(app, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        let lists = children.filter { (AXWindowOps.copy($0, kAXRoleAttribute) as? String) == (kAXListRole as String) }
        guard !lists.isEmpty else { return nil }
        var records: [DockItemRecord] = []
        for list in lists {
            guard let items = AXWindowOps.copy(list, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
            records += items.map(record(of:))
        }
        return records
    }

    /// One IPC round trip per item. Missing attributes come back as AXValue
    /// errors, which the casts below turn into `nil`.
    private static func record(of item: AXUIElement) -> DockItemRecord {
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(item, itemAttributes, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
              let array = values as? [AnyObject], array.count == 3 else { return DockItemRecord() }
        return DockItemRecord(subrole: array[0] as? String, url: array[2] as? URL, statusLabel: array[1] as? String)
    }
}

/// Notification badges ("3", "•") of every app, read from the native Dock.
/// It keeps running while Kosmodock hides it, and every running app has an
/// item there, so its Accessibility tree carries the badges apps set.
@MainActor
@Observable
final class DockBadgeService {
    /// Bundle identifier → badge text, as the app set it.
    private(set) var badges: [String: String] = [:]

    @ObservationIgnored private let windows: WindowManagerService
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var state = DockBadgeState()
    @ObservationIgnored private var dockApp: NSRunningApplication?
    @ObservationIgnored private var isPolling = false
    /// Bumped on stop, so a poll still on the AX queue can't publish after it.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var bundleIDCache: [URL: String?] = [:]

    static let pollInterval: TimeInterval = 2
    nonisolated static let dockBundleID = "com.apple.dock"

    init(windows: WindowManagerService) {
        self.windows = windows
    }

    var isActive: Bool { timer != nil }

    /// Polls while `active` (the setting is on and Accessibility is trusted);
    /// otherwise stops and clears every badge.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        if active {
            Logger.windows.info("Notification badges: polling the native Dock")
            let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
            timer.tolerance = 0.5
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            poll()
        } else {
            timer?.invalidate()
            timer = nil
            generation += 1
            isPolling = false
            state = DockBadgeState()
            dockApp = nil
            if !badges.isEmpty { badges = [:] }
        }
    }

    #if DEBUG
    /// Snapshot rendering only: show sample badges without Accessibility.
    func injectPreviewBadges(_ samples: [String: String]) {
        badges = samples
    }
    #endif

    private func poll() {
        guard isActive, !isPolling, windows.isTrusted else { return }
        guard let pid = dockPID() else {
            publish(nil)
            return
        }
        isPolling = true
        let generation = generation
        Task {
            let records = await windows.performAX { NativeDockAX.items(pid: pid) }
            guard generation == self.generation else { return }
            isPolling = false
            if records == nil {
                // Restarted or not answering: look the Dock up again next time.
                dockApp = nil
            }
            publish(records.map { DockBadgeMapping.badges(from: $0, bundleID: bundleID(for:)) })
        }
    }

    private func publish(_ polled: [String: String]?) {
        if let changed = state.apply(polled) { badges = changed }
    }

    /// The Dock's pid, re-resolved once its process is gone (`killall Dock`).
    private func dockPID() -> pid_t? {
        if let dockApp, !dockApp.isTerminated { return dockApp.processIdentifier }
        dockApp = NSRunningApplication.runningApplications(withBundleIdentifier: Self.dockBundleID).first { !$0.isTerminated }
        return dockApp?.processIdentifier
    }

    /// Only badged items are resolved, and each app bundle is read once.
    private func bundleID(for url: URL) -> String? {
        if let cached = bundleIDCache[url] { return cached }
        if bundleIDCache.count > 256 { bundleIDCache.removeAll() }
        let id = Bundle(url: url)?.bundleIdentifier
        bundleIDCache[url] = .some(id)
        return id
    }
}
