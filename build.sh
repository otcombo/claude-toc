#!/bin/bash
# Build ClaudeTOC and package as macOS .app bundle
# Usage: ./build.sh              (sign only, fast)
#        ./build.sh --notarize   (sign + Apple notarization, slow)
set -e

cd "$(dirname "$0")"

NOTARIZE=false
[ "$1" = "--notarize" ] && NOTARIZE=true

BINARY_NAME="ClaudeTOC"
DISPLAY_NAME="TOC for Claude Code"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="${SCRIPT_DIR}/build/${DISPLAY_NAME}.app"
NOTARY_PROFILE="claude-toc"

echo "Building (release)..."
swift build -c release

BIN_PATH=$(swift build -c release --show-bin-path)
BINARY="${BIN_PATH}/${BINARY_NAME}"

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
# Copy .icns for app icon
if [ -f "AppIcon.icns" ]; then
    cp "AppIcon.icns" "${STAGE_APP}/Contents/Resources/appicon.icns"
fi
# Copy app icon PNG for onboarding
if [ -f "Sources/ClaudeTOC/appicon64@3x.png" ]; then
    cp "Sources/ClaudeTOC/appicon64@3x.png" "${STAGE_APP}/Contents/Resources/appicon64@3x.png"
fi
# Copy hook script
cp hook.sh "${STAGE_APP}/Contents/Resources/hook.sh"
chmod +x "${STAGE_APP}/Contents/Resources/hook.sh"

# Sign in staging dir (/tmp) to avoid com.apple.provenance xattr that build/ inherits
SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | grep -v REVOKED | head -1 | sed 's/.*"\(.*\)".*/\1/')
if [ -n "$SIGN_IDENTITY" ]; then
    codesign --force --options runtime --sign "$SIGN_IDENTITY" "${STAGE_APP}/Contents/MacOS/${BINARY_NAME}" 2>&1
    codesign --force --options runtime --sign "$SIGN_IDENTITY" "$STAGE_APP" 2>&1
    echo "Signed with: $SIGN_IDENTITY"
else
    codesign --force --deep --sign - "$STAGE_APP" 2>/dev/null || true
    echo "Signed ad-hoc (no Developer ID certificate found)."
    if $NOTARIZE; then
        echo "ERROR: Cannot notarize without Developer ID. Skipping notarization."
        NOTARIZE=false
    fi
fi

# Verify signature in staging (clean of xattr)
echo "Verifying signature..."
codesign --verify --deep --strict "$STAGE_APP" 2>&1

# Move to final location
mkdir -p "$(dirname "$APP_DIR")"
mv "$STAGE_APP" "$APP_DIR"
rm -rf "$STAGING"

# Notarize app (optional, slow — submits to Apple and waits)
if $NOTARIZE; then
    echo "Notarizing app..."
    NOTARIZE_ZIP=$(mktemp -d)/app.zip
    ditto -c -k --keepParent "$APP_DIR" "$NOTARIZE_ZIP"
    xcrun notarytool submit "$NOTARIZE_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1
    rm -f "$NOTARIZE_ZIP"

    echo "Stapling ticket to app..."
    xcrun stapler staple "$APP_DIR" 2>&1
fi

# Force Launch Services to re-index the app icon (fixes notification icon for LSUIElement apps)
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
    "$LSREGISTER" -f "$APP_DIR"
    echo "Registered with Launch Services"
fi

echo "Done: ${APP_DIR}"

# Create DMG with styled installer window
DMG_DIR="${SCRIPT_DIR}/build"
DMG_PATH="${DMG_DIR}/${DISPLAY_NAME}.dmg"
DMG_RW="${DMG_DIR}/${DISPLAY_NAME}_rw.dmg"
DEVICE=""
rm -f "$DMG_PATH" "$DMG_RW"

