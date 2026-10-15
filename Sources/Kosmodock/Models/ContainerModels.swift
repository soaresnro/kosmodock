import Foundation

struct ContainerRuntime: Equatable, Sendable {
    var kind: ContainerRuntimeKind
    var path: String

    static let podmanCandidates = [
        "/opt/homebrew/bin/podman",
        "/usr/local/bin/podman",
        "/opt/podman/bin/podman",
    ]

    static let dockerCandidates = [
        "/opt/homebrew/bin/docker",
        "/usr/local/bin/docker",
        "/Applications/Docker.app/Contents/Resources/bin/docker",
        "~/.orbstack/bin/docker",
    ]

    /// Finds the container CLI. GUI bundles don't inherit the shell's PATH, so
    /// well-known Homebrew/installer locations are probed directly.
    static func resolve(
        kind: ContainerRuntimeKind,
        overridePath: String?,
        allowFallback: Bool,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> ContainerRuntime? {
        if let raw = overridePath?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let path = (raw as NSString).expandingTildeInPath
            if isExecutable(path) {
                let inferred: ContainerRuntimeKind = (path as NSString).lastPathComponent.contains("docker") ? .docker : .podman
                return ContainerRuntime(kind: inferred, path: path)
            }
        }
        func first(_ candidates: [String], _ kind: ContainerRuntimeKind) -> ContainerRuntime? {
            candidates
                .map { ($0 as NSString).expandingTildeInPath }
                .first(where: isExecutable)
                .map { ContainerRuntime(kind: kind, path: $0) }
        }
        switch kind {
        case .podman:
            return first(podmanCandidates, .podman) ?? (allowFallback ? first(dockerCandidates, .docker) : nil)
        case .docker:
            return first(dockerCandidates, .docker) ?? (allowFallback ? first(podmanCandidates, .podman) : nil)
        }
    }
}

enum MachineStatus: Equatable, Sendable {
    case unknown
    case notInstalled
    case noMachine
    case stopped(String)
    case starting(String)
    case running(String)
    case daemonUnavailable

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var level: HealthLevel {
        switch self {
        case .running: .ok
        case .starting: .warning
        case .stopped, .noMachine, .daemonUnavailable: .critical
        case .unknown, .notInstalled: .unknown
        }
    }

    var title: String {
        switch self {
        case .unknown: L10n.tr("Checking…")
        case .notInstalled: L10n.tr("Not installed")
        case .noMachine: L10n.tr("No machine")
        case .stopped: L10n.tr("VM Stopped")
        case .starting: L10n.tr("Starting…")
        case .running: L10n.tr("Running")
        case .daemonUnavailable: L10n.tr("Daemon down")
        }
    }
}

enum MachineOperation: String, Sendable {
    case starting = "Starting"
    case stopping = "Stopping"
    case initializing = "Initializing"

    /// "Starting…" etc., shown while the operation runs.
    var progressTitle: String {
        switch self {
        case .starting: L10n.tr("Starting…")
        case .stopping: L10n.tr("Stopping…")
        case .initializing: L10n.tr("Initializing…")
        }
    }

    func failureMessage(_ detail: String) -> String {
        switch self {
        case .starting: L10n.tr("Starting the machine failed: %@", detail)
        case .stopping: L10n.tr("Stopping the machine failed: %@", detail)
        case .initializing: L10n.tr("Initializing the machine failed: %@", detail)
        }
    }
}

enum ContainerAction: String, CaseIterable, Sendable {
    case start
    case stop
    case restart

    func failureMessage(container: String, detail: String) -> String {
        switch self {
        case .start: L10n.tr("Could not start %@: %@", container, detail)
        case .stop: L10n.tr("Could not stop %@: %@", container, detail)
        case .restart: L10n.tr("Could not restart %@: %@", container, detail)
        }
    }
}

struct PortMapping: Equatable, Hashable, Sendable {
    var hostPort: Int
    var containerPort: Int
    var proto: String

    var label: String {
        hostPort == containerPort ? ":\(hostPort)" : ":\(hostPort)→\(containerPort)"
    }
}

struct PodmanMachine: Equatable, Sendable {
    var name: String
    var isDefault: Bool
    var running: Bool
    var starting: Bool
    var cpus: Int
    var memoryBytes: UInt64
    var vmType: String
}

struct ContainerInfo: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var image: String
    var state: String
    var status: String
    var ports: [PortMapping]

    var isRunning: Bool { state.lowercased() == "running" }

    var level: HealthLevel {
        switch state.lowercased() {
        case "running": .ok
        case "paused", "restarting", "created", "starting", "stopping": .warning
        default: .critical
        }
    }

    var displayStatus: String { status.isEmpty ? state.capitalized : status }

    /// "docker.io/library/postgres:16" → "postgres:16"
    var shortImage: String {
        image.split(separator: "/").last.map(String.init) ?? image
    }
}

