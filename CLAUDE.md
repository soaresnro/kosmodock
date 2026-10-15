# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Communication

Always reply to the user in **Brazilian Portuguese (pt-BR)**: explanations, reasoning, changed files and test instructions. Code, identifiers, comments and docs stay in English, matching the existing code.

## What this is

Kosmodock is a macOS 14+ Dock replacement (Swift Package, AppKit + SwiftUI, Apple Silicon). Apps are grouped into capsules that show live telemetry (CPU/RAM, Podman/Docker, ports, shell commands). It also tiles windows through the Accessibility API, keeps windows above the dock, animates minimized windows into their group, and can hide the native Dock. It was developed as "OrbitDock": `LegacyMigration` copies `~/.config/orbitdock` on first launch.

## Commands

```sh
swift build                                   # works with Command Line Tools or Xcode
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test   # CLT has no XCTest
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter KosmodockTests.TilingEngineTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter KosmodockTests.ScreenSpaceTests/testLowWindowThatFitsMovesUp
bash scripts/setup-signing.sh                 # once per machine: "Kosmodock Local Signing" identity
bash scripts/bundle.sh                        # release build → Kosmodock.app (icon, translations, signing)
python3 scripts/check_localizations.py        # run after touching any UI text
swift scripts/generate_icon.swift Assets/AppIcon.icns preview.png   # bundle.sh does this when the script changes
```

Run the bundled app with `open Kosmodock.app`. To pick up a rebuild, quit it first: `osascript -e 'tell application id "dev.kosmodock.Kosmodock" to quit'`. Only one instance runs per bundle id. Quitting restores the native Dock when suppression is on, so the Dock restarts on every relaunch.

Diagnostics: `log show --last 5m --info --predicate 'subsystem == "dev.kosmodock.Kosmodock"'` logs Accessibility trust, observer hub start and every window the enforcer moves.

UI can't be screenshotted from the terminal (no Screen Recording). Debug builds render PNGs instead: `.build/debug/Kosmodock --render-snapshots <dir> [--language pt-BR|es-ES|en-US]`. `ImageRenderer` draws the `NSVisualEffectView` blur as a yellow placeholder. Translations only load inside an `.app` (from `Bundle.main`), so for localized snapshots copy the debug binary and `Localization/*.lproj` into a throwaway `.app` with a *different* bundle id; the same id would trip the single-instance guard.

Git workflow:
- `main` is protected by the "Protect main" ruleset: pull request required, no direct push, no force push or deletion, nobody bypasses it. Work on a branch and open a PR with `gh pr create`.
- The global credential helper is Git Credential Manager, so push with gh credentials per command: `git -c credential.helper= -c 'credential.helper=!gh auth git-credential' push -u origin <branch>`.
- This repo's git `user.email` is set locally to the GitHub noreply address; keep it so personal email addresses stay out of the public history.
- Licensed Apache-2.0 (`LICENSE`, `NOTICE`).
- `.github/workflows/release.yml` tests and packages every PR; pushing a `v*` tag publishes a GitHub Release. Signing, first match wins:
  - Developer ID plus notarization, when the `MACOS_DEVELOPER_ID_*`/`MACOS_NOTARY_*` secrets exist. `bundle.sh` adds `--options runtime --timestamp` for Developer ID identities.
  - The self-signed "Kosmodock Release Signing" certificate (`MACOS_SELF_SIGNED_P12*`, created by `scripts/create-release-certificate.sh`). It keeps the Accessibility grant across updates.
  - Otherwise ad-hoc.
- `.github/release-signing-certificate.sha1` pins the release certificate, and the workflow fails when a build's designated requirement doesn't match it. Never replace the certificate casually: every user would have to grant Accessibility again. Rotation is `create-release-certificate.sh --rotate` plus a commit of the new pin.
- `install.sh` (repo root, run as `curl … | bash` from `main`) must stay bash 3.2 compatible, which is macOS's `/bin/bash`, and keep all logic inside `main`.
  - It checks the release's `SHA256SUMS.txt` and the pin at that release's tag, so it refuses 1.0.0, which has no pin.
  - It resets the Accessibility grant only when the installed app's signature differs. Test it with `KOSMODOCK_INSTALL_DIR=<scratch dir> KOSMODOCK_NO_OPEN=1` and a fake `tccutil` first in `PATH`, because `tccutil reset` acts on the bundle id, so it would clear your real grant.
  - A move to Developer ID needs its signature check updated.