cleanup_dmg() {
    [ -n "$DEVICE" ] && hdiutil detach "$DEVICE" -force 2>/dev/null
    rm -rf "$DMG_STAGING" "$DMG_RW" 2>/dev/null
}
trap cleanup_dmg EXIT

# Prepare staging folder with app + Applications symlink
DMG_STAGING=$(mktemp -d)
cp -R "$APP_DIR" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

# Step 1: Create read-write DMG
echo "Creating DMG..."
hdiutil create -volname "$DISPLAY_NAME" -srcfolder "$DMG_STAGING" -ov -format UDRW "$DMG_RW" 2>&1
rm -rf "$DMG_STAGING"

# Step 2: Mount read-write DMG and capture actual mount point
ATTACH_OUTPUT=$(hdiutil attach -readwrite -noverify -noautoopen "$DMG_RW")
# The mount point line contains /Volumes/; extract device and path from it
MOUNT_LINE=$(echo "$ATTACH_OUTPUT" | grep "/Volumes/")
DEVICE=$(echo "$MOUNT_LINE" | awk '{print $1}')
DMG_VOLUME=$(echo "$MOUNT_LINE" | sed 's/.*\(\/Volumes\/.*\)/\1/' | sed 's/[[:space:]]*$//')
if [ -z "$DEVICE" ] || [ -z "$DMG_VOLUME" ]; then
    echo "ERROR: Failed to mount DMG"
    exit 1
fi
# Actual volume name as Finder sees it (may be "Name 1" if "Name" was already mounted)
VOLUME_NAME=$(basename "$DMG_VOLUME")

# Wait for Finder to recognize the volume
for i in $(seq 1 10); do
    [ -d "$DMG_VOLUME" ] && break
    sleep 0.5
done

# Step 3: Apply Finder window layout via AppleScript (uses actual volume name, not assumed)
echo "Styling DMG window..."
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "${VOLUME_NAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {100, 100, 700, 500}
        set opts to icon view options of container window
        set icon size of opts to 128
        set arrangement of opts to not arranged
        set position of item "${DISPLAY_NAME}.app" of container window to {160, 180}
        set position of item "Applications" of container window to {440, 180}
        close
    end tell
end tell
APPLESCRIPT

# Step 4: Wait for .DS_Store to flush, then detach
sync
sleep 2
hdiutil detach "$DEVICE" 2>/dev/null || hdiutil detach "$DEVICE" -force
DEVICE=""

# Step 5: Convert to compressed read-only DMG
hdiutil convert "$DMG_RW" -format UDZO -o "$DMG_PATH" 2>&1
rm -f "$DMG_RW"

# Sign and notarize DMG (optional)
if [ -n "$SIGN_IDENTITY" ]; then
    echo "Signing DMG..."
    codesign --force --sign "$SIGN_IDENTITY" "$DMG_PATH" 2>&1
fi
if $NOTARIZE && [ -n "$SIGN_IDENTITY" ]; then
    echo "Notarizing DMG..."
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1

    echo "Stapling ticket to DMG..."
    xcrun stapler staple "$DMG_PATH" 2>&1
fi

# Create ZIP for auto-updater (from the already-signed/notarized app)
# Strip xattr and resource forks so the ZIP doesn't break signature verification
ZIP_PATH="${DMG_DIR}/TOC.for.Claude.Code.app.zip"
rm -f "$ZIP_PATH"
ZIP_STAGING=$(mktemp -d)
rsync -a --exclude '._*' "$APP_DIR" "$ZIP_STAGING/"
xattr -cr "$ZIP_STAGING/${DISPLAY_NAME}.app"
cd "$ZIP_STAGING"
COPYFILE_DISABLE=1 ditto -c -k --norsrc --keepParent "${DISPLAY_NAME}.app" "$ZIP_PATH"
cd "$SCRIPT_DIR"
rm -rf "$ZIP_STAGING"

echo ""
echo "App: ${APP_DIR}"
echo "DMG: ${DMG_PATH}"
echo "ZIP: ${ZIP_PATH}"
