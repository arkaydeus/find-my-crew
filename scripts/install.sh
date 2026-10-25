#!/usr/bin/env bash
# Install Find My Crew: the app into /Applications (or ~/Applications) and its fmc command-line tool onto PATH
# as a link into the app, so updating the app updates fmc too. Rerun to update.
#
#   curl -fsSL https://raw.githubusercontent.com/arkaydeus/find-my-crew/main/scripts/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/arkaydeus/find-my-crew/main/scripts/install.sh | bash -s -- --version 1.2.0
#
# Options: see usage() below, or --help. FIND_MY_CREW_DOWNLOAD_URL overrides the release download folder (for
# testing the installer).
set -euo pipefail

REPO="arkaydeus/find-my-crew"
APP_NAME="Find My Crew.app"
BUNDLE_ID="com.findmycrew.app"
# Releases are signed with this Apple Developer ID team and notarized; downloads must be.
TEAM_ID="QWD87G9T3P"
ASSET="FindMyCrew.zip"

die() { echo "error: $*" >&2; exit 1; }
usage() {
  cat <<'USAGE'
Install or update Find My Crew and its fmc command-line tool.

Options:
  --version V     install release V (default: the latest release)
  --from PATH     install a local FindMyCrew.zip or Find My Crew.app instead of downloading one
  --app-dir DIR   where the app goes (default: where it's already installed, else /Applications if
                  writable, else ~/Applications)
  --bin-dir DIR   where the fmc link goes (default: ~/.local/bin)
  --no-cli        don't link fmc
  --uninstall     remove the app and the fmc link (keeps settings in ~/Library/Containers/com.findmycrew.app)
USAGE
}