// MARK: - Parsing
//
// Podman emits a JSON array with `Names: [String]` and structured `Ports`;
// Docker emits one JSON object per line with `Names: String` and a textual
// `Ports` column. Both shapes decode into `ContainerInfo`.

private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

private extension KeyedDecodingContainer where K == AnyKey {
    func string(_ keys: String...) -> String? {
        for key in keys {
            if let value = try? decodeIfPresent(String.self, forKey: AnyKey(key)) { return value }
        }
        return nil
    }

    func bool(_ key: String) -> Bool {
        (try? decodeIfPresent(Bool.self, forKey: AnyKey(key))) ?? false
    }

    func int(_ key: String) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: AnyKey(key)) { return value }
        return string(key).flatMap { Int($0) }
    }

    func uint64(_ key: String) -> UInt64? {
        if let value = try? decodeIfPresent(UInt64.self, forKey: AnyKey(key)) { return value }
        return string(key).flatMap { UInt64($0) }
    }
}

extension ContainerInfo: Decodable {
    private struct PodmanPort: Decodable {
        var host_port: Int?
        var container_port: Int?
        var `protocol`: String?
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = c.string("Id", "ID", "id") ?? UUID().uuidString
        if let names = try? c.decodeIfPresent([String].self, forKey: AnyKey("Names")), let first = names.first {
            name = first
        } else if let names = c.string("Names", "Name") {
            name = names.split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? names
        } else {
            name = String(id.prefix(12))
        }
        image = c.string("Image") ?? ""
        state = c.string("State") ?? ""
        status = c.string("Status") ?? ""

        if let structured = try? c.decodeIfPresent([PodmanPort].self, forKey: AnyKey("Ports")) {
            ports = structured.compactMap { port in
                guard let host = port.host_port, host > 0 else { return nil }
                return PortMapping(hostPort: host, containerPort: port.container_port ?? host, proto: port.protocol ?? "tcp")
            }
        } else if let text = c.string("Ports") {
            ports = ContainerInfo.parseDockerPorts(text)
        } else {
            ports = []
        }
        ports = ports.reduce(into: [PortMapping]()) { unique, port in
            if !unique.contains(port) { unique.append(port) }
        }
    }

    /// Parses Docker's `0.0.0.0:5432->5432/tcp, :::5432->5432/tcp` column.
    static func parseDockerPorts(_ text: String) -> [PortMapping] {
        text.split(separator: ",").compactMap { raw in
            let entry = raw.trimmingCharacters(in: .whitespaces)
            let sides = entry.components(separatedBy: "->")
            guard sides.count == 2 else { return nil }
            let hostSide = sides[0]
            guard let colon = hostSide.lastIndex(of: ":") else { return nil }
            let hostPortText = hostSide[hostSide.index(after: colon)...].split(separator: "-").first ?? ""
            let target = sides[1].split(separator: "/")
            let containerText = target.first?.split(separator: "-").first ?? ""
            guard let host = Int(hostPortText), let container = Int(containerText) else { return nil }
            return PortMapping(hostPort: host, containerPort: container, proto: target.count > 1 ? String(target[1]) : "tcp")
        }
    }

    /// Accepts a JSON array (Podman) or newline-delimited JSON (Docker).
    static func parseList(_ output: String) -> [ContainerInfo] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let decoder = JSONDecoder()
        let containers: [ContainerInfo]
        if trimmed.hasPrefix("[") {
            containers = (try? decoder.decode([ContainerInfo].self, from: Data(trimmed.utf8))) ?? []
        } else {
            containers = trimmed.split(whereSeparator: \.isNewline).compactMap { line in
                try? decoder.decode(ContainerInfo.self, from: Data(line.utf8))
            }
        }
        return containers.sorted { lhs, rhs in
            if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}

extension PodmanMachine: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        name = c.string("Name") ?? "podman-machine-default"
        isDefault = c.bool("Default")
        running = c.bool("Running")
        starting = c.bool("Starting")
        cpus = c.int("CPUs") ?? 0
        memoryBytes = c.uint64("Memory") ?? 0
        vmType = c.string("VMType") ?? ""
    }

    static func parseList(_ output: String) -> [PodmanMachine] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return (try? JSONDecoder().decode([PodmanMachine].self, from: Data(trimmed.utf8))) ?? []
    }
}
