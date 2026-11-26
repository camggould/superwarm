#!/usr/bin/env bash
# Builds, signs and packages a release into dist/:
#   Superwarm-<version>.zip   the universal app
#   SHA256SUMS                checksums, used by scripts/install.sh
#   appcast.xml               the Sparkle feed, pointing at this release
#
# Usage: VERSION=1.2.0 scripts/package-release.sh
#
# Environment:
#   SPARKLE_PRIVATE_KEY   EdDSA private key (CI). Without it the key is read from
#                         the Keychain account "superwarm" (maintainer machine).
#   SIGN_IDENTITY         Developer ID Application identity (optional; ad-hoc otherwise)
#   NOTARY_APPLE_ID, NOTARY_TEAM_ID, NOTARY_PASSWORD
#                         notarize with notarytool when all three are set
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:?set VERSION, e.g. VERSION=1.2.0}"
REPO="camggould/superwarm"
TAG="v$VERSION"
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"

APP="$(UNIVERSAL=1 VERSION="$VERSION" scripts/build-app.sh | tail -1)"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
ZIP="dist/Superwarm-$VERSION.zip"
rm -f "$ZIP"

if [[ -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_TEAM_ID:-}" && -n "${NOTARY_PASSWORD:-}" ]]; then
  echo "Notarizing…" >&2
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --wait \
    --apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD" >&2
  xcrun stapler staple "$APP" >&2
  rm -f "$ZIP"
else
  echo "Skipping notarization (no NOTARY_* credentials)." >&2
fi

ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(cd dist && shasum -a 256 "$(basename "$ZIP")" > SHA256SUMS)

if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  SIGNATURE="$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SPARKLE_BIN/sign_update" --ed-key-file - -p "$ZIP")"
else
  SIGNATURE="$("$SPARKLE_BIN/sign_update" --account superwarm -p "$ZIP")"
fi
LENGTH="$(stat -f%z "$ZIP")"
PUB_DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

# Release notes from CHANGELOG.md as simple HTML for Sparkle's update window.
NOTES_HTML="$(scripts/changelog-section.sh "$VERSION" | sed -E \
  -e 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' \
  -e 's/^### (.*)$/<h3>\1<\/h3>/' \
  -e 's/^[-*] (.*)$/<li>\1<\/li>/' \
  -e 's/\*\*([^*]+)\*\*/<b>\1<\/b>/g' \
  -e 's/`([^`]+)`/<code>\1<\/code>/g')"

cat > dist/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Superwarm</title>
    <link>https://github.com/$REPO</link>
    <description>Superwarm releases</description>
    <language>en</language>
    <item>
      <title>Superwarm $VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/$REPO/releases/tag/$TAG</sparkle:fullReleaseNotesLink>
      <description><![CDATA[
$NOTES_HTML
      ]]></description>
      <enclosure
        url="https://github.com/$REPO/releases/download/$TAG/$(basename "$ZIP")"
        sparkle:edSignature="$SIGNATURE"
        length="$LENGTH"
        type="application/octet-stream" />
    </item>
  </channel>
</rss>
XML

echo "Packaged Superwarm $VERSION ($BUILD_NUMBER):" >&2
ls -l "$ZIP" dist/SHA256SUMS dist/appcast.xml >&2
