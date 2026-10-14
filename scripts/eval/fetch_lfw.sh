#!/usr/bin/env bash
# Download Labeled Faces in the Wild (LFW) for `mise run eval` into models-cache/eval/.
#
# Result:
#   models-cache/eval/lfw/<Identity>/<Identity>_NNNN.jpg   (13 233 images, 5 749 identities)
#   models-cache/eval/pairs.txt                           (standard 6 000-pair verification protocol)
#
# LFW is for research/evaluation only. It is never committed or bundled with the app.
#
# Usage: scripts/eval/fetch_lfw.sh            # idempotent; skips work already done
#        EVAL_DIR=/tmp/eval scripts/eval/fetch_lfw.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
EVAL_DIR="${EVAL_DIR:-$REPO_ROOT/models-cache/eval}"

# Figshare mirrors of the original UMass files (same mirrors scikit-learn uses).
LFW_URL="https://ndownloader.figshare.com/files/5976018"    # lfw.tgz
PAIRS_URL="https://ndownloader.figshare.com/files/5976006"  # pairs.txt
LFW_SHA256="055f7d9c632d7370e6fb4afc7468d40f970c34a80d4c6f50ffec63f5a8d536c0"

mkdir -p "$EVAL_DIR"
cd "$EVAL_DIR"

if [[ ! -f pairs.txt ]]; then
  echo "Downloading pairs.txt…"
  curl -fL --retry 3 -o pairs.txt.part "$PAIRS_URL"
  mv pairs.txt.part pairs.txt
fi

if [[ -d lfw ]] && [[ "$(find lfw -name '*.jpg' | wc -l | tr -d ' ')" -ge 13233 ]]; then
  echo "LFW already present in $EVAL_DIR/lfw"
  exit 0
fi

if [[ ! -f lfw.tgz ]]; then
  echo "Downloading lfw.tgz (~173 MB)…"
  curl -fL --retry 3 -C - -o lfw.tgz.part "$LFW_URL"
  mv lfw.tgz.part lfw.tgz
fi

actual="$(shasum -a 256 lfw.tgz | cut -d' ' -f1)"
if [[ "$actual" != "$LFW_SHA256" ]]; then
  echo "error: lfw.tgz checksum mismatch (got $actual)" >&2
  echo "Delete $EVAL_DIR/lfw.tgz and try again." >&2
  exit 1
fi

echo "Extracting…"
rm -rf lfw
tar -xzf lfw.tgz
rm lfw.tgz
echo "LFW ready: $(find lfw -name '*.jpg' | wc -l | tr -d ' ') images in $EVAL_DIR/lfw"
