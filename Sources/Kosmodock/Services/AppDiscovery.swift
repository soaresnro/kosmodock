import Foundation

struct InstalledApp: Hashable, Sendable {
    let name: String
    let path: String
    let bundleID: String?

    var dockApp: DockApp { DockApp(name: name, bundleId: bundleID, path: path) }
}

/// Scans the usual application folders and builds a ready-to-use first-launch
/// configuration out of whatever developer and system apps are installed.
enum AppDiscovery {
    static var searchDirectories: [String] {
        let home = NSHomeDirectory()
        return [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities",
            "\(home)/Applications",
            "\(home)/Applications/JetBrains Toolbox",
        ]
    }

    static func scanInstalledApps() -> [InstalledApp] {
        let fileManager = FileManager.default
        var seen = Set<String>()
        var apps: [InstalledApp] = []

        func add(path: String) {
            let bundleID = Bundle(path: path)?.bundleIdentifier
            guard seen.insert(bundleID ?? path).inserted else { return }
            let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            apps.append(InstalledApp(name: name, path: path, bundleID: bundleID))
        }

        for directory in searchDirectories {
            guard let items = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }
            for item in items.sorted() where item.hasSuffix(".app") {
                add(path: (directory as NSString).appendingPathComponent(item))
            }
        }
        let finder = "/System/Library/CoreServices/Finder.app"
        if fileManager.fileExists(atPath: finder) { add(path: finder) }
        return apps
    }

    // MARK: Blueprints

    private struct Blueprint {
        var name: String
        var symbol: String
        var tint: String
        var widget: WidgetConfig
        var layout: TilingLayout
        var maxApps: Int
        /// Bundle identifiers (contain a dot) or app names, in priority order.
        var candidates: [String]
        var keepWhenEmpty = false
    }

    private static func blueprints(hasContainerRuntime: Bool) -> [Blueprint] {
        [
            Blueprint(
                name: "Code", symbol: "chevron.left.forwardslash.chevron.right", tint: "#7C6CFF",
                widget: WidgetConfig(type: .cpuRam), layout: .dev70_30Stack, maxApps: 5,
                candidates: [
                    "com.jetbrains.rider", "com.todesktop.230313mzl4w4u92", "com.microsoft.VSCode",
                    "com.jetbrains.intellij", "com.jetbrains.intellij.ce", "com.jetbrains.WebStorm",
                    "com.jetbrains.pycharm", "com.jetbrains.pycharm.ce", "com.jetbrains.goland",
                    "dev.zed.Zed", "com.apple.dt.Xcode", "com.sublimetext.4",
                    "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
                    "net.kovidgoyal.kitty", "com.github.wez.wezterm", "com.apple.Terminal",
                ]
            ),
            Blueprint(
                name: "Containers", symbol: "shippingbox.fill", tint: "#3FA9F5",
                widget: WidgetConfig(type: .podman), layout: .splitHorizontal50_50, maxApps: 3,
                candidates: ["io.podmandesktop.PodmanDesktop", "io.podman_desktop.PodmanDesktop", "Podman Desktop",
                             "com.docker.docker", "dev.kdrag0n.MacVirt"],
                keepWhenEmpty: hasContainerRuntime
            ),
            Blueprint(
                name: "Data & APIs", symbol: "cylinder.split.1x2.fill", tint: "#2EC27E",
                widget: WidgetConfig(type: .portProbe, ports: [5432, 6379, 5000, 8080]),
                layout: .splitHorizontal50_50, maxApps: 5,
                candidates: [
                    "org.jkiss.dbeaver.core.product", "com.jetbrains.datagrip", "com.tinyapp.TablePlus",
                    "Apidog", "com.postmanlabs.mac", "com.insomnia.app", "com.usebruno.app",
                    "com.mongodb.compass", "Redis Insight", "pgAdmin 4",
                ]
            ),
            Blueprint(
                name: "Web", symbol: "globe", tint: "#FF8A3D",
                widget: WidgetConfig(type: .cpuRam), layout: .splitHorizontal50_50, maxApps: 4,
                candidates: [
                    "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser",
                    "company.thebrowser.dia", "org.mozilla.firefox", "com.brave.Browser",
                    "com.microsoft.edgemac", "app.zen-browser.zen",
                ]
            ),
            Blueprint(
                name: "AI", symbol: "sparkles", tint: "#E86FD3",
                widget: WidgetConfig(type: .cpuRam), layout: .grid2x2, maxApps: 4,
                candidates: ["com.anthropic.claudefordesktop", "ChatGPT", "com.openai.chat", "com.google.GeminiMacOS",
                             "Gemini", "ai.elementlabs.lmstudio", "LM Studio", "com.electron.ollama"]
            ),
            Blueprint(
                name: "Comms", symbol: "bubble.left.and.bubble.right.fill", tint: "#F5C211",
                widget: WidgetConfig(), layout: .grid2x2, maxApps: 5,
                candidates: [
                    "com.tinyspeck.slackmacgap", "com.microsoft.teams2", "com.microsoft.Outlook",
                    "net.whatsapp.WhatsApp", "com.hnc.Discord", "us.zoom.xos", "ru.keepcoder.Telegram",
                    "com.apple.mail", "com.apple.MobileSMS",
                ]
            ),
            Blueprint(
                name: "System", symbol: "gearshape.2.fill", tint: "#8E8E93",
                widget: WidgetConfig(
                    type: .customCommand,
                    command: "pmset -g batt | grep -Eo '[0-9]+%' | head -1 | sed 's/^/🔋 /' | grep . || echo 'AC power'",
                    label: "Battery",
                    interval: 30
                ),
                layout: .maximizeAll, maxApps: 4,
                candidates: ["com.apple.finder", "com.apple.systempreferences", "com.apple.ActivityMonitor", "com.apple.Notes"],
                keepWhenEmpty: true
            ),
        ]
    }

    static func makeDefaultConfig(installed: [InstalledApp] = scanInstalledApps(), hasContainerRuntime: Bool? = nil) -> DockConfig {
        let runtimeAvailable = hasContainerRuntime
            ?? (ContainerRuntime.resolve(kind: .podman, overridePath: nil, allowFallback: true) != nil)
        var used = Set<String>()
        var groups: [DockGroup] = []

        for blueprint in blueprints(hasContainerRuntime: runtimeAvailable) {
            var apps: [DockApp] = []
            for candidate in blueprint.candidates where apps.count < blueprint.maxApps {
                let match = installed.first { app in
                    guard !used.contains(app.path) else { return false }
                    if candidate.contains(".") && !candidate.contains(" ") {
                        return app.bundleID == candidate
                    }
                    return app.name.caseInsensitiveCompare(candidate) == .orderedSame
                }
                if let match {
                    used.insert(match.path)
                    apps.append(match.dockApp)
                }
            }
            guard !apps.isEmpty || blueprint.keepWhenEmpty else { continue }
            groups.append(DockGroup(
                id: DockConfig.slug(blueprint.name),
                name: blueprint.name,
                symbol: blueprint.symbol,
                tintHex: blueprint.tint,
                apps: apps,
                widget: blueprint.widget,
                layout: blueprint.layout
            ))
        }

        var config = DockConfig()
        config.groups = groups
        return config
    }
}
