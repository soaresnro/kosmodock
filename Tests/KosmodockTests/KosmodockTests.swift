import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import XCTest
@testable import Kosmodock

final class TilingEngineTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)

    func testSplit5050() {
        let frames = TilingEngine.frames(for: .splitHorizontal50_50, count: 2, in: screen)
        XCTAssertEqual(frames, [CGRect(x: 0, y: 0, width: 500, height: 800), CGRect(x: 500, y: 0, width: 500, height: 800)])
    }

    func testDev7030StacksSecondAndThirdOnTheRight() {
        let frames = TilingEngine.frames(for: .dev70_30Stack, count: 3, in: screen)
        XCTAssertEqual(frames, [
            CGRect(x: 0, y: 0, width: 700, height: 800),
            CGRect(x: 700, y: 0, width: 300, height: 400),
            CGRect(x: 700, y: 400, width: 300, height: 400),
        ])
    }

    func testMainPlusBottom25() {
        let frames = TilingEngine.frames(for: .mainPlusBottom25, count: 3, in: screen)
        XCTAssertEqual(frames, [
            CGRect(x: 0, y: 0, width: 1000, height: 600),
            CGRect(x: 0, y: 600, width: 500, height: 200),
            CGRect(x: 500, y: 600, width: 500, height: 200),
        ])
    }

    func testGrid2x2() {
        let frames = TilingEngine.frames(for: .grid2x2, count: 4, in: screen)
        XCTAssertEqual(frames, [
            CGRect(x: 0, y: 0, width: 500, height: 400),
            CGRect(x: 500, y: 0, width: 500, height: 400),
            CGRect(x: 0, y: 400, width: 500, height: 400),
            CGRect(x: 500, y: 400, width: 500, height: 400),
        ])
    }

    func testMaximizeAllFillsTheFrame() {
        let frames = TilingEngine.frames(for: .maximizeAll, count: 3, in: screen)
        XCTAssertEqual(frames, Array(repeating: screen, count: 3))
    }

    func testGapIsUniformBetweenWindowsAndEdges() {
        let frames = TilingEngine.frames(for: .splitHorizontal50_50, count: 2, in: screen, gap: 10)
        XCTAssertEqual(frames[0], CGRect(x: 10, y: 10, width: 485, height: 780))
        XCTAssertEqual(frames[1], CGRect(x: 505, y: 10, width: 485, height: 780))
        XCTAssertEqual(frames[1].minX - frames[0].maxX, 10, "gap between windows")
        XCTAssertEqual(1000 - frames[1].maxX, 10, "gap at the screen edge")
    }

    func testCocoaToAccessibilityFlip() {
        // A 1000x775 visible frame sitting 25pt above the bottom of a 900pt-tall primary display.
        let cocoa = CGRect(x: 0, y: 25, width: 1000, height: 850)
        XCTAssertEqual(TilingEngine.accessibilityRect(fromCocoa: cocoa, primaryScreenHeight: 900),
                       CGRect(x: 0, y: 25, width: 1000, height: 850))
        let top = CGRect(x: 0, y: 600, width: 100, height: 300)
        XCTAssertEqual(TilingEngine.accessibilityRect(fromCocoa: top, primaryScreenHeight: 900).minY, 0)
    }
}

final class ConfigDecodingTests: XCTestCase {
    func testMinimalConfigFillsDefaults() throws {
        let json = #"{ "groups": [ { "name": "Dev Tools", "apps": [ { "path": "/Applications/Cursor.app" } ] } ] }"#
        let config = try JSONDecoder().decode(DockConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.theme, ThemeConfig())
        XCTAssertEqual(config.telemetry.pollInterval, 3)
        XCTAssertEqual(config.groups.first?.id, "dev-tools")
        XCTAssertEqual(config.groups.first?.apps.first?.name, "Cursor")
        XCTAssertEqual(config.groups.first?.layout, .splitHorizontal50_50)
    }

    func testDuplicateGroupIDsAreMadeUnique() throws {
        let json = #"{ "groups": [ { "name": "Web" }, { "name": "Web" }, { "id": "web", "name": "Other" } ] }"#
        let config = try JSONDecoder().decode(DockConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.groups.map(\.id), ["web", "web-2", "web-3"])
    }

    func testUnknownWidgetTypeIsReported() {
        let json = #"{ "groups": [ { "name": "X", "widget": { "type": "bogus" } } ] }"#
        XCTAssertThrowsError(try JSONDecoder().decode(DockConfig.self, from: Data(json.utf8))) { error in
            XCTAssertTrue(ConfigService.describe(error).contains("groups"))
        }
    }

