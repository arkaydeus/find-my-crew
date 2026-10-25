#!/usr/bin/env bash
# Build a Find My Crew release: a universal (arm64 + x86_64) app with fmc inside it (Contents/Helpers/fmc), zipped
# for GitHub Releases. scripts/release/publish.sh runs this before uploading.
#
# Signing (SIGNING=…):
#   auto           default: developer-id if the team's Developer ID Application certificate is in the keychain,
#                  else adhoc
#   developer-id   sign with Developer ID (hardened runtime, secure timestamp), notarize with notarytool, staple,
#                  and require Gatekeeper to accept the app
#   adhoc          ad-hoc signature; runs on this Mac, but a browser download of it is blocked by Gatekeeper
# TEAM_ID (default QWD87G9T3P) picks the certificate; NOTARY_PROFILE (default orkestrator-notary) is the
# `xcrun notarytool store-credentials` profile holding the notarization login.
#
# Result:
#   build/release/FindMyCrew.zip           Find My Crew.app
#   build/release/FindMyCrew.zip.sha256    checked by scripts/install.sh
#
# Usage: scripts/release/build.sh 1.2.0      # version to stamp on the app and fmc (a leading v is dropped)
#        scripts/release/build.sh            # keep project.yml's version, for local testing
#        SIGNING=adhoc OUT_DIR=/tmp/release DERIVED=/tmp/dd scripts/release/build.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DERIVED="${DERIVED:-$REPO_ROOT/build/DerivedData}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/build/release}"
SIGNING="${SIGNING:-auto}"
TEAM_ID="${TEAM_ID:-QWD87G9T3P}"
NOTARY_PROFILE="${NOTARY_PROFILE:-orkestrator-notary}"
ASSET="FindMyCrew.zip"
VERSION="${1:-}"
VERSION="${VERSION#v}"

fail() { echo "error: $*" >&2; exit 1; }

settings=(ONLY_ACTIVE_ARCH=NO)
if [[ -n "$VERSION" ]]; then
  # CFBundleShortVersionString only allows up to three dot-separated integers.
  if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    echo "error: version must look like 1.2 or 1.2.3 (got '$VERSION')" >&2
    exit 64
  fi
  settings+=(MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$(git -C "$REPO_ROOT" rev-list --count HEAD)")
fi

has_identity() { security find-identity -v -p codesigning | grep -q "\"Developer ID Application: .*($TEAM_ID)\""; }
case "$SIGNING" in
  auto) if has_identity; then SIGNING=developer-id; else SIGNING=adhoc; fi ;;
  developer-id) has_identity || fail "no Developer ID Application certificate for team $TEAM_ID in the keychain." ;;
  adhoc) ;;
  *) fail "SIGNING must be auto, developer-id or adhoc (got '$SIGNING')" ;;
esac
if [[ "$SIGNING" == developer-id ]]; then
  # The project signs ad hoc; this switches the app and the embedded fmc to Developer ID. Hardened runtime is
  # already on for both; notarization also needs a secure timestamp, and rejects the get-task-allow (debugger)
  # entitlement that `xcodebuild build` otherwise adds even in Release.
  settings+=(CODE_SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Manual
    OTHER_CODE_SIGN_FLAGS=--timestamp CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO)
fi

APP="$DERIVED/Build/Products/Release/Find My Crew.app"
FMC="$APP/Contents/Helpers/fmc"

cd "$REPO_ROOT"
xcodegen generate --quiet
# Rebuild the bundle from scratch so nothing stale from an earlier build ends up in the zip.
rm -rf "$APP"
echo "Building Find My Crew ${VERSION:-(project.yml version)} (Release, universal, $SIGNING)…"
xcodebuild -project FindMyCrew.xcodeproj -scheme FindMyCrew -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" "${settings[@]}" build -quiet

[[ -x "$FMC" ]] || fail "fmc is missing from the app bundle ($FMC)"
[[ -d "$APP/Contents/Resources/SFace.mlmodelc" ]] || fail "the compiled SFace model is missing from the app bundle"
for binary in "$APP/Contents/MacOS/Find My Crew" "$FMC"; do
  archs="$(lipo -archs "$binary")"
  [[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || fail "$(basename "$binary") is not universal (archs: $archs)"
done
codesign --verify --deep --strict "$APP" || fail "code signature check failed"
built_version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
fmc_version="$("$FMC" --version)"
[[ "$fmc_version" == "$built_version" ]] || fail "fmc reports version '$fmc_version' but the app is $built_version"
[[ -z "$VERSION" || "$built_version" == "$VERSION" ]] || fail "built version $built_version, expected $VERSION"

mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR/$ASSET" "$OUT_DIR/$ASSET.sha256"

if [[ "$SIGNING" == developer-id ]]; then
  for code in "$FMC" "$APP"; do
    info="$(codesign -dvv "$code" 2>&1)"
    [[ "$info" == *"TeamIdentifier=$TEAM_ID"* ]] || fail "$(basename "$code") isn't signed by team $TEAM_ID"
    [[ "$info" == *"Timestamp="* ]] || fail "$(basename "$code") has no secure timestamp"
    [[ "$info" =~ flags=0x[0-9a-f]+\([^\)]*runtime ]] || fail "$(basename "$code") doesn't use the hardened runtime"
    if codesign -d --entitlements - --xml "$code" 2>/dev/null | grep -q get-task-allow; then
      fail "$(basename "$code") has the get-task-allow entitlement, which notarization rejects"
    fi
  done

  echo "Notarizing (usually a few minutes)…"
  ditto -c -k --keepParent "$APP" "$OUT_DIR/notarize.zip"
  result="$(xcrun notarytool submit "$OUT_DIR/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait \
    --output-format json)" || fail "notarytool submit failed: $result"
  rm -f "$OUT_DIR/notarize.zip"
  status="$(plutil -extract status raw - <<<"$result" 2>/dev/null || true)"
  if [[ "$status" != Accepted ]]; then
    id="$(plutil -extract id raw - <<<"$result" 2>/dev/null || true)"
    fail "notarization ${status:-failed} (submission ${id:-unknown}); see: xcrun notarytool log ${id:-<id>} --keychain-profile $NOTARY_PROFILE"
  fi
  xcrun stapler staple -q "$APP" || fail "couldn't staple the notarization ticket"
  xcrun stapler validate -q "$APP" || fail "the stapled ticket doesn't validate"
  spctl --assess --type execute "$APP" 2>/dev/null || fail "Gatekeeper rejects the notarized app"
fi

ditto -c -k --keepParent "$APP" "$OUT_DIR/$ASSET"
(cd "$OUT_DIR" && shasum -a 256 "$ASSET" > "$ASSET.sha256")
echo "Built Find My Crew $built_version ($SIGNING): $OUT_DIR/$ASSET ($(du -h "$OUT_DIR/$ASSET" | cut -f1 | tr -d ' '))"
