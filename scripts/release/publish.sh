#!/usr/bin/env bash
# Publish a Find My Crew release from this Mac: run the tests, build a Developer ID-signed, notarized app with
# scripts/release/build.sh, then create the GitHub release vVERSION at the current commit (gh creates the tag) with
# FindMyCrew.zip and its checksum, the assets scripts/install.sh downloads.
#
# Usage: scripts/release/publish.sh 1.2.0
#        SKIP_TESTS=1 scripts/release/publish.sh 1.2.0
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/build/release}"
ASSET="FindMyCrew.zip"
VERSION="${1:-}"
VERSION="${VERSION#v}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  echo "usage: scripts/release/publish.sh VERSION   (e.g. 1.2.0)" >&2
  exit 64
fi
TAG="v$VERSION"

fail() { echo "error: $*" >&2; exit 1; }
cd "$REPO_ROOT"
gh auth status >/dev/null 2>&1 || fail "gh isn't logged in; run: gh auth login"
[[ -z "$(git status --porcelain)" ]] || fail "the working tree has uncommitted changes."
[[ "$(git rev-parse --abbrev-ref HEAD)" == main ]] || fail "releases are published from main."
git fetch --quiet --tags origin main
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "main isn't in sync with origin/main."
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then fail "$TAG already exists."; fi
COMMIT="$(git rev-parse HEAD)"

if [[ -z "${SKIP_TESTS:-}" ]]; then
  echo "Running tests…"
  mise run test:scripts
  mise run test
fi
# Never publish an ad-hoc build: scripts/install.sh only accepts downloads signed by the team.
SIGNING=developer-id OUT_DIR="$OUT_DIR" "$SCRIPT_DIR/build.sh" "$VERSION"

gh release create "$TAG" "$OUT_DIR/$ASSET" "$OUT_DIR/$ASSET.sha256" \
  --target "$COMMIT" --title "Find My Crew $VERSION" --generate-notes --draft \
  || fail "release creation or asset upload failed; inspect the draft $TAG before retrying."
gh release edit "$TAG" --draft=false \
  || fail "couldn't publish $TAG; the release and uploaded assets remain a draft."
git fetch --quiet --tags origin
echo "Published $TAG. Install it with:"
echo "  curl -fsSL https://raw.githubusercontent.com/arkaydeus/find-my-crew/main/scripts/install.sh | bash"
