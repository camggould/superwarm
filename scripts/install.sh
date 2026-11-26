#!/usr/bin/env bash
# Installs or updates Superwarm from its latest GitHub release.
#
#   curl -fsSL https://raw.githubusercontent.com/camggould/superwarm/main/scripts/install.sh | bash
#
# macOS: installs the menu bar app to ~/Applications (it bundles the CLI).
# Linux: installs the `superwarm` CLI to ~/.local/bin.
#
# Environment:
#   SUPERWARM_VERSION  install a specific version, e.g. 1.2.0 (default: latest)
#   SUPERWARM_DEST     app directory on macOS (default: ~/Applications)
#   SUPERWARM_BIN_DIR  CLI directory on Linux (default: ~/.local/bin)
#   SUPERWARM_DOWNLOAD_BASE  release download URL prefix, for mirrors and testing
#                      (default: https://github.com/camggould/superwarm/releases/download;
#                      requires SUPERWARM_VERSION)
#
# Archives are checked against the release's SHA256SUMS before anything is
# installed. Everything runs inside main() so a partial download does nothing.
set -euo pipefail

REPO="camggould/superwarm"

# Global, not local: the EXIT trap runs after main() returns.
tmp=""

fail() {
  echo "$*" >&2
  exit 1
}

sha256() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{ print $1 }'; else sha256sum "$1" | awk '{ print $1 }'; fi
}

resolve_tag() {
  if [[ -n "${SUPERWARM_VERSION:-}" ]]; then
    echo "v${SUPERWARM_VERSION#v}"
    return
  fi
  # The /releases/latest page redirects to /releases/tag/vX.Y.Z (no API rate limits).
  local url
  url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest")"
  echo "${url##*/}"
}

# Downloads release asset $1 into $tmp and verifies it against SHA256SUMS.
download_verified() {
  local tag="$1" asset="$2"
  local base="${SUPERWARM_DOWNLOAD_BASE:-https://github.com/$REPO/releases/download}/$tag"
  curl -fL --progress-bar -o "$tmp/$asset" "$base/$asset" || fail "This release has no $asset."
  curl -fsSL -o "$tmp/SHA256SUMS" "$base/SHA256SUMS"
  local expected actual
  expected="$(awk -v f="$asset" '$2 == f || $2 == "*"f { print $1 }' "$tmp/SHA256SUMS")"
  actual="$(sha256 "$tmp/$asset")"
  [[ -n "$expected" && "$expected" == "$actual" ]] || fail "Checksum mismatch for $asset; not installing."
}

install_macos_app() {
  local tag="$1" version="${1#v}"
  local dest="${SUPERWARM_DEST:-$HOME/Applications}"
  local major
  major="$(sw_vers -productVersion | cut -d. -f1)"
  (( major >= 14 )) || fail "Superwarm needs macOS 14 Sonoma or later."

  echo "Downloading Superwarm ${version}…"
  download_verified "$tag" "Superwarm-${version}.zip"
  ditto -x -k "$tmp/Superwarm-${version}.zip" "$tmp/out"
  [[ -d "$tmp/out/Superwarm.app" ]] || fail "Archive did not contain Superwarm.app."

  osascript -e 'tell application id "com.camggould.superwarm" to quit' >/dev/null 2>&1 || true
  pkill -x Superwarm >/dev/null 2>&1 || true

  mkdir -p "$dest"
  rm -rf "$dest/Superwarm.app"
  ditto "$tmp/out/Superwarm.app" "$dest/Superwarm.app"
  # curl doesn't quarantine downloads, but clear the flag in case of a re-run
  # on a browser-downloaded copy.
  xattr -dr com.apple.quarantine "$dest/Superwarm.app" 2>/dev/null || true

  open "$dest/Superwarm.app"
  echo "Installed Superwarm ${version} to $dest/Superwarm.app. Look for it in your menu bar."
  echo "It updates itself from now on (Settings → Updates)."
  if [[ -x "$dest/Superwarm.app/Contents/Helpers/superwarm" ]]; then
    echo "For the command line too: ln -sf \"$dest/Superwarm.app/Contents/Helpers/superwarm\" ~/.local/bin/superwarm"
  fi
}

install_linux_cli() {
  local tag="$1" version="${1#v}"
  local bin_dir="${SUPERWARM_BIN_DIR:-$HOME/.local/bin}"
  local target
  case "$(uname -m)" in
    x86_64 | amd64) target="x86_64-unknown-linux-musl" ;;
    aarch64 | arm64) target="aarch64-unknown-linux-musl" ;;
    *) fail "No prebuilt Superwarm for $(uname -m). Build it with: cargo install --git https://github.com/$REPO superwarm" ;;
  esac

  local asset="superwarm-${version}-${target}.tar.gz"
  echo "Downloading the Superwarm ${version} CLI…"
  download_verified "$tag" "$asset"
  tar -xzf "$tmp/$asset" -C "$tmp"
  mkdir -p "$bin_dir"
  install -m 0755 "$tmp/superwarm" "$bin_dir/superwarm"

  echo "Installed superwarm ${version} to $bin_dir/superwarm."
  case ":$PATH:" in
    *":$bin_dir:"*) echo "Try: superwarm report today" ;;
    *) echo "Add $bin_dir to your PATH, then try: superwarm report today" ;;
  esac
}

main() {
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp:-}"' EXIT

  local tag
  tag="$(resolve_tag)"
  [[ "$tag" == v* ]] || fail "Couldn't find a Superwarm release."

  case "$(uname -s)" in
    Darwin) install_macos_app "$tag" ;;
    Linux) install_linux_cli "$tag" ;;
    *) fail "Superwarm supports macOS and Linux." ;;
  esac
}

main "$@"
