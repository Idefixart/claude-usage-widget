#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Claude Usage"
BUILD_DIR="$SCRIPT_DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
INSTALL_DIR="/Applications"

# Build first if needed
if [ ! -d "$APP_BUNDLE" ]; then
    echo "Building first..."
    bash "$SCRIPT_DIR/build.sh"
fi

# Copy to Applications
echo "Installing to $INSTALL_DIR..."
rm -rf "$INSTALL_DIR/$APP_NAME.app"
cp -R "$APP_BUNDLE" "$INSTALL_DIR/"
echo "Installed to $INSTALL_DIR/$APP_NAME.app"

# Add to Login Items (auto-start)
echo ""
read -p "Beim Login automatisch starten? (j/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Jj]$ ]]; then
    osascript -e "tell application \"System Events\" to make login item at end with properties {path:\"$INSTALL_DIR/$APP_NAME.app\", hidden:true}"
    echo "Login-Item hinzugefuegt."
fi

echo ""
echo "Starte App..."
open "$INSTALL_DIR/$APP_NAME.app"
echo "Fertig! Du siehst jetzt '◆' in deiner Menueleiste."
