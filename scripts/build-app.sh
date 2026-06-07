#!/bin/bash
#
# Build Tokenomics.app — a double-clickable macOS menu bar app bundle.
#
# Compiles a release binary via SPM, then assembles a standard .app bundle
# with an Info.plist (LSUIElement => menu bar agent, no Dock icon) and an
# ad-hoc code signature so macOS treats it as a stable app identity.
#
# Usage:  ./scripts/build-app.sh
# Output: dist/Tokenomics.app

set -euo pipefail

APP_NAME="Tokenomics"
BUNDLE_ID="me.stfang.tokenomics"
VERSION="0.1.0"
MIN_MACOS="14.0"

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

RELEASE_BIN=".build/release/${APP_NAME}"
APP_DIR="dist/${APP_NAME}.app"
CONTENTS="${APP_DIR}/Contents"
ICON_SRC="Resources/${APP_NAME}.icns"

echo "▸ Compiling release binary…"
swift build -c release

echo "▸ Assembling ${APP_DIR}…"
rm -rf "${APP_DIR}"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources"
cp "${RELEASE_BIN}" "${CONTENTS}/MacOS/${APP_NAME}"

if [[ -f "${ICON_SRC}" ]]; then
    cp "${ICON_SRC}" "${CONTENTS}/Resources/${APP_NAME}.icns"
else
    echo "  (no ${ICON_SRC}; app will use the default icon)"
fi

cat > "${CONTENTS}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>     <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>      <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>      <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>        <string>${APP_NAME}</string>
    <key>CFBundleIconName</key>        <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleVersion</key>         <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>  <string>${MIN_MACOS}</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

echo "▸ Ad-hoc code signing…"
codesign --force --sign - "${APP_DIR}" >/dev/null 2>&1 || echo "  (codesign skipped)"

echo "✓ Built ${APP_DIR}"
echo "  Run:   open \"${APP_DIR}\""
echo "  Or move it to /Applications and double-click."