- `scripts/generate_social_preview.swift` renders `Assets/social-preview.png`, which is uploaded by hand in Settings → Social preview.

## Toolchain gotchas

- **Never use `@State`.** In the macOS 27 SDK it is a SwiftUI macro whose plugin ships only with Xcode, so `swift build` under the Command Line Tools fails. Use `@ViewState` (`Views/Theme.swift`), a wrapper around the `State` struct.
- Swift language mode 5 (`Package.swift`). UI and service classes are explicitly `@MainActor`. Callbacks from `NotificationCenter`, `DispatchSource`, `Timer`, `NSEvent` monitors, `onPreferenceChange` and the AX C callback wrap their bodies in `MainActor.assumeIsolated { … }`.
- **Accessibility trust is tied to the code signature.** Ad-hoc signing (`codesign -s -`) produces a new identity every build, and the System Settings switch then silently refers to the old build. `bundle.sh` uses the stable local identity when present. If trust looks stuck, check the `tccd` log ("Failed to match existing code requirement") and run `tccutil reset Accessibility dev.kosmodock.Kosmodock`.
- Self-signed certificates aren't trusted, so `security find-identity -v` reports 0 valid identities. `codesign` signs with them anyway, by name or SHA-1, and the grant only checks `certificate leaf = H"<SHA-1>"`. Also, `security find-certificate -a` exits 0 even when nothing matches; test for output instead.

## Architecture

**Composition.** `AppDelegate` runs `LegacyMigration`, installs the native-Dock failsafes, bootstraps `ConfigService`, then builds `AppModel`, `DockController`, `SettingsWindowController` and `StatusItemController`. `AppModel` (`@Observable`) owns every service and is the facade views use. The window layer injects behavior into it through closures (`presentPopover`, `safeWorkAreaProvider`, `openSettingsHandler`, `popUpMainMenu`) instead of the model knowing about windows.

**Config.** `~/.config/kosmodock/config.json` is the single source of truth.
- Every model has a lenient `init(from:)` in an extension: missing keys fall back to defaults, wrong types or unknown enum values throw. **A new field needs a line in that extension**, or old configs stop decoding.
- In-app edits go through `ConfigService.update` (debounced save) or `AppModel.binding(\.keyPath)` / `groupBinding(id:)`. Bindings look groups up by id, never by array index.
- `FileWatcher` hot-reloads external edits and survives atomic saves. Self-writes are ignored by comparing bytes.
- Services react through `configService.addObserver`.

**Windowing.**
- `FloatingPanel` is a borderless `.nonactivatingPanel`. `isFloatingPanel` resets `level`, so it is set first; `constrainFrameRect` is overridden so Intellihide can slide the dock off-screen.
- Panels are sized from measured SwiftUI content via preference keys (`MeasuredSizeKey`, `CapsuleFramesKey`): grow immediately, shrink only after the spring settles.
- `DockRootView` uses `ViewThatFits` with a fixed, screen-derived proposal (`model.dockMaxWidth`), stepping down `DockDensity` (regular → compact → minimal → scrolling). Capsules then equalize width through `CapsuleContentWidthKey`.
- matchedGeometry ids include the density, because every `ViewThatFits` candidate stays in the view graph.

**Coordinates.** AppKit rects are bottom-left origin; the Accessibility/Quartz API and `CGWindowList` are top-left origin of the primary display. `TilingEngine.accessibilityRect(fromCocoa:primaryScreenHeight:)` converts in both directions. `TilingEngine` is pure layout math in top-left space, which is why its tests read top-down.

