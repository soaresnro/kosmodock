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

UI can't be screenshotted from the terminal (no Screen Recording). Debug builds render PNGs instead: `.build/debug/Kosmodock --render-snapshots <dir> [--language pt-BR|es-ES|en-US]`. Always run the debug binary with `CFFIXED_USER_HOME=<scratch home>`: its exit failsafes would otherwise run the real native-Dock sentinel. `cfprefsd` ignores `CFFIXED_USER_HOME`, so UserDefaults writes still reach the real domain; snapshots keep them off (`FolderSeenStore(defaults: nil)`, `persistsSeenDates = false`, `UtilityWidgets.isPreview`). `ImageRenderer` draws the `NSVisualEffectView` blur, `NSViewRepresentable` overlays (`.appMenu`, drag sources), `.onDrop`, `Menu`, `ScrollView`, `TextEditor` and pickers as yellow or 🚫 placeholders. Translations only load inside an `.app` (from `Bundle.main`), so for localized snapshots copy the debug binary and `Localization/*.lproj` into a throwaway `.app` with a *different* bundle id; the same id would trip the single-instance guard.

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
- Backups: `ConfigBackupStore` (`Services/ConfigBackups.swift`) is pure file logic with an injectable directory; `ConfigService` uses `backups/` next to its `fileURL`, at launch and in `AppModel.stop()`. `backUp()` flushes a pending save first; `restore(_:)` decodes first, then backs up, then `saveNow()`, so the watcher ignores the write.
- Services react through `configService.addObserver`.

**Windowing.**
- `FloatingPanel` is a borderless `.nonactivatingPanel`. `isFloatingPanel` resets `level`, so it is set first; `constrainFrameRect` is overridden so Intellihide can slide the dock off-screen.
- Panels are sized from measured SwiftUI content via preference keys (`MeasuredSizeKey`, `CapsuleFramesKey`): grow immediately, shrink only after the spring settles.
- `DockRootView` uses `ViewThatFits` with a fixed, screen-derived proposal (`model.dockMaxWidth`), stepping down `DockDensity` (regular → compact → minimal → scrolling). The `CapsuleRow` layout gives collapsed capsules the widest one's width, capped so the row still fits the screen.
  - It's a `Layout` on purpose: `ViewThatFits` also measures candidates it doesn't show, and a width kept in `@State` and fed back through a preference goes stale in those, which left the dock stuck at a sparser density.
- matchedGeometry ids include the density, because every `ViewThatFits` candidate stays in the view graph.

