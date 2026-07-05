# HotkeyLauncher

A macOS menu bar app that registers global keyboard shortcuts to launch/switch
applications and cycle through their windows. Requires macOS 12+ and
Accessibility permission (prompted on first launch).

## Build

```bash
swift build
```

## Run

```bash
.build/debug/HotkeyLauncher
```

## Bundle (local .app)

```bash
./scripts/bundle.sh    # creates HotkeyLauncher.app (unsigned)
```

## Release (distributable)

```bash
VERSION=1.0.0 ./scripts/release.sh
```

Produces `dist/HotkeyLauncher-<version>.dmg` and `.zip`, code-signed with
hardened runtime, notarized by Apple, and stapled — ready to attach to a
GitHub Release.

One-time setup before the first real release:

1. Enroll in the [Apple Developer Program](https://developer.apple.com/programs/).
2. Install a **Developer ID Application** certificate
   (Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + ▸ Developer ID Application).
3. Store notarization credentials in the keychain
   (create an app-specific password at [account.apple.com](https://account.apple.com)):

   ```bash
   xcrun notarytool store-credentials notary \
     --apple-id you@example.com --team-id YOURTEAMID --password <app-specific-password>
   ```

Without a certificate the script falls back to an ad-hoc-signed build:
usable locally, but other people will have to right-click ▸ Open to get past
Gatekeeper.

## App icon

`assets/AppIcon.icns` is generated — to tweak and regenerate:

```bash
swift scripts/make-icon.swift
```
