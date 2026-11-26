#!/usr/bin/env bash
# Builds a versioned Superwarm.app, with Sparkle embedded, into dist/.
#
# Environment:
#   VERSION       marketing version, e.g. 1.2.0 (default: latest v* tag, else 0.0.0)
#   BUILD_NUMBER  monotonically increasing integer (default: commit count)
#   UNIVERSAL=1   build for arm64 and x86_64 (default: host architecture only)
#   SIGN_IDENTITY codesigning identity (default: "-" for ad-hoc). A Developer ID
#                 identity also enables the hardened runtime, for notarization.
#   FEED_URL      Sparkle appcast URL (default: latest GitHub release's appcast.xml)
#
# Prints the path of the built app on the last line.
set -euo pipefail
cd "$(dirname "$0")/.."

latest_tag="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"
VERSION="${VERSION:-${latest_tag#v}}"
VERSION="${VERSION:-0.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
FEED_URL="${FEED_URL:-https://github.com/camggould/superwarm/releases/latest/download/appcast.xml}"
# EdDSA public key matching the private key that signs release archives.
# The private key lives in the maintainer's Keychain (account "superwarm") and
# in the SPARKLE_PRIVATE_KEY repository secret. Never commit the private key.
SPARKLE_PUBLIC_KEY="arsOfQAY8W/hLuodLQE3pGgWCBPj4gn/pWw3rJM5KV8="

arch_flags=()
if [[ "${UNIVERSAL:-0}" == 1 ]]; then
  arch_flags=(--arch arm64 --arch x86_64)
fi

swift build -c release --product Superwarm ${arch_flags[@]+"${arch_flags[@]}"} >&2
BIN_DIR="$(swift build -c release --show-bin-path ${arch_flags[@]+"${arch_flags[@]}"})"

DIST="dist"
APP="$DIST/Superwarm.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Superwarm" "$APP/Contents/MacOS/Superwarm"
cp -R "$BIN_DIR/Superwarm_Superwarm.bundle" "$APP/Contents/Resources/"
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

ICONSET="$(mktemp -d)/Superwarm.iconset"
swift scripts/make-icon.swift assets/logo-2000.png "$ICONSET" >&2
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Superwarm.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Superwarm</string>
  <key>CFBundleDisplayName</key><string>Superwarm</string>
  <key>CFBundleIdentifier</key><string>com.camggould.superwarm</string>
  <key>CFBundleExecutable</key><string>Superwarm</string>
  <key>CFBundleIconFile</key><string>Superwarm</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
  <key>SUFeedURL</key><string>${FEED_URL}</string>
  <key>SUPublicEDKey</key><string>${SPARKLE_PUBLIC_KEY}</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
</dict>
</plist>
PLIST

# Sign inside-out, as Sparkle documents for hardened-runtime / notarized apps.
# The hardened runtime (required for notarization) enforces library validation:
# every loaded library must share the app's Team ID. Ad-hoc signatures have no
# Team ID, so ad-hoc builds skip the hardened runtime or Sparkle won't load.
sign_flags=(--force --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  sign_flags+=(--timestamp=none)
else
  sign_flags+=(--timestamp --options runtime)
fi
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
codesign "${sign_flags[@]}" "$SPARKLE/Versions/B/XPCServices/Installer.xpc" >&2
codesign "${sign_flags[@]}" --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" >&2
codesign "${sign_flags[@]}" "$SPARKLE/Versions/B/Autoupdate" >&2
codesign "${sign_flags[@]}" "$SPARKLE/Versions/B/Updater.app" >&2
codesign "${sign_flags[@]}" "$SPARKLE" >&2
codesign "${sign_flags[@]}" "$APP" >&2
codesign --verify --deep --strict "$APP" >&2
echo "Built Superwarm ${VERSION} (${BUILD_NUMBER}) at $APP" >&2
echo "$APP"
