import Foundation

/// One-time move of files written under the project's former name, OrbitDock.
enum LegacyMigration {
    static func run(fileManager: FileManager = .default, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let legacy = home.appendingPathComponent(".config/orbitdock")
        let current = home.appendingPathComponent(".config/kosmodock")
        guard fileManager.fileExists(atPath: legacy.path) else { return }
        try? fileManager.createDirectory(at: current, withIntermediateDirectories: true)

        // Groups and theme carry over; the original stays behind as a backup.
        copyIfMissing("config.json", from: legacy, to: current, fileManager: fileManager)
        // The native-Dock restore command must exist in exactly one place, or
        // it could run twice.
        moveIfMissing(".restore-native-dock.sh", from: legacy, to: current, fileManager: fileManager)
    }

    private static func copyIfMissing(_ name: String, from source: URL, to target: URL, fileManager: FileManager) {
        let from = source.appendingPathComponent(name)
        let to = target.appendingPathComponent(name)
        guard fileManager.fileExists(atPath: from.path), !fileManager.fileExists(atPath: to.path) else { return }
        try? fileManager.copyItem(at: from, to: to)
    }

    private static func moveIfMissing(_ name: String, from source: URL, to target: URL, fileManager: FileManager) {
        let from = source.appendingPathComponent(name)
        let to = target.appendingPathComponent(name)
        guard fileManager.fileExists(atPath: from.path), !fileManager.fileExists(atPath: to.path) else { return }
        try? fileManager.moveItem(at: from, to: to)
    }
}
