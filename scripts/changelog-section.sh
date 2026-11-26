#!/usr/bin/env bash
# Prints the body of a version's section from CHANGELOG.md.
# Usage: scripts/changelog-section.sh 1.2.0
set -euo pipefail
cd "$(dirname "$0")/.."
version="${1:?usage: changelog-section.sh VERSION}"
awk -v v="$version" '
  $0 ~ "^## \\[" v "\\]" { inside = 1; next }
  inside && /^## / { exit }
  inside { print }
' CHANGELOG.md | sed -e '/./,$!d' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