**Styles.** A `DockStyle` preset fills `ThemeConfig.surface`, a `DockSurface` holding blur, fill, border, glow, sheen and corners. Editing the surface makes the style "customized"; restoring copies the preset back.
- `SurfaceBackground` draws a surface. A colored fill forces a readable `colorScheme` on the bar and its vibrancy.
- Popovers stay on glass (`ThemeConfig.popoverSurface`). The floating style has no bar, so each capsule draws its own glass (`FloatingGlass`).
- Configs without a `style` key predate styles: their `cornerRadius`, `glassOpacity`, `borderOpacity` and `material` migrate into the glass surface.
- `DockSurface` writes unset fill colors as `null`, because a missing key falls back to the style's colors.
- `--render-snapshots` also writes `dock-style-<id>.png` for every style.
- Seasonal styles add `DockSurface.decorations` (in `SeasonalDecoration` order, normalized) to the preset, so toggling one customizes the style. `SeasonalDecorationLayer` draws them all in one `TimelineView` + `Canvas` as functions of time, above the surface and below the content, reaching `SeasonalPainter.reach` (inset − 2) past the bar. It pauses on `AppModel.isDockHidden` and stands still with Reduce Motion. `SeasonalPainter.order` must list every decoration.
- Icon packs (`Services/IconPacks.swift`): `IconLibrary` sets `WorkspaceService.iconResolver`, and `icon(for:)` reads `iconRevision`, so `iconsDidChange()` redraws every icon. Precedence is custom (`ThemeConfig.appIcons`, `""` = the app's own) → pack (`ThemeConfig.iconPack`) → app. Name keys are lowercase letters and digits, bundle id first; `pack.json` mappings win over file names and must stay inside the pack. Restore Default Theme keeps icon choices.
- `ThemeConfig.customizations` keeps the edited surfaces of the styles that aren't selected, by style name: `apply(_:)` stores the current one and loads the next; `restore()` drops only the current style's. `DockSurface.fillAngle` rotates the fill clockwise from top-to-bottom. `DockSurface.reflection` (on for Graphite and Floating) draws a mirrored copy under icons as a background outside their frame, so layout never changes; only dock call sites pass `AppIconView(reflects: true)`.

**Effects.** `ThemeConfig` holds `hoverEffect`, `launchAnimation`, `indicatorStyle` and `indicatorColor`.
- Magnification (`Magnifier`, `MagnifyingRow`) only scales and offsets, so it never changes layout. With `spreads`, a row moves neighbors apart and keeps permanent padding for it.
- Only the expanded accordion row spreads. Collapsed capsules' mini icons grow in place, because a wider capsule would widen every capsule (`CapsuleRow`).
- `WorkspaceService.launching` holds apps launched from the dock until `isFinishedLaunching`, shown for at least 0.7 s and at most 10 s. `AppIconView` animates them with `LaunchMotion` and draws `RunningIndicator` outside it, so the mark stays put.

**Workspaces** (`Models/Workspaces.swift`, `App/AppModel+Workspaces.swift`).
- `DockConfig.workspaces` lists item ids per bar and `activeWorkspaceID` picks one (an unknown id means the first). With no workspaces the bar is unchanged.
- `barOrder` shows only the active workspace's items; `activeOrder` is what `settleOrder` and the moves read and write. Add through `addToBar` (new items join the active workspace only), delete through `removeFromBar` (every workspace). `allItemIDs` is the single-bar order; `sidebarGroupIDs` lists groups in bar order, then hidden ones.
- `WorkspaceSwitch.plan` is pure, over bundle ids. The new workspace's `otherApps` (keep/hide/quit, never forced, never the Finder or Kosmodock) applies to running apps of the old workspace's groups and pinned apps that the new one lacks. `WorkspaceSwitcher.hiddenApps` (in memory) unhides them when a workspace that has them returns. `groupID(forBundleID:)` prefers items on the bar, and a switch runs `regroup()`.
- Triggers, only with 2 or more workspaces: ⌃⌥1…9 via Carbon `RegisterEventHotKey` (`HotKeyCenter`, no permission); `WorkspaceDots` at the bar's leading edge (a non-equalized `CapsuleRow` item); `WorkspaceSwipeMonitor`, a local `.scrollWheel` monitor on the dock panel (horizontal swipe or ⌘ + scroll, one step per gesture; on the scrolling bar only ⌘ + scroll); the status menu.
- The default names "Main" and "New Workspace" are config texts. Binding workspaces to Spaces (private CGS APIs) or Focus modes (App Intents, which `swift build` can't produce) is not done.

**Bar order.** The bar holds group capsules, pinned apps (`DockConfig.pinnedApps`, plain icons via `PinnedAppView`) and tiles in one order.
- Item ids: a group's id, `app:<DockApp.id>` and `tile:<id>` (`DockConfig.itemID(forPinned:)`, `itemID(for:)`). Group ids are slugs, so they never contain a colon.
- `DockConfig.order` lists item ids. `barOrder` applies it, drops unknown and repeated ids, and appends whatever it leaves out (pinned apps, groups, tiles), so an empty `order` keeps older configs as they were.
- Adding an item calls `settleOrder()` first, so the new item lands at the end. `moveGroups` (the sidebar) reorders groups among their own places only.
- `AppModel.barItems` resolves the order for the views; Settings › Dock edits it.
- Folders (`DockConfig.folders`, `folder:<id>`) and spacers (`DockConfig.spacers`, `spacer:<id>`, small/large/flexible) are `BarItem.extra(BarExtra)` (`Models/DockItems.swift`), appended after tiles by default. The Trash (`showsTrash`, id `kosmodock:trash`) is never in `order` or workspaces: `barItems` appends it last.
  - `FolderStackService` reads with `FolderListing.read` off the main thread, watches a folder (`FileWatcher`) only after a read succeeds and retries unreadable ones every 30 s. Downloads skips `.download`/`.crdownload`/`.part` and counts new items against `FolderSeenStore` (UserDefaults `Kosmodock.folderSeen.<id>`).
  - `TrashService` reads `~/.Trash`, which looks empty without Full Disk Access (then polled, not watched). Empty Trash sends the Finder `fndr`/`empt`; -1743 means Automation was denied.
  - A flexible spacer (`FlexibleWidthKey`) takes only the width `CapsuleRow` has left after equalization.
- **Bar edits go through `AppModel.editBar`**, not `configService.update`, or they can't be undone. `DockBarUndo` keeps one level and restores only the parts the edit changed (`Part`), and only while they still equal the post-edit state. `DockUndoCommand` takes over the main menu's ⌘Z (text undo first); the dock panel is non-activating, so ⌘Z reaches it only while Settings is key or the Kosmodock menu is open.
- `GroupResolver` sends minimized windows to the app's group, then its pinned icon, then the general group.

**Tiles.** `DockConfig.tiles` are widgets on the bar (`TileViews.swift`, `AppWidgetViews.swift`). Each is `square` or `wide`, and its width never depends on the reading.
- Tiles and pinned apps go by their item id wherever group ids are used: the popover (`popoverItemID`), `CapsuleFramesKey` and the minimize animation.
- `DockRootView` tries each density with wide tiles, then with square tiles, before the next density. Regular density first tries one mini icon less per capsule (`fewerMiniIcons`), so a tile the user chose wide stays wide a step longer. `GroupCapsuleView.variant` keeps matched-geometry ids unique across those candidates.
- Widget stacks (`Models/WidgetStacks.swift`): the first tile leads, its `tile:<id>` is the stack's bar item and `DockTile.stack` lists the rest, which `barOrder` leaves out (`barTiles`). `tileStacks` reads leniently. A new lead takes the old one's place in `order`, every workspace and `tiles`; Take Out inserts right after the stack. Stack tiles take the lead's width (`matchStackWidths`); the tile on show is in memory (`WidgetStackSelection`). `WidgetStackScrollMonitor` turns stacks, and `WorkspaceSwipeMonitor.yields` gives it the scroll except ⌘ + scroll.
- New tiles come from `AppModel.newTile(_:)`. Tile clicks go through `AppModel.activate` (Shortcut runs, AirDrop opens Finder's AirDrop, the color picker samples via `tap`); menus use `showDetails`.
- Time widgets (`Models/TimeWidgets.swift`, `Services/TimeWidgetServices.swift`): options are optional `DockTile` fields (`timeZone`, `face`, `timer`, `pomodoro`, `countdown`, `period`). Running clocks are dates (`RunClock`) in `time-widgets.json` next to `config.json`, written only on actions and stage ends, and dropped only when the tile leaves or changes kind, never before the first non-empty tile list. The scheduler wakes at the next end, at most every 10 s; ends found more than 60 s late don't alert. `TimeNotifier` uses `UNUserNotificationCenter` only inside an `.app` with a bundle id (`current()` throws otherwise) and asks on the first end; tests inject `alert:`.
- File widgets (`Models/FileWidgets.swift`, `Services/FileWidgetServices.swift`): `FileWidgetService` runs `FolderFeed`s only for Screenshots and Recent Files tiles. `ScreenshotDetector` takes images with screencapture's `kMDItemIsScreenCapture` xattr or a localized name prefix, re-reading `com.apple.screencapture location`. `FileDragSource` (AppKit) drags files out as copies only; `fileWidgetDropTarget` takes `.fileURL` drops; `FileDrop.loadURLs` resolves Finder's file reference URLs. Shortcut tiles run `/usr/bin/shortcuts run <name>` as arguments, never through a shell.
- Utility widgets (`Services/UtilityWidgetServices.swift`, `ClipboardHistory.swift`, `WeatherService.swift`): options are optional per-kind groups on `DockTile` (`note`, `water`, `emoji`, `colors`, `clipboard`, `weather`). Data that changes often goes through `WidgetStateStore` to `widget-state/<tile id>.json` (0600, debounced 0.6 s, saved in `stop()`).
  - Clipboard: polls `changeCount` every 0.5 s, prefers files > text > image, skips the nspasteboard.org concealed/transient/auto-generated markers and its own writes. The history is purged only on a runtime change from having a clipboard tile to none, so a config that fails to decode never deletes it.
  - Weather fetches Open-Meteo in Celsius through an ephemeral `URLSession` and converts locally: every 20 min, 3 min after an error.
  - `UnitConversion` uses `ConverterUnit.exact` factors where Foundation rounds. `EmojiCatalog` keeps what AppleColorEmoji draws as one glyph (CoreText check) plus region flags.
- `TileKind.pet` (`Models/Looks.swift`, `Views/PetTile.swift`): `PetKeeper` ticks every 1 s only while a pet tile exists. `PetActivity.next` uses thresholds plus 0.03 hysteresis, `PetMemory` sleeps after 120 s and eats for 6 s. Roaming pets are an overlay on `DockBar`; `PetPeekController` shows a click-through 30 pt strip while Intellihide hides the dock.
- `CapsuleRow` proposes the row's height to every item, so tiles (`maxHeight: .infinity`) match the capsules' height in each density.
- `TelemetryService` reads `battery` (IOKit power sources) and `network` only while such a tile exists.
  - Network uses `sysctl` `NET_RT_IFLIST2` 64-bit counters over Ethernet-type interfaces, minus VM ones.
  - macOS rounds those counters to 1 KiB, so low traffic reads as 0 or about 340 B/s.
  - Command tiles run under the key `tile:<id>`, and a new one's label is the config text `L10n.uptime`.
- Tiles are VoiceOver buttons (`accessibilityAction`), which also lets AX scripts open their popovers.
- App widgets (`AppWidgetServices.swift`) run only while their tile is on the bar (`AppModel.updateAppWidgetServices`):
  - `ClaudeUsageService` reads transcripts incrementally and counts each `message.id` once (one response spans several lines with the same `usage`). The plan limits come only from Claude Code's status line JSON, which the `ClaudeStatusLine` script saves whole to `claude-status.json` (only when `rate_limits` is in it); *Set Up* edits `~/.claude/settings.json` only on click and never replaces another status line. The script parses no JSON: `plutil` can't read JSON from stdin before macOS 26 (the CI runner's macOS 15 fails) and `jq` isn't installed by default, so its own line uses `sed`, and `printf` never formats numbers, because the shell's number parsing follows the locale (pt-BR rejects `23.5`).
  - `NowPlayingService` asks Music/Spotify through `osascript` only while the app is running (`tell application` would launch it). Error -1743 means Automation was denied.
  - `CalendarService` checks `Bundle.main.infoDictionary` for the usage key before asking: asking without it crashes the app, and `object(forInfoDictionaryKey:)` would also find the key in `InfoPlist.strings`.
  - `GitHubService` runs `gh search prs` every two minutes; exit 4 means signed out, 127 not installed.
  - `CodexUsageService`/`CodexSessionReader` (`AppWidgetServices+More.swift`) read `~/.codex/sessions` incrementally. Each `event_msg`/`token_count` line has the turn's `last_token_usage` and the session's `total_token_usage`; Codex repeats the event without new usage, so a line whose total equals the previous one counts nothing, and turns are keyed by time and counts so copied sessions count once. `rate_limits.primary`/`secondary` are classified by `window_minutes` (a plan may have only the weekly window, as `primary`).
  - `RemindersService` has the same raw-Info.plist guard as Calendar (`NSRemindersFullAccessUsageDescription`); `fetchReminders` calls back on EventKit's queue, so items are copied there.
  - `NowPlayingService` fetches Music's artwork once per track: osascript prints `«data PNGf…»`, a 4-character type code plus hex, parsed off the main thread and thumbnailed with ImageIO.
- `bundle.sh` writes the Automation, Calendars and Reminders usage descriptions into Info.plist; `Localization/*.lproj/InfoPlist.strings` translates them.
- A command that prints a JSON object draws its widget (`CommandOutput`: text, detail, symbol, color, progress, status, url).

**Coordinates.** AppKit rects are bottom-left origin; the Accessibility/Quartz API and `CGWindowList` are top-left origin of the primary display. `TilingEngine.accessibilityRect(fromCocoa:primaryScreenHeight:)` converts in both directions. `TilingEngine` is pure layout math in top-left space, which is why its tests read top-down.

**Accessibility pipeline.**
- `AXObserverHub` keeps one `AXObserver` per regular app, registered on the application element, and merges NSWorkspace events into `WindowEvent`s. Listeners are `BottomMarginEnforcer`, `MinimizedWindowTracker` and `IntellihideController`.
- All blocking AX calls run on `WindowManagerService`'s serial queue (`performAX`). `AXWindowOps` is the synchronous AX layer and must never run on the main thread.
- `SafeWorkArea` (built by `DockController.safeWorkArea()`) is the contract between the dock and everything that places windows. The reserved line is the dock's *resting* bar height + `theme.dockClearance`. It ignores accordion expansion on purpose, so expanding a group doesn't resize every window.
- `DockBadgeService` polls the native Dock's AX tree every 2 s through `performAX` (Dock → `AXList` → `AXDockItem`). `AXStatusLabel`/`AXURL` count only on `AXApplicationDockItem`: on the Handoff item `AXStatusLabel` is a device id. It re-resolves the Dock's pid after `killall Dock` and tolerates 3 failed polls. `AppIconView(badgeStyle:)` takes `.full`/`.dot`/`.hidden`; lists and Settings pass `.hidden`. Notification badges sit top-trailing, the minimized counter bottom-trailing.
- The app's own Dock menu (`DockMenuService`) can only be read by opening it: `DockMenuAX` performs `AXShowMenu` on the native Dock item, reads `AXShownMenuUIElement`, then `AXCancel` (about 100 ms). A chosen item is pressed by reopening the menu and checking the title at the same index. `DockMenuFilter` drops the Dock's closing block and its Options submenu. SwiftUI's `.contextMenu` can't wait for that, so `.appMenu(_:group:)` puts an AppKit view over the icon that takes right and Control clicks only and pops up an NSMenu.
- `BottomMarginEnforcer`:
  - waits while any mouse button is down;
  - remembers windows that refuse a frame (`EnforcementMemory`) to avoid resize loops;
  - leaves a window the user dragged more than `edgeCatchDistance` past the line behind the dock, like the native Dock. It counts only moves with the size unchanged, of a window seen before, within 2 s of a mouse drag (`CGEventSource.secondsSinceLastEventType`). Resizes and macOS tiles, which change the size, still stop at the line;
  - grows windows that sat exactly on the previous line when the line moves down (the last line is persisted in UserDefaults);
  - re-checks the frontmost app every 1.5 s, because some apps don't emit moved/resized notifications to app-level observers.

- Window previews (`Windowing/WindowPreviews.swift`): `.windowPreviews(for:)` reports hover to `AppModel.windowPreviewHover`. AX windows (via `performAX`) are matched to `SCWindow` by pid and frame (`WindowMatching`, 6 pt). Thumbnails only with `CGPreflightScreenCaptureAccess` (never prompts), never of Kosmodock's own windows, cached 3 s (window list 1.5 s). The panel sits at statusBar+2, sized by `WindowPreviewMetrics`, above the icon.
- Keyboard focus (`Windowing/DockKeyboardFocus.swift`): ⌃⌥D on its own `HotKeyCenter`; each center needs its own signature, or equal ids collide. The dock panel's `allowsKey` turns on for the moment, and ending orders it out and back to hand the keys back. Spacers are skipped. Intellihide stays pinned while focus or preview cards are up.
- Drop Zone (`Windowing/DropZone.swift`): a global `leftMouseDown/Dragged/Up` monitor; a drag counts when the drag pasteboard's `changeCount` moved since mouse-down and its types include `.fileURL`. Contents are read only on drop, into `DockConfig.dropShelfTileID`.

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