**Accessibility pipeline.**
- `AXObserverHub` keeps one `AXObserver` per regular app, registered on the application element, and merges NSWorkspace events into `WindowEvent`s. Listeners are `BottomMarginEnforcer`, `MinimizedWindowTracker` and `IntellihideController`.
- All blocking AX calls run on `WindowManagerService`'s serial queue (`performAX`). `AXWindowOps` is the synchronous AX layer and must never run on the main thread.
- `SafeWorkArea` (built by `DockController.safeWorkArea()`) is the contract between the dock and everything that places windows. The reserved line is the dock's *resting* bar height + `theme.dockClearance`. It ignores accordion expansion on purpose, so expanding a group doesn't resize every window.
- `BottomMarginEnforcer`:
  - waits while any mouse button is down;
  - remembers windows that refuse a frame (`EnforcementMemory`) to avoid resize loops;
  - grows windows that sat exactly on the previous line when the line moves down (the last line is persisted in UserDefaults);
  - re-checks the frontmost app every 1.5 s, because some apps don't emit moved/resized notifications to app-level observers.

**Minimize into groups.** macOS has no API to redirect or cancel the WindowServer's minimize animation, and `kAXWindowMiniaturizedNotification` only arrives after the window is gone. `MinimizedWindowTracker` therefore detects minimizes *up front* and dedupes the late AX notification (3 s window). Sources:
- yellow button: global mouse down/up + `AXUIElementCopyElementAtPosition`;
- ⌘M;
- Kosmodock's own clicks.

`WindowMinimizeAnimator` draws the card with Core Animation on a click-through overlay panel. `GroupResolver` maps a bundle id to its group, falling back to the "system" group, then the last group.

**Telemetry.**
- `MetricsSampler` (an actor) samples Mach/libproc counters. Per-app usage covers the whole child-process tree. On Apple Silicon `ri_*_time` is in Mach ticks, so convert with timebase.
- Services assign `@Observable` properties only when values change, to avoid re-rendering every poll.
- `ShellRunner` captures output through temp files, not pipes: `podman machine start` spawns daemons that inherit stdout, and a pipe would never reach EOF. It also injects the Homebrew `PATH`.
- `ContainerModels` parses both Podman (JSON array) and Docker (NDJSON) `ps` output.

**Native Dock suppression (`SystemDockManager`).** "Suppressed" means a sentinel file, `~/.config/kosmodock/.restore-native-dock.sh`, exists. It holds the exact shell command that restores the user's original `autohide`, `autohide-delay`, `minimize-to-application` and `mineffect` values. Every exit path runs it and deletes it: willTerminate, `atexit`, SIGINT/TERM/HUP sources, and a detached watchdog shell for crashes and SIGKILL. Test failsafes by putting a harmless command in the sentinel; real suppression runs `killall Dock`.

**Localization.**
- Keys are the English text, in `Localization/{en,pt-BR,es}.lproj/Localizable.strings`, which `bundle.sh` copies into the app.
- SwiftUI string literals are resolved by SwiftUI from the `\.locale` environment, set at each hosting root together with `.id(model.language)` so a language switch rebuilds the tree.
- Everything else (enum titles, badges, AppKit menus, errors, any interpolated or ternary string) must use `L10n.tr("key", args…)` with explicit `%@`/`%lld`/`%d`. Format numbers with `L10n.locale`.
- Custom components (`BentoCard`, `IconButton`, `StatLine`, `SliderRow`) take already-localized `String`s.
- A new key must be added to all three files; `check_localizations.py` and `LocalizationTests` enforce key parity and matching format specifiers.
- Text Kosmodock writes into `config.json` itself (default labels, a default command's fallback output) is saved in English as an `L10n.configKey("…")` constant and shown through `L10n.configText(_:)`. That recognizes the text in any language, so an old "Bateria" still follows the interface language, and leaves anything the user typed as is.
- Badge texts that contain numbers come with a `reserve` of their widest variants (`WidgetBadge.usage`, `.fraction`, …), and `BadgeView` reserves that width. Otherwise one reading gaining a digit resizes every capsule, and with them the dock. New numeric badges must do the same; `BadgeWidthTests` measures it.
