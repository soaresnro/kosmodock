import Foundation

/// A copy of config.json in the backups folder.
struct ConfigBackup: Identifiable, Equatable, Sendable {
    let url: URL
    let date: Date
    /// Tells apart copies made within the same second (`config-…-2.json`).
    let sequence: Int

    var id: URL { url }
}

/// Timestamped copies of config.json: `config-yyyyMMdd-HHmmss.json` in
/// `directory`, in local time. A copy equal to the newest one is skipped,
/// and only the newest `limit` are kept.
struct ConfigBackupStore: Sendable {
    static let defaultLimit = 20

    let directory: URL
    var limit = ConfigBackupStore.defaultLimit

    /// Newest first. Files that aren't backups are ignored, and never deleted.
    func list() -> [ConfigBackup] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name in
            Self.parse(name).map { ConfigBackup(url: directory.appendingPathComponent(name), date: $0.date, sequence: $0.sequence) }
        }
        .sorted { ($0.date, $0.sequence) > ($1.date, $1.sequence) }
    }

    /// Saves `data` as the newest backup, then prunes the oldest. Returns nil
    /// when `data` equals the newest backup, which is then left as it is.
    @discardableResult
    func save(_ data: Data, at date: Date = Date()) throws -> ConfigBackup? {
        if let newest = list().first, (try? Data(contentsOf: newest.url)) == data { return nil }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = Self.stamp(date)
        var sequence = 1
        var url = directory.appendingPathComponent(Self.fileName(stamp: stamp, sequence: sequence))
        while fileManager.fileExists(atPath: url.path) {
            sequence += 1
            url = directory.appendingPathComponent(Self.fileName(stamp: stamp, sequence: sequence))
        }
        try data.write(to: url, options: .atomic)
        for old in list().dropFirst(max(1, limit)) {
            try? fileManager.removeItem(at: old.url)
        }
        return ConfigBackup(url: url, date: Self.parse(url.lastPathComponent)?.date ?? date, sequence: sequence)
    }

    // MARK: File names

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    static func fileName(stamp: String, sequence: Int) -> String {
        sequence > 1 ? "config-\(stamp)-\(sequence).json" : "config-\(stamp).json"
    }

    /// `yyyyMMdd-HHmmss`, without a `DateFormatter` so the store stays `Sendable`.
    static func stamp(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d%02d%02d-%02d%02d%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )
    }

    static func parse(_ name: String) -> (date: Date, sequence: Int)? {
        guard name.hasPrefix("config-"), name.hasSuffix(".json") else { return nil }
        let fields = name.dropFirst("config-".count).dropLast(".json".count).split(separator: "-", omittingEmptySubsequences: false)
        guard fields.count == 2 || fields.count == 3,
              fields.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              fields[0].count == 8, fields[1].count == 6,
              let day = Int(fields[0]), let time = Int(fields[1]),
              let sequence = fields.count == 3 ? Int(fields[2]) : 1, sequence >= 1
        else { return nil }
        var components = DateComponents()
        components.year = day / 10_000
        components.month = day / 100 % 100
        components.day = day % 100
        components.hour = time / 10_000
        components.minute = time / 100 % 100
        components.second = time % 100
        return calendar.date(from: components).map { ($0, sequence) }
    }
}