    func testRoundTrip() throws {
        var config = DockConfig()
        config.groups = [DockGroup(
            id: "data", name: "Data", apps: [DockApp(name: "DBeaver", bundleId: "org.jkiss.dbeaver.core.product")],
            widget: WidgetConfig(type: .portProbe, ports: [5432, 6379], probes: [HealthProbe(name: "API", command: "true")]),
            layout: .grid2x2, expansionMode: .accordion
        )]
        let data = try JSONEncoder().encode(config)
        XCTAssertEqual(try JSONDecoder().decode(DockConfig.self, from: data), config)
    }

    func testDefaultConfigUsesInstalledApps() {
        let installed = [
            InstalledApp(name: "Rider", path: "/Users/x/Applications/Rider.app", bundleID: "com.jetbrains.rider"),
            InstalledApp(name: "iTerm", path: "/Applications/iTerm.app", bundleID: "com.googlecode.iterm2"),
            InstalledApp(name: "Podman Desktop", path: "/Applications/Podman Desktop.app", bundleID: "io.podmandesktop.PodmanDesktop"),
            InstalledApp(name: "Apidog", path: "/Applications/Apidog.app", bundleID: "com.example.unknown"),
        ]
        let config = AppDiscovery.makeDefaultConfig(installed: installed, hasContainerRuntime: true)
        let byName = Dictionary(uniqueKeysWithValues: config.groups.map { ($0.name, $0) })
        XCTAssertEqual(byName["Code"]?.apps.map(\.name), ["Rider", "iTerm"])
        XCTAssertEqual(byName["Containers"]?.widget.type, .podman)
        XCTAssertEqual(byName["Data & APIs"]?.apps.map(\.name), ["Apidog"])
        XCTAssertNil(byName["Web"])
    }
}

final class ContainerParsingTests: XCTestCase {
    func testPodmanJSONArray() {
        let json = """
        [
          {"Id":"abc123def4567890","Names":["postgres"],"Image":"docker.io/library/postgres:16","State":"running","Status":"Up 2 hours",
           "Ports":[{"host_ip":"","container_port":5432,"host_port":5432,"range":1,"protocol":"tcp"}]},
          {"Id":"zzz","Names":["redis"],"Image":"docker.io/library/redis:7","State":"exited","Status":"Exited (0) 3 minutes ago","Ports":null}
        ]
        """
        let containers = ContainerInfo.parseList(json)
        XCTAssertEqual(containers.count, 2)
        XCTAssertEqual(containers[0].name, "postgres")
        XCTAssertTrue(containers[0].isRunning)
        XCTAssertEqual(containers[0].shortImage, "postgres:16")
        XCTAssertEqual(containers[0].ports, [PortMapping(hostPort: 5432, containerPort: 5432, proto: "tcp")])
        XCTAssertEqual(containers[1].level, .critical)
        XCTAssertTrue(containers[1].ports.isEmpty)
    }

    func testDockerNDJSON() {
        let ndjson = """
        {"ID":"111","Names":"api","Image":"my/api:latest","State":"running","Status":"Up 5 minutes","Ports":"0.0.0.0:8080->80/tcp, :::8080->80/tcp"}
        {"ID":"222","Names":"worker","Image":"my/worker","State":"exited","Status":"Exited (1)","Ports":""}
        """
        let containers = ContainerInfo.parseList(ndjson)
        XCTAssertEqual(containers.map(\.name), ["api", "worker"])
        XCTAssertEqual(containers[0].ports, [PortMapping(hostPort: 8080, containerPort: 80, proto: "tcp")])
    }

    func testPodmanMachineList() {
        let json = """
        [{"Name":"podman-machine-default","Default":true,"Running":true,"Starting":false,"VMType":"applehv","CPUs":4,"Memory":"3999268864"}]
        """
        let machines = PodmanMachine.parseList(json)
        XCTAssertEqual(machines.first?.running, true)
        XCTAssertEqual(machines.first?.cpus, 4)
        XCTAssertEqual(machines.first?.memoryBytes, 3_999_268_864)
    }

    func testRuntimeResolutionPrefersHomebrewPodman() {
        let available: Set<String> = ["/usr/local/bin/podman", "/opt/homebrew/bin/podman", "/opt/homebrew/bin/docker"]
        let runtime = ContainerRuntime.resolve(kind: .podman, overridePath: nil, allowFallback: true) { available.contains($0) }
        XCTAssertEqual(runtime, ContainerRuntime(kind: .podman, path: "/opt/homebrew/bin/podman"))
        let docker = ContainerRuntime.resolve(kind: .podman, overridePath: nil, allowFallback: true) { $0 == "/opt/homebrew/bin/docker" }
        XCTAssertEqual(docker?.kind, .docker)
        XCTAssertNil(ContainerRuntime.resolve(kind: .podman, overridePath: nil, allowFallback: false) { $0 == "/opt/homebrew/bin/docker" })
    }
}

final class ProbeTests: XCTestCase {
    func testLsofParsing() {
        let output = "p101\ncpostgres\nf7\nn*:5432\nf8\nn[::1]:5432\np202\ncredis-server\nf6\nn127.0.0.1:6379\n"
        XCTAssertEqual(PortScanner.parse(output), [5432: "postgres", 6379: "redis-server"])
    }

