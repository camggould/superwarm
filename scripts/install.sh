#!/usr/bin/env bash
# Installs or updates Superwarm from its latest GitHub release.
#
#   curl -fsSL https://raw.githubusercontent.com/camggould/superwarm/main/scripts/install.sh | bash
#
# Environment:
#   SUPERWARM_VERSION  install a specific version, e.g. 1.2.0 (default: latest)
#   SUPERWARM_DEST     install directory (default: ~/Applications)
#
# The archive is checked against the release's SHA256SUMS before anything is
# installed. Everything runs inside main() so a partial download does nothing.
set -euo pipefail

main() {
  local repo="camggould/superwarm"
  local dest="${SUPERWARM_DEST:-$HOME/Applications}"

  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Superwarm is a macOS app." >&2; exit 1
  fi
  local major
  major="$(sw_vers -productVersion | cut -d. -f1)"
  if (( major < 14 )); then
    echo "Superwarm needs macOS 14 Sonoma or later." >&2; exit 1
  fi

  local tag
  if [[ -n "${SUPERWARM_VERSION:-}" ]]; then
    tag="v${SUPERWARM_VERSION#v}"
  else
    # The /releases/latest page redirects to /releases/tag/vX.Y.Z (no API rate limits).
    tag="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$repo/releases/latest")"
    tag="${tag##*/}"
  fi
  [[ "$tag" == v* ]] || { echo "Couldn't find a Superwarm release." >&2; exit 1; }
  local version="${tag#v}"
  local base="https://github.com/$repo/releases/download/$tag"
  local zip="Superwarm-$version.zip"

  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  echo "Downloading Superwarm $version…"
  curl -fL --progress-bar -o "$tmp/$zip" "$base/$zip"
  curl -fsSL -o "$tmp/SHA256SUMS" "$base/SHA256SUMS"

  local expected actual
  expected="$(awk -v f="$zip" '$2 == f || $2 == "*"f { print $1 }' "$tmp/SHA256SUMS")"
  actual="$(shasum -a 256 "$tmp/$zip" | awk '{ print $1 }')"
  if [[ -z "$expected" || "$expected" != "$actual" ]]; then
    echo "Checksum mismatch for $zip; not installing." >&2; exit 1
  fi

  ditto -x -k "$tmp/$zip" "$tmp/out"
  [[ -d "$tmp/out/Superwarm.app" ]] || { echo "Archive did not contain Superwarm.app." >&2; exit 1; }

  osascript -e 'tell application id "com.camggould.superwarm" to quit' >/dev/null 2>&1 || true
  pkill -x Superwarm >/dev/null 2>&1 || true

  mkdir -p "$dest"
  rm -rf "$dest/Superwarm.app"
  ditto "$tmp/out/Superwarm.app" "$dest/Superwarm.app"
  # curl doesn't quarantine downloads, but clear the flag in case of a re-run on
  # a browser-downloaded copy.
  xattr -dr com.apple.quarantine "$dest/Superwarm.app" 2>/dev/null || true

  open "$dest/Superwarm.app"
  echo "Installed Superwarm $version to $dest/Superwarm.app. Look for it in your menu bar."
  echo "It updates itself from now on (Settings → Updates)."
}

main "$@"
