import Foundation

/// Health of a probe, container or service. Ordered by severity so `max()`
/// yields the worst level.
enum HealthLevel: Int, Comparable, Sendable {
    case unknown = 0
    case ok
    case warning
    case critical

    static func < (lhs: HealthLevel, rhs: HealthLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct ResourceUsage: Equatable, Sendable {
    /// Percentage of total machine capacity (0–100, normalised by core count).
    var cpuPercent: Double = 0
    /// Physical footprint, matching Activity Monitor's "Memory" column.
    var memoryBytes: UInt64 = 0
    var processCount: Int = 0

    static let zero = ResourceUsage()

    static func + (lhs: ResourceUsage, rhs: ResourceUsage) -> ResourceUsage {
        ResourceUsage(
            cpuPercent: lhs.cpuPercent + rhs.cpuPercent,
            memoryBytes: lhs.memoryBytes + rhs.memoryBytes,
            processCount: lhs.processCount + rhs.processCount
        )
    }
}

enum MemoryPressure: Int, Sendable {
    case normal = 1
    case warning = 2
    case critical = 4

    var title: String {
        switch self {
        case .normal: L10n.tr("Normal")
        case .warning: L10n.tr("Elevated")
        case .critical: L10n.tr("Critical")
        }
    }

    var level: HealthLevel {
        switch self {
        case .normal: .ok
        case .warning: .warning
        case .critical: .critical
        }
    }
}

struct SystemSnapshot: Equatable, Sendable {
    var cpuPercent: Double = 0
    var coreCount: Int = ProcessInfo.processInfo.activeProcessorCount
    var memoryUsed: UInt64 = 0
    var memoryTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    var swapUsed: UInt64 = 0
    var pressure: MemoryPressure = .normal
    var loadAverage: Double = 0

    var memoryFraction: Double {
        memoryTotal == 0 ? 0 : min(1, Double(memoryUsed) / Double(memoryTotal))
    }
}

/// Outcome of a custom command or command probe.
struct ProbeResult: Sendable {
    var level: HealthLevel
    var summary: String
    var detail: String
    var updatedAt: Date

    init(level: HealthLevel, summary: String, detail: String = "", updatedAt: Date = Date()) {
        self.level = level
        self.summary = summary
        self.detail = detail
        self.updatedAt = updatedAt
    }

    /// Maps a shell result onto the 🟢/🟡/🔴 convention: exit 0 = ok, 1 = warning,
    /// anything else (or a timeout) = critical.
    init(shell result: ShellResult) {
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = stdout.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        switch (result.timedOut, result.exitCode) {
        case (true, _): level = .critical
        case (_, 0): level = .ok
        case (_, 1): level = .warning
        default: level = .critical
        }
        if result.timedOut {
            summary = L10n.tr("Timed out")
        } else if !firstLine.isEmpty {
            summary = String(firstLine.prefix(42))
        } else if result.exitCode == 0 {
            summary = L10n.tr("OK")
        } else {
            summary = result.errorSummary
        }
        detail = String(stdout.prefix(600))
        updatedAt = Date()
    }
}

extension ProbeResult: Equatable {
    // `updatedAt` is deliberately excluded so identical results don't
    // invalidate SwiftUI views on every poll.
    static func == (lhs: ProbeResult, rhs: ProbeResult) -> Bool {
        lhs.level == rhs.level && lhs.summary == rhs.summary && lhs.detail == rhs.detail
    }
}

/// Text + status dot rendered on a collapsed capsule.
struct WidgetBadge: Equatable, Sendable {
    var level: HealthLevel?
    var text: String
}

enum Format {
    /// Decimal separators follow the interface language ("3.8 GB" / "3,8 GB").
    static func bytes(_ value: UInt64) -> String {
        let locale = L10n.locale
        let gib = Double(value) / 1_073_741_824
        if gib >= 10 { return String(format: "%.0f GB", locale: locale, gib) }
        if gib >= 1 { return String(format: "%.1f GB", locale: locale, gib) }
        let mib = Double(value) / 1_048_576
        return String(format: "%.0f MB", locale: locale, mib)
    }

    /// Compact percentage for badges: "12%", "0.4%".
    static func percent(_ value: Double) -> String {
        if value >= 0.05, value < 1 { return String(format: "%.1f%%", locale: L10n.locale, value) }
        return "\(Int(value.rounded()))%"
    }
}