    func testShellResultMapping() {
        XCTAssertEqual(ProbeResult(shell: ShellResult(exitCode: 0, stdout: "healthy\nmore", stderr: "")).level, .ok)
        XCTAssertEqual(ProbeResult(shell: ShellResult(exitCode: 0, stdout: "healthy\nmore", stderr: "")).summary, "healthy")
        XCTAssertEqual(ProbeResult(shell: ShellResult(exitCode: 1, stdout: "", stderr: "degraded")).level, .warning)
        XCTAssertEqual(ProbeResult(shell: ShellResult(exitCode: 7, stdout: "", stderr: "connection refused")).summary, "connection refused")
        XCTAssertEqual(ProbeResult(shell: ShellResult(exitCode: 0, stdout: "", stderr: "", timedOut: true)).level, .critical)
    }

    func testShellRunnerInjectsHomebrewPath() async {
        let result = await ShellRunner.shell("echo $PATH", timeout: 5)
        XCTAssertTrue(result.stdout.hasPrefix("/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"))
    }

    func testShellRunnerTimesOut() async {
        let start = Date()
        let result = await ShellRunner.shell("sleep 10", timeout: 0.5)
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
    }
}

final class DockFailsafeTests: XCTestCase {
    /// Simulates a crash: the watched process dies without cleaning up, and
    /// the watchdog must run the sentinel's restore command exactly once.
    func testWatchdogRunsSentinelCommandWhenProcessDies() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kosmodock-watchdog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sentinel = dir.appendingPathComponent("restore.sh")
        let marker = dir.appendingPathComponent("restored")
        try "echo ran >> '\(marker.path)'\n".write(to: sentinel, atomically: true, encoding: .utf8)

        let victim = Process()
        victim.executableURL = URL(fileURLWithPath: "/bin/sleep")
        victim.arguments = ["1"]
        try victim.run()

        let watchdog = Process()
        watchdog.executableURL = URL(fileURLWithPath: "/bin/sh")
        watchdog.arguments = ["-c", SystemDockManager.watchdogScript, "test-watchdog", String(victim.processIdentifier), sentinel.path]
        try watchdog.run()
        watchdog.waitUntilExit()

        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "ran\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
    }
}

final class ScreenSpaceTests: XCTestCase {
    // AX space: a 1352×878 display; menu bar ends at y=29, reserved line at y=780.
    private let screen = CGRect(x: 0, y: 0, width: 1352, height: 878)
    private let work = CGRect(x: 0, y: 29, width: 1352, height: 751)

    func testMaximizedWindowShrinksToTheReservedLine() {
        let window = CGRect(x: 0, y: 29, width: 1352, height: 849)
        let adjusted = ScreenSpaceMath.adjustedFrame(for: window, workArea: work, screen: screen, canResize: true)
        XCTAssertEqual(adjusted, CGRect(x: 0, y: 29, width: 1352, height: 751))
    }

    func testLowWindowThatFitsMovesUp() {
        let window = CGRect(x: 200, y: 500, width: 600, height: 400)
        let adjusted = ScreenSpaceMath.adjustedFrame(for: window, workArea: work, screen: screen, canResize: true)
        XCTAssertEqual(adjusted, CGRect(x: 200, y: 380, width: 600, height: 400))
    }

    func testFixedSizeWindowOnlyMoves() {
        let window = CGRect(x: 0, y: 100, width: 800, height: 820)
        let adjusted = ScreenSpaceMath.adjustedFrame(for: window, workArea: work, screen: screen, canResize: false)
        XCTAssertEqual(adjusted, CGRect(x: 0, y: 29, width: 800, height: 820))
    }

    func testCompliantWindowIsLeftAlone() {
        let window = CGRect(x: 100, y: 100, width: 600, height: 680)
        XCTAssertNil(ScreenSpaceMath.adjustedFrame(for: window, workArea: work, screen: screen, canResize: true))
    }

    func testWindowOnAnotherDisplayIsIgnored() {
        let window = CGRect(x: 1500, y: 100, width: 800, height: 1000)
        XCTAssertNil(ScreenSpaceMath.adjustedFrame(for: window, workArea: work, screen: screen, canResize: true))
    }

    func testSafeWorkAreaReservedHeightAndFlip() {
        let area = SafeWorkArea(
            screenFrame: CGRect(x: 0, y: 0, width: 1352, height: 878),
            workFrame: CGRect(x: 0, y: 98, width: 1352, height: 751),
            dockFrame: CGRect(x: 150, y: 10, width: 1050, height: 64),
            reservesSpace: true,
            primaryScreenHeight: 878
        )
        XCTAssertEqual(area.reservedBottomHeight, 98)
        XCTAssertEqual(area.accessibilityWorkFrame, CGRect(x: 0, y: 29, width: 1352, height: 751))
        XCTAssertEqual(area.accessibilityWorkFrame.maxY, 878 - 98, "reserved line = screenHeight - reservedBottomHeight")
    }

