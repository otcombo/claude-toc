#!/bin/bash
# Build ClaudeTOC and package as macOS .app bundle
set -e

cd "$(dirname "$0")"

echo "Building..."
swift build

APP_NAME="ClaudeTOC"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="${SCRIPT_DIR}/build/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
BINARY=".build/arm64-apple-macosx/debug/${APP_NAME}"

echo "Packaging ${APP_DIR}..."
rm -rf "$APP_DIR"

# Build into /tmp first to avoid inheriting com.apple.provenance xattr
# (which blocks codesign with developer certificates)
STAGING=$(mktemp -d)
STAGE_APP="${STAGING}/${APP_NAME}.app"
mkdir -p "${STAGE_APP}/Contents/MacOS" "${STAGE_APP}/Contents/Resources"
cat "$BINARY" > "${STAGE_APP}/Contents/MacOS/${APP_NAME}"
chmod +x "${STAGE_APP}/Contents/MacOS/${APP_NAME}"
cat Info.plist > "${STAGE_APP}/Contents/Info.plist"
if [ -f "AppIcon.icns" ]; then
    cat AppIcon.icns > "${STAGE_APP}/Contents/Resources/AppIcon.icns"
fi

# Sign the app with developer certificate (stable identity preserves TCC permissions across rebuilds)
SIGN_HASH=$(security find-identity -v -p codesigning 2>/dev/null | grep "otcombo.dev" | grep -v REVOKED | head -1 | awk '{print $2}')
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

echo "Done: ${APP_DIR}"

# Create DMG
DMG_DIR="${SCRIPT_DIR}/build"
DMG_PATH="${DMG_DIR}/${APP_NAME}.dmg"
rm -f "$DMG_PATH"

# Create a temporary folder with app + Applications symlink for drag-install
DMG_STAGING=$(mktemp -d)
cp -R "$APP_DIR" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_PATH" 2>&1
rm -rf "$DMG_STAGING"

echo ""
echo "App: ${APP_DIR}"
echo "DMG: ${DMG_PATH}"
