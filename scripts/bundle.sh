#!/bin/bash
set -euo pipefail

# Builds HotkeyLauncher.app (unsigned) in the repo root.
# VERSION can be overridden: VERSION=1.2.0 ./scripts/bundle.sh

APP_NAME="HotkeyLauncher"
BUNDLE_ID="com.priomsrb.HotkeyLauncher"
EXECUTABLE_NAME="HotkeyLauncher"
VERSION="${VERSION:-1.0.0}"
# Monotonic build number for CFBundleVersion (notarization requires one)
BUILD_NUMBER="$(git -C "$(dirname "$0")/.." rev-list --count HEAD 2>/dev/null || echo 1)"

cd "$(dirname "$0")/.."

echo "🔨 Building ${APP_NAME} ${VERSION} (${BUILD_NUMBER}) in release mode..."
swift build -c release

APP_BUNDLE="${APP_NAME}.app"
echo "📦 Creating ${APP_BUNDLE}..."

rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp ".build/release/${EXECUTABLE_NAME}" "${APP_BUNDLE}/Contents/MacOS/${EXECUTABLE_NAME}"
cp "assets/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"

cat <<EOF > "${APP_BUNDLE}/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${EXECUTABLE_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>© $(date +%Y) Shafqat Bhuiyan</string>
</dict>
</plist>
EOF

echo "✅ Successfully created ${APP_BUNDLE}"
