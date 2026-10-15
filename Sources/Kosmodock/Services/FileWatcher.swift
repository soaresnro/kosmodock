import Foundation

/// Watches a single file with a kqueue-backed dispatch source.
///
/// Editors such as VS Code and Vim save atomically (write temp file, rename over
/// the original), which detaches the watched inode. On delete/rename events the
/// watcher re-opens the path, retrying until the replacement file appears.
@MainActor
final class FileWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var debounceTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    func start() {
        stop()
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            scheduleRetry()
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke, .link],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.handleEvent() }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        self.source = source
        source.resume()
    }

    func stop() {
        retryTask?.cancel()
        retryTask = nil
        source?.cancel()
        source = nil
    }

    private func handleEvent() {
        guard let source else { return }
        let event = source.data
        if !event.isDisjoint(with: [.delete, .rename, .revoke]) {
            stop()
            scheduleRetry(after: .milliseconds(100))
        }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.onChange()
        }
    }

    private func scheduleRetry(after delay: Duration = .seconds(1)) {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            if FileManager.default.fileExists(atPath: self.url.path) {
                self.start()
                self.onChange()
            } else {
                self.scheduleRetry()
            }
        }
    }
}
