import AppKit
import Observation

/// Hides the native macOS Dock while Kosmodock runs and guarantees it comes
/// back, no matter how Kosmodock exits.
///
/// "Suppressed" is represented on disk by a sentinel file that contains the
/// exact shell command restoring the user's original Dock settings. Every exit
/// path — normal quit, `willTerminate`, SIGINT/SIGTERM/SIGHUP, `atexit`, and a
/// detached watchdog for crashes and SIGKILL — runs that command if the file
/// still exists and then deletes it, so restoration is idempotent.
@MainActor
@Observable
final class SystemDockManager {
    private(set) var isSuppressed: Bool
    private(set) var isBusy = false
    private(set) var lastError: String?

    @ObservationIgnored private var watchdog: Process?
    @ObservationIgnored private var pending: Bool?

    nonisolated static let sentinelURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/kosmodock/.restore-native-dock.sh")

    /// Hides the Dock, and sends minimized windows into their app icon with the
    /// short "scale" effect so Kosmodock's group animation dominates.
    nonisolated static let suppressCommand = [
        "defaults write com.apple.dock autohide -bool true",
        "defaults write com.apple.dock autohide-delay -float 1000",
        "defaults write com.apple.dock minimize-to-application -bool true",
        "defaults write com.apple.dock mineffect -string scale",
        "killall Dock",
    ].joined(separator: " && ")

    /// `$1` = pid to watch, `$2` = sentinel path. Ignores SIGINT/SIGHUP so a
    /// Ctrl-C in the launching terminal can't kill it alongside Kosmodock.
    nonisolated static let watchdogScript = """
    trap '' INT HUP
    while kill -0 "$1" 2>/dev/null; do sleep 2; done
    if [ -f "$2" ]; then cmd=$(cat "$2"); rm -f "$2"; /bin/sh -c "$cmd"; fi
    """

    private static var signalSources: [DispatchSourceSignal] = []
    private static var terminationToken: NSObjectProtocol?

    init() {
        isSuppressed = FileManager.default.fileExists(atPath: Self.sentinelURL.path)
    }

    /// Brings the native Dock in line with the desired state. Also recovers
    /// from a previous session that died while the Dock was suppressed.
    func reconcile(wantsSuppressed: Bool) {
        guard !isBusy else {
            pending = wantsSuppressed
            return
        }
        Task {
            if wantsSuppressed {
                await suppress()
            } else if FileManager.default.fileExists(atPath: Self.sentinelURL.path) {
                await restore()
            }
            if let next = pending {
                pending = nil
                reconcile(wantsSuppressed: next)
            }
        }
    }

    private func suppress() async {
        isBusy = true
        defer { isBusy = false }
        do {
            try FileManager.default.createDirectory(at: Self.sentinelURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Only capture the original settings once; an existing sentinel
            // already holds them (the current values are the suppressed ones).
            if !FileManager.default.fileExists(atPath: Self.sentinelURL.path) {
                try Self.restoreCommand(for: Self.currentNativeDockState())
                    .write(to: Self.sentinelURL, atomically: true, encoding: .utf8)
            }
        } catch {
            lastError = L10n.tr("Could not record Dock settings: %@", error.localizedDescription)
            return
        }
        if !Self.nativeDockAlreadySuppressed() {
            let result = await ShellRunner.shell(Self.suppressCommand, timeout: 15)
            guard result.succeeded else {
                lastError = L10n.tr("Could not hide the Dock: %@", result.errorSummary)
                return
            }
        }
        lastError = nil
        isSuppressed = true
        spawnWatchdog()
    }

    private func restore() async {
        isBusy = true
        defer { isBusy = false }
        guard let command = try? String(contentsOf: Self.sentinelURL, encoding: .utf8) else {
            isSuppressed = false
            return
        }
        try? FileManager.default.removeItem(at: Self.sentinelURL)
        let result = await ShellRunner.shell(command, timeout: 15)
        lastError = result.exitCode == 0 ? nil : L10n.tr("Dock restore reported: %@", result.errorSummary)
        isSuppressed = false
    }

    // MARK: Failsafes

    /// Synchronous, idempotent restore used on every termination path.
    nonisolated static func restoreNativeDockIfNeeded() {
        guard let command = try? String(contentsOf: sentinelURL, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: sentinelURL)
        ShellRunner.runBlocking(command)
    }

    static func installTerminationFailsafes() {
        atexit {
            SystemDockManager.restoreNativeDockIfNeeded()
        }
        for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                SystemDockManager.restoreNativeDockIfNeeded()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
        terminationToken = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            SystemDockManager.restoreNativeDockIfNeeded()
        }
    }

