#!/bin/bash
# Build ClaudeTOC and package as macOS .app bundle
set -e

cd "$(dirname "$0")"

echo "Building..."
swift build

APP_NAME="ClaudeTOC"
APP_DIR="$HOME/Applications/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
BINARY=".build/arm64-apple-macosx/debug/${APP_NAME}"

echo "Packaging ${APP_DIR}..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# Copy binary
cp "$BINARY" "$MACOS_DIR/${APP_NAME}"

# Copy Info.plist
cp Info.plist "$CONTENTS_DIR/Info.plist"

# Generate app icon from SF Symbol (simple approach: use a placeholder)
# If you have an .icns file, copy it to Resources/AppIcon.icns
if [ -f "AppIcon.icns" ]; then
    cp AppIcon.icns "$RESOURCES_DIR/AppIcon.icns"
fi

# Sign the app
codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || true

echo "Done: ${APP_DIR}"
echo ""
echo "To launch:  open ${APP_DIR}"
echo "Hook binary: ${MACOS_DIR}/${APP_NAME}"
