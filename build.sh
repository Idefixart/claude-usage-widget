#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Claude Usage"
BUILD_DIR="$SCRIPT_DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "Building $APP_NAME..."

# Clean
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Compile
swiftc "$SCRIPT_DIR/main.swift" \
    -framework AppKit \
    -framework SwiftUI \
    -framework Combine \
    -target arm64-apple-macos14 \
    -O \
    -o "$BUILD_DIR/ClaudeUsage"

echo "Binary compiled."

# Create .app bundle
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
cp "$BUILD_DIR/ClaudeUsage" "$APP_BUNDLE/Contents/MacOS/ClaudeUsage"
cp "$SCRIPT_DIR/fetch_usage.py" "$APP_BUNDLE/Contents/MacOS/fetch_usage.py"

# App icon (regenerate from master PNG if present, else use existing .icns)
ICON_SRC="$SCRIPT_DIR/Claude Cusage App Icon Template.png"
if [ -f "$ICON_SRC" ]; then
    ISET="$BUILD_DIR/AppIcon.iconset"
    rm -rf "$ISET"
    mkdir -p "$ISET"
    SIZES=(16 16x16 32 16x16@2x 32 32x32 64 32x32@2x 128 128x128 256 128x128@2x 256 256x256 512 256x256@2x 512 512x512 1024 512x512@2x)
    for ((i=0; i<${#SIZES[@]}; i+=2)); do
        sips -z "${SIZES[$i]}" "${SIZES[$i]}" "$ICON_SRC" --out "$ISET/icon_${SIZES[$((i+1))]}.png" >/dev/null
    done
    iconutil -c icns "$ISET" -o "$SCRIPT_DIR/AppIcon.icns"
fi
if [ -f "$SCRIPT_DIR/AppIcon.icns" ]; then
    cp "$SCRIPT_DIR/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

# Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Claude Usage</string>
    <key>CFBundleDisplayName</key>
    <string>Claude Usage</string>
    <key>CFBundleIdentifier</key>
    <string>com.claude.usage-widget</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleExecutable</key>
    <string>ClaudeUsage</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
</dict>
</plist>
PLIST

echo "App bundle created: $APP_BUNDLE"
echo ""
echo "To install, run: ./install.sh"
echo "Or open directly: open \"$APP_BUNDLE\""