    /// A detached shell that outlives Kosmodock: once our pid disappears (crash,
    /// SIGKILL, force quit) it runs the restore command if the sentinel remains.
    private func spawnWatchdog() {
        guard watchdog == nil else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", Self.watchdogScript, "kosmodock-dock-watchdog", String(getpid()), Self.sentinelURL.path]
        process.environment = ShellRunner.environment()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            watchdog = process
        } catch {
            NSLog("Kosmodock: could not start Dock watchdog: \(error.localizedDescription)")
        }
    }

    // MARK: Native Dock preferences

    struct NativeDockState: Equatable {
        var autohide: Bool
        var autohideDelay: Double?
        var minimizeToApplication: Bool?
        var minimizeEffect: String?
    }

    private static func preference(_ key: String) -> CFPropertyList? {
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        return CFPreferencesCopyAppValue(key as CFString, "com.apple.dock" as CFString)
    }

    private static func currentNativeDockState() -> NativeDockState {
        let autohide = preference("autohide") as? Bool ?? false
        let delay = preference("autohide-delay") as? Double
        let minimizeToApplication = preference("minimize-to-application") as? Bool
        let effect = preference("mineffect") as? String
        // A huge delay is a leftover from an earlier suppression whose sentinel
        // was lost; treat it as "never customised".
        if let delay, delay >= 100 {
            return NativeDockState(autohide: false, autohideDelay: nil, minimizeToApplication: nil, minimizeEffect: nil)
        }
        return NativeDockState(autohide: autohide, autohideDelay: delay, minimizeToApplication: minimizeToApplication, minimizeEffect: effect)
    }

    private static func nativeDockAlreadySuppressed() -> Bool {
        let autohide = preference("autohide") as? Bool ?? false
        let delay = preference("autohide-delay") as? Double ?? 0
        let minimizeToApplication = preference("minimize-to-application") as? Bool ?? false
        let effect = preference("mineffect") as? String
        return autohide && delay >= 100 && minimizeToApplication && effect == "scale"
    }

    /// Shell command that puts back exactly the settings captured in `state`.
    nonisolated static func restoreCommand(for state: NativeDockState) -> String {
        let delay = state.autohideDelay.map { "defaults write com.apple.dock autohide-delay -float \($0)" }
            ?? "defaults delete com.apple.dock autohide-delay 2>/dev/null"
        let minimizeToApplication = state.minimizeToApplication.map {
            "defaults write com.apple.dock minimize-to-application -bool \($0 ? "true" : "false")"
        } ?? "defaults delete com.apple.dock minimize-to-application 2>/dev/null"
        // The value ends up in a shell command: keep letters only.
        let effect = state.minimizeEffect.map { String($0.filter(\.isLetter)) }.flatMap { $0.isEmpty ? nil : $0 }
        let minimizeEffect = effect.map { "defaults write com.apple.dock mineffect -string \($0)" }
            ?? "defaults delete com.apple.dock mineffect 2>/dev/null"
        return [
            delay,
            "defaults write com.apple.dock autohide -bool \(state.autohide ? "true" : "false")",
            minimizeToApplication,
            minimizeEffect,
            "killall Dock",
        ].joined(separator: "; ") + "\n"
    }
}
