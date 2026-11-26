#!/usr/bin/env bash
# Builds Superwarm.app (release), installs it to ~/Applications and launches it.
# Usage: scripts/install-app.sh [--no-launch] [--dest DIR]
set -euo pipefail

cd "$(dirname "$0")/.."
DEST="$HOME/Applications"
LAUNCH=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-launch) LAUNCH=0 ;;
    --dest) DEST="$2"; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

swift build -c release --product Superwarm
BIN_DIR="$(swift build -c release --show-bin-path)"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Superwarm.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Superwarm" "$APP/Contents/MacOS/Superwarm"
cp -R "$BIN_DIR/Superwarm_Superwarm.bundle" "$APP/Contents/Resources/"

# App icon: the white glyph on a warm gradient tile.
swift scripts/make-icon.swift assets/logo-2000.png "$STAGE/Superwarm.iconset"
iconutil -c icns "$STAGE/Superwarm.iconset" -o "$APP/Contents/Resources/Superwarm.icns"

VERSION="$(git describe --always --dirty 2>/dev/null || echo dev)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Superwarm</string>
  <key>CFBundleDisplayName</key><string>Superwarm</string>
  <key>CFBundleIdentifier</key><string>com.superwarm.app</string>
  <key>CFBundleExecutable</key><string>Superwarm</string>
  <key>CFBundleIconFile</key><string>Superwarm</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"

mkdir -p "$DEST"
pkill -x Superwarm 2>/dev/null || true
rm -rf "$DEST/Superwarm.app"
cp -R "$APP" "$DEST/Superwarm.app"
echo "Installed $DEST/Superwarm.app"

if [[ $LAUNCH == 1 ]]; then open "$DEST/Superwarm.app"; fi
