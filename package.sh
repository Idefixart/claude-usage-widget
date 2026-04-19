#!/bin/bash
# Package the app as a shareable DMG (AirDrop-friendly).
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Claude Usage"
BUILD_DIR="$SCRIPT_DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
DMG_DIR="$BUILD_DIR/dmg"
DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"
VERSION="1.1.0"

# Build fresh
bash "$SCRIPT_DIR/build.sh"

# Ad-hoc sign so Gatekeeper accepts it after unquarantine
codesign --force --deep --sign - "$APP_BUNDLE" || true

# Stage DMG
rm -rf "$DMG_DIR" "$DMG_PATH"
mkdir -p "$DMG_DIR"
cp -R "$APP_BUNDLE" "$DMG_DIR/"
ln -s /Applications "$DMG_DIR/Applications"

# Volume icon (shown when DMG is mounted)
if [ -f "$SCRIPT_DIR/AppIcon.icns" ]; then
    cp "$SCRIPT_DIR/AppIcon.icns" "$DMG_DIR/.VolumeIcon.icns"
    SETFILE="/usr/bin/SetFile"
    [ ! -x "$SETFILE" ] && SETFILE="/Library/Developer/CommandLineTools/usr/bin/SetFile"
    [ -x "$SETFILE" ] && "$SETFILE" -a C "$DMG_DIR" || true
fi

# README inside DMG
cat > "$DMG_DIR/LIES_MICH.txt" << 'EOF'
Claude Usage Widget
===================

Installation:
1. "Claude Usage.app" in "Applications" ziehen.
2. Beim ersten Start: Rechtsklick -> "Oeffnen" (ungesigniert, ad-hoc).
3. Beim ersten Fetch werden Python-Deps (cryptography, curl_cffi)
   automatisch per pip3 --user installiert. Python 3 muss vorhanden sein.

Voraussetzungen:
- macOS 14+
- Claude Desktop installiert und eingeloggt (liefert Session-Cookies)
- Python 3 (macOS hat "/usr/bin/python3" vorinstalliert)

Das Widget zeigt:
- 5h Session, 7d Gesamt, Sonnet, Opus, Claude Design
- Extra Usage + Current Balance
EOF

# Build DMG
hdiutil create -volname "$APP_NAME" \
    -srcfolder "$DMG_DIR" \
    -ov -format UDZO \
    "$DMG_PATH"

# Unquarantine for local tests; shared copy will still be quarantined on recipient
xattr -d com.apple.quarantine "$DMG_PATH" 2>/dev/null || true

# Set the .dmg file's own Finder icon (shows as thumbnail in Finder)
# Uses NSWorkspace.setIcon via a tiny compiled Swift helper (no PyObjC dep).
if [ -f "$SCRIPT_DIR/AppIcon.icns" ]; then
    SETICON_BIN="$BUILD_DIR/seticon"
    cat > "$BUILD_DIR/seticon.swift" <<'SWIFT'
import AppKit
let a = CommandLine.arguments
guard a.count >= 3, let img = NSImage(contentsOfFile: a[1]) else { exit(1) }
let ok = NSWorkspace.shared.setIcon(img, forFile: a[2], options: [])
exit(ok ? 0 : 2)
SWIFT
    swiftc "$BUILD_DIR/seticon.swift" -o "$SETICON_BIN" 2>/dev/null
    "$SETICON_BIN" "$SCRIPT_DIR/AppIcon.icns" "$DMG_PATH" || echo "warn: dmg icon not set"
fi

echo ""
echo "DMG ready: $DMG_PATH"
echo "Share via AirDrop / iMessage. Recipient: right-click app -> Open (first time)."