bundle_id() { /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$1/Contents/Info.plist" 2>/dev/null || true; }
app_version() { /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$1/Contents/Info.plist" 2>/dev/null || true; }

# The folder holding an existing install, if any.
installed_dir() {
  local dir
  for dir in /Applications "$HOME/Applications"; do
    if [[ "$(bundle_id "$dir/$APP_NAME")" == "$BUNDLE_ID" ]]; then echo "$dir"; return; fi
  done
}

ensure_not_running() {
  if pgrep -x "Find My Crew" >/dev/null 2>&1; then
    die "Find My Crew is running. Quit it and run the installer again."
  fi
}

# Only replace or remove an app bundle that really is Find My Crew.
check_replaceable() {
  [[ -e "$1" ]] || return 0
  [[ "$(bundle_id "$1")" == "$BUNDLE_ID" ]] || die "$1 exists but isn't Find My Crew; leaving it alone."
  ensure_not_running
}

# True when $1 is a link this installer made (it points at fmc inside a Find My Crew app).
is_our_link() { [[ -L "$1" && "$(readlink "$1")" == *"/$APP_NAME/Contents/Helpers/fmc" ]]; }

uninstall() {
  local app_dir="$1" bin_dir="$2" removed=0
  [[ -n "$app_dir" ]] || app_dir="$(installed_dir)"
  if [[ -n "$app_dir" && -e "$app_dir/$APP_NAME" ]]; then
    check_replaceable "$app_dir/$APP_NAME"
    rm -rf "${app_dir:?}/$APP_NAME"
    echo "Removed $app_dir/$APP_NAME"
    removed=1
  fi
  if is_our_link "$bin_dir/fmc"; then
    rm "$bin_dir/fmc"
    echo "Removed $bin_dir/fmc"
    removed=1
  fi
  [[ "$removed" == 1 ]] || echo "Find My Crew isn't installed."
}

main() {
  local version="" from="" app_dir="" bin_dir="$HOME/.local/bin" cli=1 action=install
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version) [[ $# -ge 2 ]] || die "--version needs a value"; version="${2#v}"; shift 2 ;;
      --from) [[ $# -ge 2 ]] || die "--from needs a path"; from="$2"; shift 2 ;;
      --app-dir) [[ $# -ge 2 ]] || die "--app-dir needs a folder"; app_dir="${2%/}"; shift 2 ;;
      --bin-dir) [[ $# -ge 2 ]] || die "--bin-dir needs a folder"; bin_dir="${2%/}"; shift 2 ;;
      --no-cli) cli=0; shift ;;
      --uninstall) action=uninstall; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown option: $1 (see --help)" ;;
    esac
  done
  [[ -z "$version" || -z "$from" ]] || die "use either --version or --from, not both"

  [[ "$(uname -s)" == Darwin ]] || die "Find My Crew is a macOS app."
  if [[ "$action" == uninstall ]]; then uninstall "$app_dir" "$bin_dir"; return; fi
  local macos
  macos="$(sw_vers -productVersion)"
  [[ "${macos%%.*}" -ge 15 ]] || die "Find My Crew needs macOS 15 or later (this Mac has $macos)."

  if [[ -z "$app_dir" ]]; then
    app_dir="$(installed_dir)"
    if [[ -z "$app_dir" ]]; then
      if [[ -w /Applications ]]; then app_dir=/Applications; else app_dir="$HOME/Applications"; fi
    fi
  fi

  local tmp src
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064  # expand now: $tmp is local
  trap "rm -rf '$tmp'" EXIT

  if [[ -n "$from" ]]; then
    if [[ -d "$from" ]]; then
      src="${from%/}"
    elif [[ -f "$from" ]]; then
      ditto -x -k "$from" "$tmp/unpacked" || die "couldn't unpack $from"
      src="$tmp/unpacked/$APP_NAME"
    else
      die "$from doesn't exist"
    fi
  else
    local base="${FIND_MY_CREW_DOWNLOAD_URL:-}"
    if [[ -z "$base" ]]; then
      if [[ -n "$version" ]]; then
        base="https://github.com/$REPO/releases/download/v$version"
      else
        base="https://github.com/$REPO/releases/latest/download"
      fi
    fi
    echo "Downloading Find My Crew ${version:-(latest)}…"
    curl -fsSL --retry 3 -o "$tmp/$ASSET" "$base/$ASSET" || die "download failed: $base/$ASSET"
    curl -fsSL --retry 3 -o "$tmp/$ASSET.sha256" "$base/$ASSET.sha256" || die "download failed: $base/$ASSET.sha256"
    (cd "$tmp" && shasum -a 256 -c "$ASSET.sha256" >/dev/null 2>&1) || die "checksum mismatch for $ASSET; not installing."
    ditto -x -k "$tmp/$ASSET" "$tmp/unpacked" || die "couldn't unpack $ASSET"
    src="$tmp/unpacked/$APP_NAME"
  fi

  [[ "$(bundle_id "$src")" == "$BUNDLE_ID" ]] || die "$src isn't a Find My Crew app bundle."
  codesign --verify --deep --strict "$src" 2>/dev/null || die "the app's code signature is invalid; not installing."
  if [[ -z "$from" ]]; then
    codesign --verify --deep --strict -R="anchor apple generic and certificate leaf[subject.OU] = \"$TEAM_ID\"" \
      "$src" 2>/dev/null || die "the download isn't signed by Find My Crew's developer (team $TEAM_ID); not installing."
    spctl --assess --type execute "$src" 2>/dev/null || die "Gatekeeper rejects the download (not notarized?); not installing."
  fi

  local dest="$app_dir/$APP_NAME" staged="$app_dir/.$APP_NAME.installing"
  check_replaceable "$dest"
  mkdir -p "$app_dir"
  rm -rf "$staged"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp' '$staged'" EXIT
  ditto "$src" "$staged" || die "couldn't copy the app into $app_dir"
  rm -rf "$dest"
  mv "$staged" "$dest"
  echo "Installed Find My Crew $(app_version "$dest") → $dest"

  [[ "$cli" == 1 ]] || return 0
  local fmc="$dest/Contents/Helpers/fmc" link="$bin_dir/fmc"
  [[ -x "$fmc" ]] || die "this build of the app doesn't include fmc."
  mkdir -p "$bin_dir"
  if [[ -e "$link" && ! -L "$link" ]]; then
    echo "warning: $link is a file, not a link; leaving it alone. Remove it and rerun to install fmc." >&2
    return 0
  fi
  ln -sfn "$fmc" "$link"
  echo "Linked fmc $("$link" --version) → $link"

  case ":$PATH:" in
    *":$bin_dir:"*)
      local found
      found="$(command -v fmc || true)"
      if [[ -n "$found" && "$found" != "$link" ]]; then
        echo "note: \`fmc\` currently runs $found, which comes earlier on PATH than $link."
      fi
      ;;
    *) echo "note: $bin_dir isn't on your PATH. Add it, e.g.: echo 'export PATH=\"$bin_dir:\$PATH\"' >> ~/.zshrc" ;;
  esac
}

main "$@"
