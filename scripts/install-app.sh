#!/usr/bin/env bash
# Builds Superwarm.app from source, installs it to ~/Applications and launches it.
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

APP="$(scripts/build-app.sh | tail -1)"

mkdir -p "$DEST"
pkill -x Superwarm 2>/dev/null || true
rm -rf "$DEST/Superwarm.app"
ditto "$APP" "$DEST/Superwarm.app"
echo "Installed $DEST/Superwarm.app"

if [[ $LAUNCH == 1 ]]; then open "$DEST/Superwarm.app"; fi
