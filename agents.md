# HotkeyLauncher - Agent Guide

## Overview

A macOS menu bar app that registers global keyboard shortcuts to launch/switch applications and cycle windows.

## Project Structure

```
Sources/HotkeyLauncher/
├── main.swift              # Entry point, runs as .accessory (no dock icon)
├── AppDelegate.swift       # Menu bar setup, orchestrates components
├── HotkeyManager.swift     # CGEvent tap for global keyboard interception
├── ApplicationManager.swift # NSWorkspace + Accessibility API for app/window control
├── ConfigManager.swift     # JSON config loading from ~/Library/Application Support/
└── Hotkey.swift            # Data model with key code mapping
```

## Build & Run

```bash
swift build
.build/debug/HotkeyLauncher
```

## Key Technical Details

### Permissions

- **Accessibility permission required** - handled via `AXIsProcessTrustedWithOptions()`
- Without it, CGEvent tap cannot intercept global keyboard events

### CGEvent Tap (HotkeyManager)

- Uses `.cgSessionEventTap` to intercept before other apps
- Returns `nil` to consume matched hotkeys, `Unmanaged.passRetained(event)` to pass through
- Must handle `.tapDisabledByTimeout` to re-enable if system disables it

### Window Cycling (ApplicationManager)

- Uses `AXUIElementCreateApplication(pid)` to get app's accessibility element
- Gets windows via `kAXWindowsAttribute`, focused window via `kAXFocusedWindowAttribute`
- Cycles by calling `kAXRaiseAction` on next window

### Config

- Location: `~/Library/Application Support/HotkeyLauncher/config.json`
- Format: `{ "hotkeys": [{ "key": "t", "modifiers": ["cmd"], "bundleId": "com.apple.Terminal" }] }`
- Reload without restart via menu bar

## Common Issues

- **Hotkeys not working**: Check Accessibility permissions, check logs for event tap status
- **App not found**: Verify bundle ID (use: `osascript -e 'id of app "AppName"'`)
