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

/// What a command can print as a JSON object to draw its widget, like an
/// xbar plugin. Every field is optional.
struct CommandOutput: Equatable, Sendable {
    /// Replaces the first line of output on the widget.
    var text: String?
    var detail: String?
    /// An SF Symbol name.
    var symbol: String?
    var colorHex: String?
    /// 0…1, drawn as a bar.
    var progress: Double?
    /// "ok", "warning" or "critical": overrides the exit status.
    var level: HealthLevel?
    /// Opened by the details' button.
    var url: URL?

    /// `nil` unless `stdout` is a JSON object.
    init?(json stdout: String) {
        guard stdout.hasPrefix("{"),
              let object = try? JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any]
        else { return nil }
        text = object["text"] as? String
        detail = object["detail"] as? String
        symbol = object["symbol"] as? String
        colorHex = object["color"] as? String
        progress = (object["progress"] as? NSNumber).map { min(1, max(0, $0.doubleValue)) }
        level = switch (object["status"] as? String)?.lowercased() {
        case "ok", "green": .ok
        case "warning", "yellow": .warning
        case "critical", "error", "red": .critical
        default: nil
        }
        url = (object["url"] as? String).flatMap(URL.init(string:))
    }
}

/// Outcome of a custom command or command probe.
struct ProbeResult: Sendable {
    var level: HealthLevel
    var summary: String
    var detail: String
    var updatedAt: Date
    /// Set when the command printed a JSON object.
    var output: CommandOutput?

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
        if !result.timedOut, let output = CommandOutput(json: stdout) {
            self.output = output
            if let text = output.text { summary = String(text.prefix(42)) }
            detail = output.detail ?? ""
            if let level = output.level { self.level = level }
        }
    }
}

extension ProbeResult: Equatable {
    // `updatedAt` is deliberately excluded so identical results don't
    // invalidate SwiftUI views on every poll.
    static func == (lhs: ProbeResult, rhs: ProbeResult) -> Bool {
        lhs.level == rhs.level && lhs.summary == rhs.summary && lhs.detail == rhs.detail && lhs.output == rhs.output
    }
}

/// Text + status dot rendered on a collapsed capsule.
struct WidgetBadge: Equatable, Sendable {
    var level: HealthLevel?
    var text: String
    /// The widest texts `text` can become while only its numbers change.
    /// `BadgeView` reserves room for them: every capsule takes the widest
    /// capsule's width, so one reading gaining a digit would resize the dock.
    var reserve: [String] = []
}

extension WidgetBadge {
    /// "12% CPU • 3.8 GB"
    static func usage(cpu: Double, memory: UInt64) -> WidgetBadge {
        reading(cpu: cpu, memory: memory) { "\($0) CPU • \($1)" }
    }

    /// "SYS 12% • 3.8 GB", when none of the group's apps is running.
    static func systemUsage(cpu: Double, memory: UInt64) -> WidgetBadge {
        reading(cpu: cpu, memory: memory) { L10n.tr("SYS %@ • %@", $0, $1) }
    }

    /// "🦭 2 UP • 4% CPU"
    static func podmanRunning(containers: Int, cpu: Double) -> WidgetBadge {
        let make = { (count: Int, cpu: String) in L10n.tr("🦭 %lld UP • %@ CPU", count, cpu) }
        // Room for two-digit container counts.
        return WidgetBadge(
            text: make(containers, Format.percent(cpu)),
            reserve: Format.percentSamples.map { make(max(containers, 88), $0) }
        )
    }

    /// "2/4 ports": the count never has more digits than the total.
    static func fraction(_ count: Int, of total: Int, _ make: (Int, Int) -> String) -> WidgetBadge {
        WidgetBadge(text: make(count, total), reserve: [make(total, total)])
    }

    /// Appends " • 3.8 GB".
    func addingMemory(_ bytes: UInt64) -> WidgetBadge {
        let bases = reserve.isEmpty ? [text] : reserve
        return WidgetBadge(
            level: level,
            text: "\(text) • \(Format.bytes(bytes))",
            reserve: bases.flatMap { base in Format.bytesSamples.map { "\(base) • \($0)" } }
        )
    }

    private static func reading(cpu: Double, memory: UInt64, _ make: (String, String) -> String) -> WidgetBadge {
        WidgetBadge(
            text: make(Format.percent(cpu), Format.bytes(memory)),
            reserve: Format.percentSamples.flatMap { cpu in Format.bytesSamples.map { make(cpu, $0) } }
        )
    }
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

    /// Network speed: "176 KB/s", "2.3 MB/s"; `short` drops the "B/s" ("2.3M").
    static func rate(_ bytesPerSecond: Double, short: Bool = false) -> String {
        let units = short ? ["", "K", "M", "G"] : ["B/s", "KB/s", "MB/s", "GB/s"]
        var value = max(0, bytesPerSecond)
        var unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        let number = value < 10 && unit > 0
            ? String(format: "%.1f", locale: L10n.locale, value)
            : String(format: "%.0f", locale: L10n.locale, value)
        return short ? number + units[unit] : "\(number) \(units[unit])"
    }

    /// Compact counts: "980", "12K", "1.2M", "3.4B".
    static func count(_ value: Int) -> String {
        let number = Double(value)
        let (scaled, unit): (Double, String) = switch abs(number) {
        case ..<1000: (number, "")
        case ..<1_000_000: (number / 1000, "K")
        case ..<1_000_000_000: (number / 1_000_000, "M")
        default: (number / 1_000_000_000, "B")
        }
        if unit.isEmpty { return "\(value)" }
        let digits = abs(scaled) < 10 ? "%.1f" : "%.0f"
        return String(format: digits, locale: L10n.locale, scaled) + unit
    }

    /// Compact percentage for badges: "12%", "0.4%".
    static func percent(_ value: Double) -> String {
        if value >= 0.05, value < 1 { return String(format: "%.1f%%", locale: L10n.locale, value) }
        return "\(Int(value.rounded()))%"
    }

    /// The widest shapes `percent` produces: three digits, and one decimal.
    /// A group's CPU passes 100% on several cores.
    static var percentSamples: [String] { [percent(888), percent(0.88)] }

    /// The widest shapes `bytes` produces: three-digit MB, one-decimal GB, three-digit GB.
    static var bytesSamples: [String] {
        [bytes(888 * 1_048_576), bytes(8 * 1_073_741_824), bytes(888 * 1_073_741_824)]
    }
}
