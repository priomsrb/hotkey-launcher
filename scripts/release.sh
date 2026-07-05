#!/bin/bash
set -euo pipefail

# Builds a distributable, signed + notarized release of HotkeyLauncher.
#
#   VERSION=1.0.0 ./scripts/release.sh
#
# Output: dist/HotkeyLauncher-<version>.dmg and .zip
#
# Requirements (one-time setup):
#   1. Apple Developer Program membership.
#   2. A "Developer ID Application" certificate installed in your keychain
#      (Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates, or developer.apple.com).
#   3. Notarization credentials stored in the keychain:
#        xcrun notarytool store-credentials notary \
#          --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
#
# Environment overrides:
#   CODESIGN_IDENTITY  signing identity (default: auto-detect Developer ID Application)
#   NOTARY_PROFILE     notarytool keychain profile name (default: notary)
#   SKIP_NOTARIZE=1    sign but skip notarization (not distributable to strangers)
#
# Without a Developer ID certificate the script falls back to ad-hoc signing and
# skips notarization — fine for personal use, but recipients will have to
# right-click ▸ Open to bypass Gatekeeper.

cd "$(dirname "$0")/.."

APP_NAME="HotkeyLauncher"
APP_BUNDLE="${APP_NAME}.app"
VERSION="${VERSION:-1.0.0}"
NOTARY_PROFILE="${NOTARY_PROFILE:-notary}"
DIST_DIR="dist"

# --- Build the bundle ---------------------------------------------------------
VERSION="${VERSION}" ./scripts/bundle.sh

# --- Sign ---------------------------------------------------------------------
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)}"

ADHOC=0
if [ -z "${IDENTITY}" ]; then
    ADHOC=1
    echo "⚠️  No Developer ID Application certificate found — ad-hoc signing."
    echo "    The app will NOT pass Gatekeeper on other Macs."
    codesign --force --sign - "${APP_BUNDLE}"
else
    echo "🔏 Signing with: ${IDENTITY}"
    codesign --force --options runtime --timestamp --sign "${IDENTITY}" "${APP_BUNDLE}"
fi
codesign --verify --strict --verbose=2 "${APP_BUNDLE}"

# --- Notarize + staple --------------------------------------------------------
mkdir -p "${DIST_DIR}"
ZIP_PATH="${DIST_DIR}/${APP_NAME}-${VERSION}.zip"

if [ "${ADHOC}" = "0" ] && [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
    echo "📤 Submitting to Apple notary service (this can take a few minutes)..."
    ditto -c -k --keepParent "${APP_BUNDLE}" "${ZIP_PATH}"
    xcrun notarytool submit "${ZIP_PATH}" --keychain-profile "${NOTARY_PROFILE}" --wait
    echo "📎 Stapling notarization ticket..."
    xcrun stapler staple "${APP_BUNDLE}"
    # Re-zip so the archive contains the stapled app
    rm -f "${ZIP_PATH}"
else
    echo "⏭  Skipping notarization."
fi

ditto -c -k --keepParent "${APP_BUNDLE}" "${ZIP_PATH}"

# --- DMG ----------------------------------------------------------------------
DMG_PATH="${DIST_DIR}/${APP_NAME}-${VERSION}.dmg"
STAGING="$(mktemp -d)"
cp -R "${APP_BUNDLE}" "${STAGING}/"
ln -s /Applications "${STAGING}/Applications"
rm -f "${DMG_PATH}"
hdiutil create -volname "${APP_NAME}" -srcfolder "${STAGING}" -ov -format UDZO -quiet "${DMG_PATH}"
rm -rf "${STAGING}"

if [ "${ADHOC}" = "0" ]; then
    codesign --force --timestamp --sign "${IDENTITY}" "${DMG_PATH}"
fi

echo ""
echo "✅ Release artifacts:"
ls -lh "${DIST_DIR}/${APP_NAME}-${VERSION}".{zip,dmg}
if [ "${ADHOC}" = "1" ]; then
    echo ""
    echo "⚠️  Reminder: this build is ad-hoc signed. Set up a Developer ID"
    echo "    certificate and rerun for a Gatekeeper-approved release."
fi
