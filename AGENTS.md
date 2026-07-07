# HotkeyLauncher — Agent Guide

A macOS menu bar app (Swift Package, AppKit + SwiftUI) that registers global keyboard
shortcuts to launch/switch applications and cycle through their windows. Single
executable target, no dependencies, macOS 12+.

## Build, run, bundle

```bash
swift build                      # debug build
.build/debug/HotkeyLauncher      # run (menu bar only, no dock icon)
./scripts/bundle.sh              # release build + HotkeyLauncher.app bundle (unsigned)
./scripts/release.sh             # bundle + codesign + notarize + dist/ dmg & zip
swift scripts/make-icon.swift    # regenerate assets/AppIcon.icns
```

`release.sh` needs a Developer ID Application certificate and a `notary`
notarytool keychain profile (see README); without them it ad-hoc signs and
skips notarization.

There are no automated tests. Verification is manual: it requires real hotkey presses,
multiple app windows/spaces, and Accessibility permission. To safely experiment with
window/AX APIs without touching the app, compile a scratch file with `swiftc` and run
it from the terminal — terminal-spawned binaries inherit the terminal's Accessibility
trust, so AX calls work.

## Source map

```
Sources/HotkeyLauncher/
├── main.swift              # Single-instance guard (2nd launch tells 1st to show
│                           # settings via DistributedNotificationCenter), .accessory policy
├── AppDelegate.swift       # Menu bar item, settings window, wires components together
├── HotkeyManager.swift     # CGEvent tap for global keyboard interception
├── ApplicationManager.swift # App activation + window discovery/cycling (the tricky part)
├── LaunchHUD.swift         # Floating "Launching <App>…" bezel shown during cold launches
├── CycleIndicatorHUD.swift # Window-cycling indicator (list of window titles, shown while
│                           # the hotkey's modifiers are held) + ModifierWatcher
├── ConfigManager.swift     # JSON config load/save
├── Hotkey.swift            # Hotkey model + key code mapping
├── SettingsView.swift      # SwiftUI settings UI (running apps + hotkeys in one list)
└── ShortcutRecorder.swift  # Inline hotkey-recording control
```

## Hotkey flow (HotkeyManager)

- `.cgSessionEventTap` intercepts keyDown before other apps. Return `nil` to consume a
  matched hotkey, `Unmanaged.passRetained(event)` to pass through.
- Must handle `.tapDisabledByTimeout` / `.tapDisabledByUserInput` by re-enabling the tap.
- `isRecording` suppresses matching while the user records a shortcut in settings.
- `exceptions` (bundle IDs) disable all hotkeys while that app is frontmost.

## Window switching design (ApplicationManager)

Behavior contract for a hotkey press:
1. App not running → launch it.
2. Running but not focused → raise its most recently focused window.
3. Focused, or pressed again within 1s of the last press → cycle to the next window.

Cycling uses a `CycleSession` that freezes the window list, so rapid presses visit every
window exactly once per loop even while the OS z-order shifts underneath. Holding the
hotkey's modifier keys keeps the session alive past the 1s timeout and shows the
CycleIndicatorHUD (window-title list, focused row highlighted); releasing the modifiers
hides the HUD and ends the session (detected by `ModifierWatcher`: global flagsChanged
monitor + 100ms `CGEventSource.flagsState` polling fallback).

Window discovery merges three sources (`getWindowsForApp`), because none is complete alone:
1. **Ground truth**: `windowServerWindowIDs(pid:)` asks the window server, via private
   SkyLight APIs (`CGSCopyManagedDisplaySpaces` + `CGSCopyWindowsWithOptionsAndTags`),
   for every window ID the app owns on *every* space, including fullscreen ones.
   Filtered to layer 0, alpha > 0.1, ≥100×100 px so tooltips/ghost windows don't count.
2. **Standard AX list** (`kAXWindows`): reliable, but misses other spaces and fullscreen.
3. **Targeted brute force**: any expected ID the AX list missed is hunted by iterating
   `_AXUIElementCreateWithRemoteToken` element IDs (up to 30k IDs / 500ms) and matching
   by `CGWindowID`, stopping as soon as all missing windows are found.

Results are deduped by `CGWindowID` and sorted focused-first, then by z-order.

Hard-won gotchas — do not rediscover these:
- `CGWindowListCreateDescriptionFromArray` silently returns nothing if the CFArray holds
  NSNumbers; the IDs must be stored as **raw values** (`UnsafeRawPointer(bitPattern:)`).
- Chromium apps burn through AX element IDs (web content allocates them), so their
  windows can sit at high element IDs — that's why the brute-force scan is targeted-by-ID
  and deep, instead of subrole-checking every element. A blind subrole scan capped at
  2000 IDs is what caused Chrome windows to be intermittently unswitchable.
- `raiseWindow` order matters: un-minimize → set `kAXMain` → `kAXRaise` → activate the
  app. Activation after setting main is what makes macOS switch spaces. A dead AX
  element (window closed) fails attribute queries — `raiseWindow` returns false and the
  cycle skips it.
- All private API declarations (`@_silgen_name`) are undocumented; if you change their
  signatures or options, verify against a scratch binary first (wrong ABI = crash,
  wrong option flags = silently empty results).

## Config

- Path: `~/Library/Application Support/HotkeyLauncher/config.json`
- Shape: `{ "hotkeys": [{ "key": "t", "modifiers": ["cmd"], "bundleId": "..." }], "exceptions": ["bundle.id"] }`
- Find a bundle ID: `osascript -e 'id of app "AppName"'`

## Repo conventions and traps

- Accessibility permission is granted per-binary; a rebuilt or moved binary may need
  the permission re-granted in System Settings.
- Logging is `print` with a `[Component]` prefix (e.g. `[AppManager]`, `[HotkeyManager]`).
  Timing logs already exist for total switch time, window discovery, and brute-force
  scans — check them first when investigating slowness.
- `TODO.md` is the task list; move finished items to its Done section with a short
  note on how they were solved.

## Debugging switching issues

1. Run the debug binary from a terminal and watch the logs while pressing hotkeys.
2. `[AppManager] Warning: N window(s) exist but weren't reachable via AX` means the
   window server sees a window that AX discovery couldn't reach — discovery problem.
3. No warning but wrong window raised — ordering or session problem (`CycleSession`,
   z-order sort).
4. Correct window, nothing visible — raising/activation problem (`raiseWindow`).
