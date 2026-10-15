import AppKit
import ApplicationServices
import OSLog

/// Window lifecycle events gathered from Accessibility observers and
/// NSWorkspace, fanned out to the enforcer, Intellihide and minimize tracker.
enum WindowEvent {
    /// A window of `pid` was created, moved, resized or changed focus.
    case windowsChanged(pid_t)
    case miniaturized(pid_t, AXElementRef)
    case deminiaturized(pid_t, AXElementRef)
    case destroyed(pid_t, AXElementRef)
    case appActivated(pid_t)
    case appLaunched(pid_t)
    case appTerminated(pid_t)
    case spaceChanged
}

/// Hashable, sendable handle for an `AXUIElement` (compared with `CFEqual`),
/// so elements can be stored in sets and handed to the AX queue.
final class AXElementRef: Hashable, @unchecked Sendable {
    let element: AXUIElement

    init(_ element: AXUIElement) {
        self.element = element
    }

    static func == (lhs: AXElementRef, rhs: AXElementRef) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}

/// One `AXObserver` per regular app, registered on the application element so
/// a single registration covers every window the app owns.
@MainActor
final class AXObserverHub {
    typealias Listener = (WindowEvent) -> Void

    private static let applicationNotifications = [
        kAXWindowCreatedNotification,
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
        kAXFocusedWindowChangedNotification,
        kAXMainWindowChangedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
    ]

    private var listeners: [Listener] = []
    private var observers: [pid_t: AXObserver] = [:]
    private var retries: [pid_t: Int] = [:]
    private var tokens: [NSObjectProtocol] = []
    private(set) var isRunning = false

    func addListener(_ listener: @escaping Listener) {
        listeners.append(listener)
    }

    /// Starts observing every regular app. Requires Accessibility trust;
    /// call again once trust is granted.
    func start() {
        guard !isRunning, AXIsProcessTrusted() else { return }
        isRunning = true
        installWorkspaceObservers()
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            observe(app.processIdentifier)
        }
        Logger.windows.notice("AX observer hub started: \(self.observers.count, privacy: .public) app(s) observed")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        for pid in Array(observers.keys) { unobserve(pid) }
        let center = NSWorkspace.shared.notificationCenter
        tokens.forEach(center.removeObserver)
        tokens.removeAll()
    }

    var observedPIDs: [pid_t] { Array(observers.keys) }

    /// Window destruction is only delivered per element, so minimized windows
    /// register individually.
    func watchDestruction(of ref: AXElementRef, pid: pid_t) {
        guard let observer = observers[pid] else { return }
        AXObserverAddNotification(observer, ref.element, kAXUIElementDestroyedNotification as CFString, refcon)
    }

    // MARK: Observers

    private var refcon: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    private func observe(_ pid: pid_t) {
        guard observers[pid] == nil, pid != getpid() else { return }
        var created: AXObserver?
        let creation = AXObserverCreate(pid, axObserverCallback, &created)
        guard creation == .success, let observer = created else {
            Logger.windows.error("AXObserverCreate failed for pid \(pid, privacy: .public): \(creation.rawValue, privacy: .public)")
            return
        }

        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        var registered = 0
        for notification in Self.applicationNotifications
        where AXObserverAddNotification(observer, app, notification as CFString, refcon) == .success {
            registered += 1
        }
        // Freshly launched apps often aren't AX-ready yet; retry a few times.
        guard registered > 0 else {
            scheduleRetry(pid)
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
        retries[pid] = nil
    }

    private func unobserve(_ pid: pid_t) {
        retries[pid] = nil
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    private func scheduleRetry(_ pid: pid_t) {
        let attempt = (retries[pid] ?? 0) + 1
        guard attempt <= 5 else {
            retries[pid] = nil
            return
        }
        retries[pid] = attempt
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, self.isRunning, NSRunningApplication(processIdentifier: pid) != nil else { return }
            self.observe(pid)
        }
    }

    // MARK: Events

    fileprivate func receive(element: AXUIElement, notification: String) {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        switch notification {
        case kAXWindowMiniaturizedNotification:
            emit(.miniaturized(pid, AXElementRef(element)))
        case kAXWindowDeminiaturizedNotification:
            emit(.deminiaturized(pid, AXElementRef(element)))
        case kAXUIElementDestroyedNotification:
            emit(.destroyed(pid, AXElementRef(element)))
        default:
            emit(.windowsChanged(pid))
        }
    }

    private func emit(_ event: WindowEvent) {
        for listener in listeners { listener(event) }
    }

    private func installWorkspaceObservers() {
        guard tokens.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter

        func observeApp(_ name: Notification.Name, _ handler: @escaping (AXObserverHub, pid_t, Bool) -> Void) {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard let pid = app?.processIdentifier else { return }
                let isRegular = app?.activationPolicy == .regular
                MainActor.assumeIsolated {
                    guard let self else { return }
                    handler(self, pid, isRegular)
                }
            })
        }

        observeApp(NSWorkspace.didLaunchApplicationNotification) { hub, pid, isRegular in
            guard isRegular else { return }
            hub.observe(pid)
            hub.emit(.appLaunched(pid))
        }
        observeApp(NSWorkspace.didTerminateApplicationNotification) { hub, pid, _ in
            hub.unobserve(pid)
            hub.emit(.appTerminated(pid))
        }
        observeApp(NSWorkspace.didActivateApplicationNotification) { hub, pid, isRegular in
            if isRegular { hub.observe(pid) }
            hub.emit(.appActivated(pid))
        }
        observeApp(NSWorkspace.didHideApplicationNotification) { hub, pid, _ in hub.emit(.windowsChanged(pid)) }
        observeApp(NSWorkspace.didUnhideApplicationNotification) { hub, pid, _ in hub.emit(.windowsChanged(pid)) }

        tokens.append(center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.emit(.spaceChanged) }
        })
    }
}

/// C callback; the observer's run loop source lives on the main run loop.
private func axObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let hub = Unmanaged<AXObserverHub>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    MainActor.assumeIsolated {
        hub.receive(element: element, notification: name)
    }
}
