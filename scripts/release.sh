#!/usr/bin/env bash
# Tags a release. Pushing the tag makes GitHub Actions build and publish it.
# Usage: scripts/release.sh 1.2.0 [--push]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh VERSION [--push]}"
PUSH="${2:-}"
TAG="v$VERSION"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || { echo "Not a semantic version: $VERSION" >&2; exit 1; }
[[ "$(git rev-parse --abbrev-ref HEAD)" == "main" ]] || { echo "Release from main." >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Working tree is not clean." >&2; exit 1; }
git fetch --quiet origin main --tags
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || { echo "main is not in sync with origin/main." >&2; exit 1; }
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { echo "$TAG already exists." >&2; exit 1; }
[[ -n "$(scripts/changelog-section.sh "$VERSION")" ]] || { echo "Add a '## [$VERSION]' section to CHANGELOG.md first." >&2; exit 1; }
engine_version="$(sed -n 's/^version = "\(.*\)"/\1/p' engine/Cargo.toml | head -1)"
[[ "$engine_version" == "$VERSION" ]] || { echo "engine/Cargo.toml is at $engine_version; set it to $VERSION first." >&2; exit 1; }

swift test
(cd engine && cargo test --quiet)
git tag -a "$TAG" -m "Superwarm $VERSION"
echo "Tagged $TAG."
if [[ "$PUSH" == "--push" ]]; then
  git push origin "$TAG"
  echo "Pushed. Follow the build at https://github.com/camggould/superwarm/actions"
else
  echo "Push it with: git push origin $TAG"
fi
