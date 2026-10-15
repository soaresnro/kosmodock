import Foundation

struct ShellResult: Sendable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
    var timedOut: Bool = false

    var succeeded: Bool { exitCode == 0 && !timedOut }

    /// First meaningful line of output, for compact error messages.
    var errorSummary: String {
        for text in [stderr, stdout] {
            if let line = text.split(whereSeparator: \.isNewline)
                .map({ $0.trimmingCharacters(in: .whitespaces) })
                .first(where: { !$0.isEmpty }) {
                return String(line.prefix(160))
            }
        }
        return timedOut ? L10n.tr("timed out") : L10n.tr("exit code %d", Int(exitCode))
    }
}

/// Runs child processes without blocking the main thread.
///
/// Output is captured through temporary files rather than pipes: commands such
/// as `podman machine start` spawn long-lived daemons that inherit stdout, and a
/// pipe would never reach EOF while they live.
enum ShellRunner {
    /// GUI app bundles launch with a minimal PATH; inject the Homebrew prefixes
    /// so `podman`, `docker` and user scripts resolve like they do in a shell.
    static let injectedPATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        var entries = injectedPATH.split(separator: ":").map(String.init) + ["/usr/sbin", "/sbin", "/opt/podman/bin"]
        for entry in (env["PATH"] ?? "").split(separator: ":").map(String.init) where !entries.contains(entry) {
            entries.append(entry)
        }
        env["PATH"] = entries.joined(separator: ":")
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        return env
    }

    static func run(_ executable: String, _ arguments: [String] = [], timeout: TimeInterval = 20) async -> ShellResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<ShellResult, Never>) in
            launch(executable, arguments, timeout: timeout) { continuation.resume(returning: $0) }
        }
    }

    /// Runs a snippet through `/bin/sh -c`.
    static func shell(_ command: String, timeout: TimeInterval = 20) async -> ShellResult {
        await run("/bin/sh", ["-c", command], timeout: timeout)
    }

    /// Synchronous variant for termination paths where async work can't finish.
    @discardableResult
    static func runBlocking(_ command: String) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = environment()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }

    private static func launch(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval,
        completion: @escaping @Sendable (ShellResult) -> Void
    ) {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appendingPathComponent("kosmodock-\(UUID().uuidString)")
        let outURL = base.appendingPathExtension("out")
        let errURL = base.appendingPathExtension("err")

        guard fileManager.createFile(atPath: outURL.path, contents: nil),
              fileManager.createFile(atPath: errURL.path, contents: nil),
              let outHandle = try? FileHandle(forWritingTo: outURL),
              let errHandle = try? FileHandle(forWritingTo: errURL)
        else {
            completion(ShellResult(exitCode: -1, stdout: "", stderr: "Unable to create temporary output files"))
            return
        }

        let timedOut = Flag()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outHandle
        process.standardError = errHandle

        @Sendable func collect(exitCode: Int32) -> ShellResult {
            try? outHandle.close()
            try? errHandle.close()
            let stdout = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
            let stderr = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
            return ShellResult(exitCode: exitCode, stdout: stdout, stderr: stderr, timedOut: timedOut.isSet)
        }

        process.terminationHandler = { finished in
            completion(collect(exitCode: finished.terminationStatus))
        }

        do {
            try process.run()
        } catch {
            var result = collect(exitCode: -1)
            result.stderr = error.localizedDescription
            completion(result)
            return
        }

        // The closure holds `process` strongly so it stays alive until it exits.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            guard process.isRunning else { return }
            timedOut.set()
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }
}

/// Minimal thread-safe boolean.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
