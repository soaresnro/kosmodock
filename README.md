# Kosmodock

[![License: Apache 2.0](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
![Platform: macOS 14+](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey.svg)
![Swift 6](https://img.shields.io/badge/Swift-6-orange.svg)

![Kosmodock: a macOS Dock replacement with live widget groups](Assets/social-preview.png)

<!-- Demo: drop a 30–60 s screen recording (or GIF) here: capsules with live telemetry, the Bento popover, Launch & Tile, a window minimizing into its group, switching languages. -->

A macOS Dock replacement built around **app groups that are live widgets**. Each capsule on the dock shows a group's apps plus live telemetry: CPU/RAM, Podman containers, listening ports, or the output of your own shell command. Clicking a capsule expands it (Bento popover or inline accordion), and one click launches the whole group and tiles its windows.

Requires macOS 14+ on Apple Silicon. Built with Swift 6.4, SwiftUI, AppKit, Mach/libproc and the Accessibility API. Free and open source under the Apache 2.0 license.

## Installation

### Download

Grab `Kosmodock-<version>.dmg` (or `.zip`) from [Releases](https://github.com/soaresnro/kosmodock/releases) and drag **Kosmodock** to `/Applications`.

Builds signed with an Apple Developer ID and notarized open normally. A build that isn't notarized yet is stopped by Gatekeeper the first time you open it. Allow it once in **System Settings → Privacy & Security → Open Anyway**, or run `xattr -dr com.apple.quarantine /Applications/Kosmodock.app`. Every release lists its signing status and a `SHA256SUMS.txt`.

On first launch, grant **Accessibility** when macOS asks (see [Permissions](#permissions)).

### Build from source

See [Build & run](#build--run) below. It takes a minute with Xcode or the Command Line Tools installed.

## Privacy

- **Nothing leaves your Mac.** Kosmodock makes no internet requests: no analytics, no update checks, no telemetry. The only sockets it opens are connections to `127.0.0.1` to check whether ports you configured are listening.
- **What it reads:** CPU, memory and process usage through Mach/libproc; listening ports through `lsof`; Podman/Docker status through their CLIs (`podman machine list`, `podman ps`); and the output of shell commands **you** put in `config.json`.
- **Accessibility** is used only to move, resize, minimize, restore and raise windows, and to be notified when windows move or minimize. It reads window frames and titles (the titles are shown in *Minimized Windows*), never window contents.
- **Global input:** to animate minimizes and close popovers, Kosmodock observes mouse clicks system-wide and checks key presses for exactly two keys, ⌘M and Escape. Nothing is logged or stored.
- **The native Dock:** *Hide the native macOS Dock* changes four `com.apple.dock` preferences and restores your original values whenever Kosmodock quits or crashes (see [Native Dock suppression & recovery](#native-dock-suppression--recovery)). To restore them by hand: `defaults delete com.apple.dock autohide-delay; defaults write com.apple.dock autohide -bool false; killall Dock`.
- Your settings live in `~/.config/kosmodock/config.json`.

## Uninstall

1. Quit Kosmodock from its menu (this restores the native Dock).
2. Delete `Kosmodock.app` and `~/.config/kosmodock`.
3. Remove Kosmodock from **System Settings → Privacy & Security → Accessibility**, and from **Login Items** if you enabled launch at login.
4. If you built it yourself: `bash scripts/setup-signing.sh --remove` deletes the local signing identity.

## Build & run

```sh
bash scripts/setup-signing.sh   # once: stable local signing identity (see Permissions)
swift build                     # debug build (works with Command Line Tools or Xcode)
bash scripts/bundle.sh          # release build → Kosmodock.app, signed
open Kosmodock.app
```

`bundle.sh` writes an `Info.plist` with `LSUIElement` (no Dock icon), `NSAccessibilityUsageDescription` and `CFBundleIconFile`, then signs the bundle with `codesign --force --deep`. The app icon is drawn by `scripts/generate_icon.swift` (CoreGraphics; every size from 16 to 1024 px is rendered as vectors, with simplified artwork at 32 px and below) and packed with `iconutil` into `Assets/AppIcon.icns`. It is regenerated whenever the script changes; to render it by hand, run `swift scripts/generate_icon.swift Assets/AppIcon.icns preview.png`. Options:

| Variable | Default | Purpose |
| --- | --- | --- |
| `CONFIGURATION` | `release` | `debug` for a debug bundle |
| `SIGN_IDENTITY` | `Kosmodock Local Signing` if it exists, else `-` (ad-hoc) | Signing identity passed to `codesign` |
| `BUNDLE_ID` / `VERSION` | `dev.kosmodock.Kosmodock` / `1.0.0` | Bundle metadata |

Run the tests with Xcode's toolchain (the Command Line Tools don't ship XCTest):

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

To get PNGs of the dock and every popover from live data (debug builds only):

```sh
swift build && .build/debug/Kosmodock --render-snapshots /tmp/kosmodock-snaps
```

### Permissions

Accessibility is the **only** permission Kosmodock needs (System Settings → Privacy & Security → Accessibility). Tiling, keeping windows above the dock, and minimize-into-group all depend on it. Kosmodock asks once at launch; the popover, Settings → Permissions and the menu also have a *Grant Access* button. Screen Recording and Input Monitoring are not used.

macOS ties the grant to the app's code signature. An ad-hoc signature (`codesign -s -`) changes on every build, so after a rebuild the switch in System Settings still looks on but belongs to the previous build. `scripts/setup-signing.sh` creates a self-signed **Kosmodock Local Signing** certificate in your login keychain, and `bundle.sh` uses it automatically. The identity then stays the same across builds, and so does the grant. `bash scripts/setup-signing.sh --remove` deletes it.

**Switch is on but Kosmodock still asks?** The entry belongs to an older build. Reset it and grant again:

```sh
tccutil reset Accessibility dev.kosmodock.Kosmodock
open Kosmodock.app   # asks again; switch the new entry on
```

To see what the window services are doing, read the diagnostics log:

```sh
log show --last 5m --info --predicate 'subsystem == "dev.kosmodock.Kosmodock"'
```

## Using it

- **Click a capsule** to open its Bento popover. It has a header with *Launch All* (▶) and *Launch & Tile*, tiling layout pills (`50/50 · 70/30 · 75/25 · Grid · Max`), a *Focus* toggle, the app grid with per-app RAM, and the telemetry section.
- **Right-click an app**: Focus, Hide, Tile Left/Right, Maximize, Quit, Force Quit, Show in Finder, Remove.
- **Right-click a capsule**: Launch & Tile, Launch All, Details, Layout ▸, Edit Group…
- **Accordion mode** (per group or global) expands the capsule inline, morphing mini icons into full launchers.
- **Launch & Tile** does three things. It launches any closed apps, unhides the group, and (with Focus Mode on) hides every other app. Then it waits for windows and applies the layout inside the screen's visible frame, above the dock.
- The **⊞ button** at the end of the dock, and the menu bar icon, open the Kosmodock menu: Settings, hide native Dock, Focus Mode, expansion mode, reload/open config, Quit.
- **Windows never sit behind the dock.** With *Reserve screen space* on (the default), an Accessibility observer watches every app. When a window reaches into the dock's band, it is moved up, or shrunk if it's taller than the work area. Tiling presets use the same work area. Turn the option off to get **Intellihide**: the dock slides below the screen edge while a window overlaps it, and comes back when the pointer touches the bottom edge.
- **Minimize into groups.** Minimizing a window plays a card animation from the window into its group's capsule, and the capsule bounces. The minimize can come from the yellow button, ⌘M, *Minimize to Group* in the menu, or clicking the frontmost app's icon. The capsule shows a counter, and the group's popover lists *Minimized Windows*; clicking one plays the reverse animation and restores it. Clicking an app whose windows are all minimized restores the most recent one.
- The dock **adapts to screen width**. It steps down from full labels to a compact layout (icons over badge), then status dots, and finally scrolls.

## Configuration

`~/.config/kosmodock/config.json` is generated on first launch by scanning `/Applications`, `/System/Applications` and `~/Applications` (including JetBrains Toolbox). The file is hot-reloaded on save. If an edit is invalid, the last good config stays active and the error shows in Settings → Config File. Every key is optional.

```jsonc
{
  "theme": {
    "cornerRadius": 22, "glassOpacity": 0.35, "borderOpacity": 0.6,
    "iconSize": 34, "dockMargin": 10, "tileGap": 8,
    "dockClearance": 5,                                // gap between windows and the top of the dock
    "springResponse": 0.32, "springDamping": 0.78,   // lower response = stiffer
    "accentHex": "#8B7CFF", "material": "hudWindow",   // hudWindow|popover|menu|sidebar|underWindowBackground|fullScreenUI
    "appearance": "system", "showGroupLabels": true
  },
  "behavior": {
    "expansionMode": "bento", "suppressNativeDock": false, "focusMode": false, "showMenuBarIcon": true,
    "reserveScreenSpace": true,          // false = Intellihide
    "minimizeToGroups": true, "clickActiveAppToMinimize": true,
    "screenSpaceExclusions": ["com.example.SomeGame"]   // never moved/resized by the enforcer
  },
  "telemetry": { "pollInterval": 3, "containerRuntime": "podman", "runtimePath": null, "fallbackToDocker": true, "commandTimeout": 10 },
  "groups": [
    {
      "id": "backend", "name": "Backend", "symbol": "server.rack", "tintHex": "#2EC27E",
      "layout": "dev70_30Stack",              // splitHorizontal50_50|dev70_30Stack|mainPlusBottom25|grid2x2|maximizeAll
      "expansionMode": "accordion",           // optional per-group override
      "apps": [
        { "name": "Rider", "path": "~/Applications/Rider.app" },
        { "name": "iTerm", "bundleId": "com.googlecode.iterm2" }
      ],
      "widget": {
        "type": "portProbe",                  // none|cpuRam|podman|portProbe|customCommand
        "ports": [5432, 6379, 8080],
        "probes": [
          { "name": "API", "command": "curl -fsS http://localhost:8080/health" },
          { "name": "Redis", "port": 6379 }
        ]
      }
    },
    {
      "name": "Deploys",
      "widget": { "type": "customCommand", "label": "CI", "interval": 30,
                  "command": "gh run list -L1 --json conclusion -q '.[0].conclusion'" }
    }
  ]
}
```

| Widget | Capsule badge | Popover |
| --- | --- | --- |
| `cpuRam` | `12% CPU • 3.8 GB` for the group's apps and their child processes (system totals when idle) | CPU ring, memory bar, pressure |
| `podman` | `🦭 3 UP • 12% CPU` (VM process CPU) or `🦭 VM Stopped` | Machine status with Start/Stop/Initialize, container list with Start/Stop/Restart |
| `portProbe` | 🟢 all listening / 🟡 some / 🔴 none, `:5432` or `2/4 ports` | Each port with its owning process (via `lsof`) |
| `customCommand` | First line of stdout. Exit `0` = 🟢, `1` = 🟡, anything else or a timeout = 🔴 | Output, last run, *Run now* |

`probes` work with any widget type. The worst result colours the capsule's status dot. Commands run through `/bin/sh` with `PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:…`, so Homebrew tools resolve from the GUI app. Podman is looked up at `/opt/homebrew/bin`, `/usr/local/bin` and `/opt/podman/bin`, falling back to Docker when enabled.

## Releasing

`.github/workflows/release.yml` runs on every pull request: it runs the tests and the translation check, bundles the app, and attaches `Kosmodock-<version>.dmg`/`.zip` to the workflow run. Pushing a tag publishes a release:

```sh
git tag v1.0.0 && git push origin v1.0.0
```

With the repository secrets `MACOS_DEVELOPER_ID_P12` (base64 `.p12` with a *Developer ID Application* certificate), `MACOS_DEVELOPER_ID_P12_PASSWORD`, `MACOS_NOTARY_APPLE_ID`, `MACOS_NOTARY_TEAM_ID` and `MACOS_NOTARY_PASSWORD` (an app-specific password), the app and disk image are signed with the hardened runtime, notarized and stapled. Without them the release is unsigned, and its notes explain how to open it.

## Languages

The interface is available in **English (US)**, **Português (Brasil)** and **Español (España)**. Pick one in Settings → Behavior → Language, or set `"behavior": { "language": "pt-BR" }` (`system`, `en-US`, `pt-BR`, `es-ES`). The switch applies immediately to the dock, the popovers, the menus and Settings, including number formatting (`3,8 GB`). `system` follows macOS and falls back to English.

Translations live in `Localization/<lang>.lproj/Localizable.strings`, with the English text as the key, and `bundle.sh` copies them into the app. SwiftUI literals (`Text("Launch & Tile")`) are translated from the `locale` environment value; text built in code goes through `L10n.tr("…", args…)`. After adding or changing UI text, run:

```sh
python3 scripts/check_localizations.py   # every key used in code exists in every language, with matching %@/%lld
```

## Native Dock suppression & recovery

*Hide the native macOS Dock* sets `autohide` with a 1000 s `autohide-delay`. It also sets `minimize-to-application = true` and the short `mineffect = scale`, so the native minimize animation is as brief as possible. Before that, it saves the command that restores **your original** values of all four keys to `~/.config/kosmodock/.restore-native-dock.sh`. That file is run and deleted by every exit path:

- quitting normally (`applicationWillTerminate`, `NSApplication.willTerminateNotification`, `atexit`)
- `SIGINT`, `SIGTERM` and `SIGHUP` (dispatch signal sources)
- a crash, force quit or `SIGKILL`: a detached watchdog shell notices Kosmodock's pid is gone within 2 s
- the next launch, if the file is still there and suppression is off

## Architecture

```
Sources/Kosmodock
├── App/        KosmodockApp (@main), AppDelegate, AppModel (composition root, badges, actions), SnapshotRenderer (DEBUG)
├── Models/     DockConfig (lenient Codable), TelemetryModels, ContainerModels (Podman/Docker JSON parsing)
├── Services/   ConfigService + FileWatcher (hot reload), AppDiscovery, WorkspaceService,
│               SystemMetrics (Mach/libproc sampler, lsof port scanner), TelemetryService,
│               ContainerMonitorService, TilingEngine (pure layout math), WindowManagerService (AX),
│               SystemDockManager, ShellRunner
├── Windowing/  FloatingPanel (non-activating NSPanel), DockController (sizing, anchoring, popovers),
│               SettingsWindowController (+ status item menu, main menu for ⌘C/⌘V)
└── Views/      DockRootView, GroupCapsuleView, BentoPopoverView, TelemetryWidgets, AppIconView, SettingsView, Theme
```

- UI types are `@MainActor`. The package uses Swift language mode 5 so AppKit, AX and Mach interop stays free of strict-concurrency noise.
- `@State` is a SwiftUI *macro* in the macOS 27 SDK, and its plugin ships only with Xcode. Views use `@ViewState`, a thin wrapper around the `State` property-wrapper struct, so `swift build` also works with the Command Line Tools.
- Panels are sized from measured SwiftUI content. They grow immediately and shrink only after the spring settles, so expand/collapse animations are never clipped.
- AX calls run on a private serial queue, so a hung target app can't stall the 120 Hz UI. Telemetry only publishes values that changed.

## Known limitations

- macOS has no public API to redirect or cancel the WindowServer's own minimize animation. Kosmodock detects minimizes up front so its animation starts together with the system's (yellow button, ⌘M, its own clicks). Other minimizes (e.g. double-clicking a title bar) are only reported after they finish, so the card animates from the window's last frame.
- An app that maximizes itself (green button, its own tiling) briefly covers the dock before the enforcer moves it back.

- Per-app memory follows each app's process tree. XPC services launched by `launchd` (e.g. Safari's WebContent processes) aren't attributed to their app.
- Port 5000 is the macOS AirPlay Receiver by default, so a `:5000` probe reports it as listening.
- The dock lives on the primary display.

## License

Kosmodock is licensed under the [Apache License 2.0](LICENSE). You may use, modify and distribute it, including commercially, as long as you keep the license and the notices in [NOTICE](NOTICE). The license grants no rights to the Kosmodock name or icon.
