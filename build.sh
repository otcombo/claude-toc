#!/bin/bash
# Build ClaudeTOC and package as macOS .app bundle
set -e

cd "$(dirname "$0")"

echo "Building..."
swift build

BINARY_NAME="ClaudeTOC"
DISPLAY_NAME="TOC for Claude Code"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="${SCRIPT_DIR}/build/${DISPLAY_NAME}.app"
BINARY=".build/arm64-apple-macosx/debug/${BINARY_NAME}"

echo "Packaging ${APP_DIR}..."
rm -rf "$APP_DIR"

# Build into /tmp first to avoid inheriting com.apple.provenance xattr
# (which blocks codesign with developer certificates)
STAGING=$(mktemp -d)
STAGE_APP="${STAGING}/${DISPLAY_NAME}.app"
mkdir -p "${STAGE_APP}/Contents/MacOS" "${STAGE_APP}/Contents/Resources"
cat "$BINARY" > "${STAGE_APP}/Contents/MacOS/${BINARY_NAME}"
chmod +x "${STAGE_APP}/Contents/MacOS/${BINARY_NAME}"
cat Info.plist > "${STAGE_APP}/Contents/Info.plist"
# Compile .icon to Assets.car for macOS 26 Liquid Glass icon
ICON_FILE="Sources/ClaudeTOC/appicon.icon"
if [ -d "$ICON_FILE" ]; then
    ACTOOL_OUT=$(mktemp -d)
    xcrun actool "$ICON_FILE" --compile "${STAGE_APP}/Contents/Resources" \
        --output-format human-readable-text \
        --output-partial-info-plist "${ACTOOL_OUT}/assetcatalog_generated_info.plist" \
        --app-icon appicon --include-all-app-icons \
        --enable-on-demand-resources NO \
        --target-device mac \
        --minimum-deployment-target 13.0 \
        --platform macosx 2>&1 || true
    rm -rf "$ACTOOL_OUT"
    echo "Compiled .icon → Assets.car"
fi
# Copy pre-built .icns for notification icon support
if [ -f "AppIcon.icns" ]; then
    cp "AppIcon.icns" "${STAGE_APP}/Contents/Resources/appicon.icns"
fi

# Sign the app with developer certificate (stable identity preserves TCC permissions across rebuilds)
SIGN_HASH=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | grep -v REVOKED | head -1 | awk '{print $2}')
if [ -n "$SIGN_HASH" ]; then
    codesign --force --deep --sign "$SIGN_HASH" "$STAGE_APP" 2>&1
    echo "Signed with: $SIGN_HASH"
else
    codesign --force --deep --sign - "$STAGE_APP" 2>/dev/null || true
    echo "⚠  Signed ad-hoc (no developer certificate found)."
fi

# Move to final location
mkdir -p "$(dirname "$APP_DIR")"
mv "$STAGE_APP" "$APP_DIR"
rm -rf "$STAGING"

# Force Launch Services to re-index the app icon (fixes notification icon for LSUIElement apps)
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
    "$LSREGISTER" -f "$APP_DIR"
    echo "Registered with Launch Services"
fi

echo "Done: ${APP_DIR}"

# Create DMG
DMG_DIR="${SCRIPT_DIR}/build"
DMG_PATH="${DMG_DIR}/${DISPLAY_NAME}.dmg"
rm -f "$DMG_PATH"

# Create a temporary folder with app + Applications symlink for drag-install
DMG_STAGING=$(mktemp -d)
cp -R "$APP_DIR" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

hdiutil create -volname "$DISPLAY_NAME" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_PATH" 2>&1
rm -rf "$DMG_STAGING"

# Create ZIP for auto-updater
ZIP_PATH="${DMG_DIR}/TOC.for.Claude.Code.app.zip"
rm -f "$ZIP_PATH"
cd "$DMG_DIR"
ditto -c -k --keepParent "${DISPLAY_NAME}.app" "$ZIP_PATH"
cd "$SCRIPT_DIR"

echo ""
echo "App: ${APP_DIR}"
echo "DMG: ${DMG_PATH}"
echo "ZIP: ${ZIP_PATH}"