    func testIntellihideOverlap() {
        let dock = CGRect(x: 150, y: 800, width: 1050, height: 64)
        XCTAssertTrue(IntellihideController.overlaps(windowBounds: [CGRect(x: 0, y: 29, width: 1352, height: 849)], dockRect: dock))
        XCTAssertFalse(IntellihideController.overlaps(windowBounds: [CGRect(x: 0, y: 29, width: 1352, height: 700)], dockRect: dock))
        XCTAssertFalse(IntellihideController.overlaps(windowBounds: [], dockRect: dock))
    }
}

final class GroupMinimizeTests: XCTestCase {
    private let groups: [(id: String, name: String, bundleIDs: Set<String>)] = [
        (id: "code", name: "Code", bundleIDs: ["com.jetbrains.rider", "com.googlecode.iterm2"]),
        (id: "system", name: "System", bundleIDs: ["com.apple.finder"]),
        (id: "web", name: "Web", bundleIDs: ["com.google.Chrome"]),
    ]

    func testGroupedAppResolvesToItsGroup() {
        XCTAssertEqual(GroupResolver.groupID(for: "com.jetbrains.rider", groups: groups), "code")
        XCTAssertEqual(GroupResolver.groupID(for: "com.google.Chrome", groups: groups), "web")
    }

    func testUngroupedAppFallsBackToSystemThenLast() {
        XCTAssertEqual(GroupResolver.groupID(for: "com.example.Unknown", groups: groups), "system")
        XCTAssertEqual(GroupResolver.groupID(for: "com.example.Unknown", groups: Array(groups.prefix(1))), "code")
        XCTAssertNil(GroupResolver.groupID(for: "com.example.Unknown", groups: []))
    }

    func testRestoreCommandPutsBackOriginalMinimizeSettings() {
        let command = SystemDockManager.restoreCommand(for: .init(autohide: false, autohideDelay: nil, minimizeToApplication: false, minimizeEffect: "genie"))
        XCTAssertTrue(command.contains("defaults write com.apple.dock minimize-to-application -bool false"))
        XCTAssertTrue(command.contains("defaults write com.apple.dock mineffect -string genie"))
        XCTAssertTrue(command.contains("defaults delete com.apple.dock autohide-delay"))
        XCTAssertTrue(command.hasSuffix("killall Dock\n"))
    }

    func testRestoreCommandDeletesKeysThatDidNotExistAndSanitizes() {
        let missing = SystemDockManager.restoreCommand(for: .init(autohide: true, autohideDelay: 0.2, minimizeToApplication: nil, minimizeEffect: nil))
        XCTAssertTrue(missing.contains("defaults delete com.apple.dock minimize-to-application"))
        XCTAssertTrue(missing.contains("defaults delete com.apple.dock mineffect"))
        XCTAssertTrue(missing.contains("autohide-delay -float 0.2"))
        let hostile = SystemDockManager.restoreCommand(for: .init(autohide: false, autohideDelay: nil, minimizeToApplication: nil, minimizeEffect: "scale; rm -rf ~"))
        XCTAssertTrue(hostile.contains("mineffect -string scalermrf;"))
        XCTAssertFalse(hostile.contains("rm -rf"))
    }

    func testSuppressCommandConfiguresMinimizeTarget() {
        XCTAssertTrue(SystemDockManager.suppressCommand.contains("minimize-to-application -bool true"))
        XCTAssertTrue(SystemDockManager.suppressCommand.contains("mineffect -string scale"))
    }

    @MainActor
    func testCapsuleRectConvertsToScreenCoordinates() {
        let tracker = GroupGeometryTracker()
        // Capsule at (100, 40) in the hosting view (top-left origin), panel 1000×120 at (176, -18).
        tracker.capsuleFrames = ["code": CGRect(x: 100, y: 40, width: 140, height: 46)]
        let rect = tracker.screenRect(forGroup: "code", panelFrame: CGRect(x: 176, y: -18, width: 1000, height: 120), shownOriginY: -18)
        XCTAssertEqual(rect, CGRect(x: 276, y: -18 + 120 - 86, width: 140, height: 46))
        XCTAssertNil(tracker.screenRect(forGroup: "missing", panelFrame: .zero, shownOriginY: 0))
    }
}

final class ClearanceTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1352, height: 878)
    // New reserved line at y=804 (5 pt above a dock whose top is at 809).
    private let work = CGRect(x: 0, y: 29, width: 1352, height: 775)

    func testWindowFittedToPreviousLineFollowsItDown() {
        let window = CGRect(x: 0, y: 29, width: 1352, height: 767) // ended on the old 796 line
        let grown = ScreenSpaceMath.grownFrame(for: window, previousLimit: 796, workArea: work, screen: screen, canResize: true)
        XCTAssertEqual(grown, CGRect(x: 0, y: 29, width: 1352, height: 775))
        XCTAssertEqual(grown?.maxY, 804)
    }

    func testOnlyWindowsOnThePreviousLineGrow() {
        let shorter = CGRect(x: 100, y: 100, width: 600, height: 500)
        XCTAssertNil(ScreenSpaceMath.grownFrame(for: shorter, previousLimit: 796, workArea: work, screen: screen, canResize: true))
        let fixed = CGRect(x: 0, y: 29, width: 800, height: 767)
        XCTAssertNil(ScreenSpaceMath.grownFrame(for: fixed, previousLimit: 796, workArea: work, screen: screen, canResize: false))
    }

    func testNoGrowthWhenTheLineMovesUp() {
        let window = CGRect(x: 0, y: 29, width: 1352, height: 767)
        let higher = CGRect(x: 0, y: 29, width: 1352, height: 700)
        XCTAssertNil(ScreenSpaceMath.grownFrame(for: window, previousLimit: 796, workArea: higher, screen: screen, canResize: true))
    }

    func testDefaultClearanceIsFivePoints() {
        XCTAssertEqual(ThemeConfig().dockClearance, 5)
        let decoded = try? JSONDecoder().decode(ThemeConfig.self, from: Data(#"{ "dockClearance": 2 }"#.utf8))
        XCTAssertEqual(decoded?.dockClearance, 2)
    }
}

final class LocalizationTests: XCTestCase {
    private var localizationDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Localization")
    }

    private func table(_ language: String) throws -> [String: String] {
        let url = localizationDirectory.appendingPathComponent("\(language).lproj/Localizable.strings")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }

    func testEveryLanguageHasTheSameKeys() throws {
        let english = try table("en")
        XCTAssertGreaterThan(english.count, 200)
        for language in ["pt-BR", "es"] {
            XCTAssertEqual(Set(try table(language).keys), Set(english.keys), "\(language) keys differ from en")
        }
    }

    func testFormatSpecifiersMatchInEveryTranslation() throws {
        let specifier = try NSRegularExpression(pattern: "%(?:\\d+\\$)?(?:lld|ld|d|@|lf|f)")
        func specifiers(_ text: String) -> [String] {
            specifier.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .map { String(text[Range($0.range, in: text)!]) }.sorted()
        }
        for language in ["en", "pt-BR", "es"] {
            for (key, value) in try table(language) {
                XCTAssertEqual(specifiers(key), specifiers(value), "\(language): “\(key)” → “\(value)”")
            }
        }
    }

    func testTranslationsAreNotLeftInEnglish() throws {
        let portuguese = try table("pt-BR")
        XCTAssertEqual(portuguese["Launch & Tile"], "Abrir e Organizar")
        XCTAssertEqual(try table("es")["Minimized Windows"], "Ventanas minimizadas")
        XCTAssertEqual(try table("en")["Focus mode (short)"], "Focus")
    }

    func testFormattingFallsBackToTheKey() {
        XCTAssertEqual(L10n.tr("%lld/%lld open", 2, 5), "2/5 open")
        XCTAssertEqual(L10n.tr("Restore “%@”", "Notes"), "Restore “Notes”")
    }

    func testLanguageConfigDecoding() throws {
        XCTAssertEqual(BehaviorConfig().language, .system)
        let decoded = try JSONDecoder().decode(BehaviorConfig.self, from: Data(#"{ "language": "es-ES" }"#.utf8))
        XCTAssertEqual(decoded.language, .spanishES)
        XCTAssertEqual(AppLanguage.portugueseBR.lprojName, "pt-BR")
        XCTAssertEqual(AppLanguage.spanishES.locale.identifier, "es_ES")
    }

    /// Texts Kosmodock saves in config.json are recognized in whatever language
    /// they were saved in, so they can show in the interface language.
    func testConfigTextsAreRecognizedInEveryLanguage() throws {
        let tables = try ["pt-BR", "es"].map(table)
        let index = L10n.index(of: [L10n.battery, L10n.acPower], translations: tables.map { table in { table[$0] ?? $0 } })
        for spelling in ["Battery", "BATTERY", "Bateria", "bateria", "Batería"] {
            XCTAssertEqual(index[spelling.lowercased()], "Battery", spelling)
        }
        XCTAssertEqual(index["na tomada"], "AC power")
        XCTAssertEqual(index["enchufado"], "AC power")
        XCTAssertNil(index["energia"], "a label the user typed isn't a config text")
    }

    func testUserTextIsShownAsIs() {
        XCTAssertEqual(L10n.configText("Energia"), "Energia")
        XCTAssertEqual(L10n.configText("🔋 85%"), "🔋 85%")
        // Tests have no app bundle, so a config text falls back to English.
        XCTAssertEqual(L10n.configText(" battery "), "Battery")
    }

    func testDefaultSystemGroupSavesConfigTextsInEnglish() throws {
        let config = AppDiscovery.makeDefaultConfig(installed: [], hasContainerRuntime: false)
        let system = try XCTUnwrap(config.groups.first { $0.name == "System" })
        XCTAssertEqual(system.widget.label, "Battery")
        XCTAssertEqual(system.widget.command?.hasSuffix("|| echo 'AC power'"), true)
    }
}

final class LegacyMigrationTests: XCTestCase {
    func testCopiesConfigAndMovesRestoreCommandOnce() throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory.appendingPathComponent("kosmodock-home-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: home) }
        let legacy = home.appendingPathComponent(".config/orbitdock")
        try fileManager.createDirectory(at: legacy, withIntermediateDirectories: true)
        try #"{ "groups": [] }"#.write(to: legacy.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try "killall Dock\n".write(to: legacy.appendingPathComponent(".restore-native-dock.sh"), atomically: true, encoding: .utf8)

        LegacyMigration.run(fileManager: fileManager, home: home)

        let current = home.appendingPathComponent(".config/kosmodock")
        XCTAssertEqual(try String(contentsOf: current.appendingPathComponent("config.json"), encoding: .utf8), #"{ "groups": [] }"#)
        XCTAssertTrue(fileManager.fileExists(atPath: legacy.appendingPathComponent("config.json").path), "original kept as backup")
        XCTAssertTrue(fileManager.fileExists(atPath: current.appendingPathComponent(".restore-native-dock.sh").path))
        XCTAssertFalse(fileManager.fileExists(atPath: legacy.appendingPathComponent(".restore-native-dock.sh").path), "restore command must not exist twice")

        // A second run never overwrites the new config.
        try #"{ "groups": [{"name": "Edited"}] }"#.write(to: current.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        LegacyMigration.run(fileManager: fileManager, home: home)
        XCTAssertTrue(try String(contentsOf: current.appendingPathComponent("config.json"), encoding: .utf8).contains("Edited"))
    }
}

/// Every capsule takes the widest capsule's width, so a badge that changed
/// width with each reading made the whole dock grow and shrink.
@MainActor
final class BadgeWidthTests: XCTestCase {
    private let gib: UInt64 = 1_073_741_824

    private func width(_ badge: WidgetBadge) -> CGFloat {
        NSHostingView(rootView: BadgeView(badge: badge)).fittingSize.width
    }

    private func assertSameWidth(_ badges: [WidgetBadge], file: StaticString = #filePath, line: UInt = #line) {
        let widths = badges.map(width)
        XCTAssertEqual(Set(widths).count, 1, "widths \(widths) for \(badges.map(\.text))", file: file, line: line)
        // Without the reserve, the same readings would have different widths.
        let bare = badges.map { width(WidgetBadge(text: $0.text)) }
        XCTAssertGreaterThan(Set(bare).count, 1, "readings too similar to prove anything", file: file, line: line)
    }

    func testCPUAndMemoryReadingsKeepTheWidth() {
        let readings: [(Double, UInt64)] = [
            (0, 0), (0.4, 900 * 1_048_576), (7, 3 * gib), (12, 9 * gib), (99, 12 * gib), (120, 64 * gib), (640, 512 * gib),
        ]
        assertSameWidth(readings.map { WidgetBadge.usage(cpu: $0.0, memory: $0.1) })
        assertSameWidth(readings.map { WidgetBadge.systemUsage(cpu: $0.0, memory: $0.1) })
    }

    func testPodmanReadingsKeepTheWidth() {
        let readings: [(Int, Double)] = [(0, 0), (1, 0.3), (3, 9), (12, 45), (40, 310)]
        assertSameWidth(readings.map { WidgetBadge.podmanRunning(containers: $0.0, cpu: $0.1) })
    }

    func testPortCountsAndMemoryKeepTheWidth() {
        let ports = (0...12).map { up in
            WidgetBadge.fraction(up, of: 12) { "\($0)/\($1) ports" }.addingMemory(UInt64(up) * 3 * gib)
        }
        assertSameWidth(ports)
    }

    func testFixedTextHasNoReserve() {
        let badge = WidgetBadge(text: "🦭 VM Stopped")
        XCTAssertTrue(badge.reserve.isEmpty)
        XCTAssertTrue(badge.addingMemory(gib).reserve.allSatisfy { $0.hasPrefix("🦭 VM Stopped • ") })
    }
}

/// Collapsed capsules share the widest one's width, as far as the screen allows.
@MainActor
final class CapsuleRowTests: XCTestCase {
    private func widths(_ natural: [CGFloat], equalized: [Bool]? = nil, maxWidth: CGFloat) -> [CGFloat] {
        CapsuleRow.widths(natural: natural, equalized: equalized ?? natural.map { _ in true }, spacing: 0, maxWidth: maxWidth)
    }

    func testCapsulesTakeTheWidestWidthWhenItFits() {
        XCTAssertEqual(widths([100, 60, 80], maxWidth: 1000), [100, 100, 100])
    }

    func testNarrowCapsulesWidenOnlyAsFarAsTheRowFits() {
        // Fully equal would be 360 + 30; the 300 left for capsules lifts the
        // two narrow ones to 90 and leaves the widest as it is.
        let result = widths([120, 60, 80, 30], equalized: [true, true, true, false], maxWidth: 330)
        XCTAssertEqual(result, [120, 90, 90, 30])
        XCTAssertEqual(result.reduce(0, +), 330)
    }

    func testRowThatCannotFitIsFullyEqualized() {
        XCTAssertEqual(widths([120, 60, 80], maxWidth: 200), [120, 120, 120])
    }

    func testSpacingAndUnequalizedViewsCountAgainstTheWidth() {
        let result = CapsuleRow.widths(natural: [50, 20, 30], equalized: [true, true, false], spacing: 10, maxWidth: 140)
        XCTAssertEqual(result, [50, 40, 30])
        XCTAssertEqual(CapsuleRow.widths(natural: [50, 20], equalized: [false, false], spacing: 10, maxWidth: 10), [50, 20])
    }

    /// One wide badge used to widen every capsule past the screen, and the
    /// dock fell back to the density that shows no badges at all.
    func testWideCapsuleDoesNotPushTheRowToTheFallback() {
        let row = CapsuleRow(spacing: 0, maxWidth: 200) {
            Color.clear.frame(width: 80, height: 10).frame(maxWidth: .infinity).layoutValue(key: EqualizesWidthKey.self, value: true)
            Color.clear.frame(width: 40, height: 10).frame(maxWidth: .infinity).layoutValue(key: EqualizesWidthKey.self, value: true)
            Color.clear.frame(width: 40, height: 10).frame(maxWidth: .infinity).layoutValue(key: EqualizesWidthKey.self, value: true)
        }
        let fits = ViewThatFits(in: .horizontal) {
            row.fixedSize()
            Color.clear.frame(width: 10, height: 99)
        }
        .frame(width: 200)
        XCTAssertEqual(NSHostingView(rootView: row.fixedSize()).fittingSize.width, 200)
        XCTAssertEqual(NSHostingView(rootView: fits).fittingSize.height, 10)
    }
}

/// Styles are presets of the bar's surface; old configs keep their glass.
final class ThemeStyleTests: XCTestCase {
    private func theme(_ json: String) throws -> ThemeConfig {
        try JSONDecoder().decode(ThemeConfig.self, from: Data(json.utf8))
    }

    func testThemeFromBeforeStylesKeepsItsGlass() throws {
        let edited = try theme(#"{ "cornerRadius": 18, "glassOpacity": 0.5, "borderOpacity": 0.3, "material": "menu" }"#)
        XCTAssertEqual(edited.style, .glass)
        XCTAssertEqual(edited.surface.cornerRadius, 18)
        XCTAssertEqual(edited.surface.fillOpacity, 0.5)
        XCTAssertEqual(edited.surface.borderOpacity, 0.3)
        XCTAssertEqual(edited.surface.material, .menu)
        XCTAssertTrue(edited.isCustomized)

        let untouched = try theme(#"{ "cornerRadius": 22, "glassOpacity": 0.35, "borderOpacity": 0.6, "material": "hudWindow" }"#)
        XCTAssertEqual(untouched, ThemeConfig())
        XCTAssertFalse(untouched.isCustomized)
    }

    func testOldGlassKeysDontOverrideAChosenStyle() throws {
        let neon = try theme(#"{ "style": "neon", "cornerRadius": 22, "glassOpacity": 0.35, "borderOpacity": 0.6 }"#)
        XCTAssertEqual(neon.surface, DockStyle.neon.surface)
        XCTAssertFalse(neon.isCustomized)
    }

    func testMissingSurfaceKeysFallBackToTheStyle() throws {
        let neon = try theme(#"{ "style": "neon", "surface": { "cornerRadius": 10 } }"#)
        var expected = DockStyle.neon.surface
        expected.cornerRadius = 10
        XCTAssertEqual(neon.surface, expected)
    }

    func testRoundTripKeepsARemovedFill() throws {
        var original = ThemeConfig()
        original.apply(.midnight)
        original.surface.fillTopHex = nil
        original.surface.fillBottomHex = nil
        let decoded = try JSONDecoder().decode(ThemeConfig.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }

    func testRestoringAStyleDropsTheEdits() {
        var theme = ThemeConfig()
        theme.apply(.paper)
        XCTAssertFalse(theme.isCustomized)
        theme.surface.borderWidth = 2.5
        XCTAssertTrue(theme.isCustomized)
        theme.apply(theme.style)
        XCTAssertEqual(theme.surface, DockStyle.paper.surface)
    }

    func testColoredFillsPickAReadableScheme() {
        XCTAssertNil(DockStyle.glass.surface.colorScheme, "the window background already follows the mode")
        XCTAssertNil(DockStyle.floating.surface.colorScheme)
        XCTAssertEqual(DockStyle.paper.surface.colorScheme, .light)
        for style in [DockStyle.midnight, .graphite, .neon] {
            XCTAssertEqual(style.surface.colorScheme, .dark, style.rawValue)
        }
    }

    func testEveryStyleColorParses() {
        for style in DockStyle.allCases {
            let surface = style.surface
            for hex in [surface.borderHex, surface.glowHex] + [surface.fillTopHex, surface.fillBottomHex].compactMap({ $0 }) {
                XCTAssertNotNil(Color(hex: hex), "\(style.rawValue): \(hex)")
            }
        }
    }

    func testOnlyTheFloatingStyleHasNoBar() {
        XCTAssertEqual(DockStyle.allCases.filter { !$0.surface.isVisible }, [.floating])
    }

    func testPopoversStayOnGlass() {
        var theme = ThemeConfig()
        theme.surface.cornerRadius = 30
        XCTAssertEqual(theme.popoverSurface.cornerRadius, 30, "glass edits reach the popover")
        theme.apply(.neon)
        XCTAssertEqual(theme.popoverSurface, DockStyle.glass.surface)
    }
}

/// Icons under the pointer grow with their neighbors without overlapping.
final class MagnifierTests: XCTestCase {
    private let magnifier = Magnifier(size: 34, spacing: 6, maxScale: 1.5)

    func testNothingGrowsWithoutAPointer() {
        XCTAssertEqual(magnifier.scales(count: 5, pointer: nil), [1, 1, 1, 1, 1])
    }

    func testTheIconUnderThePointerGrowsMost() {
        let scales = magnifier.scales(count: 7, pointer: magnifier.center(of: 3))
        XCTAssertEqual(scales[3], 1.5, accuracy: 0.0001)
        XCTAssertGreaterThan(scales[3], scales[2])
        XCTAssertEqual(scales[2], scales[4], accuracy: 0.0001)
        XCTAssertGreaterThan(scales[2], 1)
        XCTAssertEqual(scales[0], 1, "past the reach nothing grows")
        XCTAssertEqual(scales[6], 1)
    }

    func testGrownIconsKeepTheirSpacing() {
        let count = 6
        for pointer in stride(from: CGFloat(-10), through: 250, by: 7) {
            let scales = magnifier.scales(count: count, pointer: pointer)
            let offsets = magnifier.offsets(scales: scales)
            for index in 0..<(count - 1) {
                let right = magnifier.center(of: index) + offsets[index] + 34 * scales[index] / 2
                let left = magnifier.center(of: index + 1) + offsets[index + 1] - 34 * scales[index + 1] / 2
                XCTAssertEqual(left - right, 6, accuracy: 0.0001, "pointer \(pointer), after icon \(index)")
            }
        }
    }

    func testTheRowsRoomCoversEveryPointer() {
        let count = 5
        let width = CGFloat(count) * 40 - 6
        let room = magnifier.overflow(count: count)
        XCTAssertGreaterThan(room, 0)
        for pointer in stride(from: CGFloat(0), through: width, by: 0.5) {
            let scales = magnifier.scales(count: count, pointer: pointer)
            let offsets = magnifier.offsets(scales: scales)
            let first = magnifier.center(of: 0) + offsets[0] - 34 * scales[0] / 2
            let last = magnifier.center(of: count - 1) + offsets[count - 1] + 34 * scales[count - 1] / 2
            XCTAssertGreaterThanOrEqual(first, -room - 0.5, "pointer \(pointer)")
            XCTAssertLessThanOrEqual(last, width + room + 0.5, "pointer \(pointer)")
        }
    }

    func testEffectsDecodeAndDefault() throws {
        let theme = try JSONDecoder().decode(ThemeConfig.self, from: Data(#"{ "hoverEffect": "magnify", "launchAnimation": "shake", "indicatorStyle": "line", "indicatorColor": "group" }"#.utf8))
        XCTAssertEqual(theme.hoverEffect, .magnify)
        XCTAssertEqual(theme.launchAnimation, .shake)
        XCTAssertEqual(theme.indicatorStyle, .line)
        XCTAssertEqual(theme.indicatorColor, .group)
        let defaults = ThemeConfig()
        XCTAssertEqual([defaults.hoverEffect.rawValue, defaults.launchAnimation.rawValue, defaults.indicatorStyle.rawValue, defaults.indicatorColor.rawValue], ["scale", "bounce", "dot", "accent"])
    }
}
