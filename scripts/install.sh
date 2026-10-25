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

# Keep trap data outside main's local scope, and never interpolate paths into shell source.
tmp="" transaction="" backup="" dest=""
state_lock="" app_lock=""
cleanup() {
  local status=$? preserve=0
  trap - EXIT
  set +e
  if [[ "$status" != 0 && -n "$backup" && -e "$backup" ]]; then
    # Inspect the filesystem rather than a flag set after mv: a signal can arrive between the
    # rename and the next shell statement. Never move the backup inside an existing destination.
    if [[ -e "$dest" || -L "$dest" ]] && ! rm -rf "$dest"; then
      preserve=1
    elif ! mv "$backup" "$dest"; then
      preserve=1
    fi
    if [[ "$preserve" == 1 ]]; then
      echo "error: couldn't restore the previous app; it is preserved at $backup" >&2
    fi
  fi
  [[ -z "$tmp" ]] || rm -rf "$tmp"
  if [[ -n "$transaction" && "$preserve" == 0 ]]; then rm -rf "$transaction"; fi
  [[ -z "$app_lock" ]] || rmdir "$app_lock"
  [[ -z "$state_lock" ]] || rmdir "$state_lock"
  exit "$status"
}

absolute_dir() { mkdir -p "$1" && (cd "$1" && pwd -P); }

# mkdir is atomic on macOS. Fail promptly rather than racing an active installer. A lock left by
# SIGKILL requires manual removal; never guess that another process's lock is stale.
lock_dir() {
  mkdir "$1" 2>/dev/null || die "another install/uninstall may be active (lock: $1). Retry when it finishes; remove the lock only if no installer is running."
}

die() { echo "error: $*" >&2; exit 1; }
usage() {
  cat <<'USAGE'
Install or update Find My Crew and its fmc command-line tool.

Options:
  --version V     install release V (default: the latest release)
  --from PATH     install a local FindMyCrew.zip or Find My Crew.app instead of downloading one
  --app-dir DIR   where the app goes (remembered for updates/uninstall; default: the existing location,
                  else /Applications if writable, else ~/Applications)
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
  [[ -e "$1" || -L "$1" ]] || return 0
  [[ ! -L "$1" ]] || die "$1 is a symlink; leaving it alone."
  [[ "$(bundle_id "$1")" == "$BUNDLE_ID" ]] || die "$1 exists but isn't Find My Crew; leaving it alone."
  ensure_not_running
}

# Only manage links into the selected installation, including its dangling link after app removal.
is_our_link() { [[ -L "$1" && "$(readlink "$1")" == "$2/Contents/Helpers/fmc" ]]; }

uninstall() {
  local app_dir="$1" bin_dir="$2" removed=0
  local owned_link=0
  if is_our_link "$bin_dir/fmc" "$app_dir/$APP_NAME"; then owned_link=1; fi
  if [[ -n "$app_dir" && -e "$app_dir/$APP_NAME" ]]; then
    check_replaceable "$app_dir/$APP_NAME"
    rm -rf "${app_dir:?}/$APP_NAME"
    echo "Removed $app_dir/$APP_NAME"
    removed=1
  fi
  if [[ "$owned_link" == 1 ]]; then
    rm "$bin_dir/fmc"
    echo "Removed $bin_dir/fmc"
    removed=1
  fi
  [[ "$removed" == 1 ]] || echo "Find My Crew isn't installed."
}

main() {
  local version="" from="" app_dir="" bin_dir="" cli=1 action=install
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version) [[ $# -ge 2 ]] || die "--version needs a value"; version="${2#v}"; shift 2 ;;
      --from) [[ $# -ge 2 ]] || die "--from needs a path"; from="$2"; shift 2 ;;
      --app-dir) [[ $# -ge 2 && -n "$2" ]] || die "--app-dir needs a folder"; app_dir="$2"; shift 2 ;;
      --bin-dir) [[ $# -ge 2 && -n "$2" ]] || die "--bin-dir needs a folder"; bin_dir="$2"; shift 2 ;;
      --no-cli) cli=0; shift ;;
      --uninstall) action=uninstall; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown option: $1 (see --help)" ;;
    esac
  done
  [[ -z "$version" || -z "$from" ]] || die "use either --version or --from, not both"
  [[ "$action" != uninstall || ( -z "$version" && -z "$from" && "$cli" == 1 ) ]] || die "--uninstall cannot be combined with --version, --from or --no-cli"

  [[ "$(uname -s)" == Darwin ]] || die "Find My Crew is a macOS app."
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  local state_dir="$HOME/Library/Application Support/Find My Crew/installer"
  mkdir -p "$state_dir"
  lock_dir "$state_dir/lock"
  state_lock="$state_dir/lock"
  if [[ -z "$app_dir" && -f "$state_dir/app-dir" ]]; then app_dir="$(cat "$state_dir/app-dir")"; fi
  if [[ -z "$bin_dir" && -f "$state_dir/bin-dir" ]]; then bin_dir="$(cat "$state_dir/bin-dir")"; fi
  bin_dir="$(absolute_dir "${bin_dir:-$HOME/.local/bin}")"
  if [[ -z "$app_dir" ]]; then app_dir="$(installed_dir)"; fi
  if [[ -z "$app_dir" ]]; then
    if [[ "$action" == uninstall ]]; then
      echo "No app located. For an older custom installation, repeat --app-dir DIR (and --bin-dir DIR)."
      return
    fi
    if [[ -w /Applications ]]; then app_dir=/Applications; else app_dir="$HOME/Applications"; fi
  fi
  app_dir="$(absolute_dir "$app_dir")"
  lock_dir "$app_dir/.$APP_NAME.install-lock"
  app_lock="$app_dir/.$APP_NAME.install-lock"
  dest="$app_dir/$APP_NAME"
  if [[ "$action" == uninstall ]]; then
    uninstall "$app_dir" "$bin_dir"
    if [[ -f "$state_dir/app-dir" && "$(cat "$state_dir/app-dir")" == "$app_dir" ]]; then
      rm -f "$state_dir/app-dir" "$state_dir/bin-dir"
    fi
    return
  fi
  local macos
  macos="$(sw_vers -productVersion)"
  [[ "${macos%%.*}" -ge 15 ]] || die "Find My Crew needs macOS 15 or later (this Mac has $macos)."

  local src
  tmp="$(mktemp -d)"

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

  check_replaceable "$dest"
  transaction="$(mktemp -d "$app_dir/.$APP_NAME.installing.XXXXXX")"
  local staged="$transaction/$APP_NAME" fmc_version link="$bin_dir/fmc" link_cli="$cli"
  ditto "$src" "$staged" || die "couldn't copy the app into $app_dir"
  if [[ "$cli" == 1 ]]; then
    [[ -x "$staged/Contents/Helpers/fmc" ]] || die "this build of the app doesn't include fmc."
    fmc_version="$("$staged/Contents/Helpers/fmc" --version)" || die "the staged fmc --version failed; leaving the installed app alone."
    [[ -n "$fmc_version" ]] || die "the staged fmc reported an empty version."
    if [[ -e "$link" || -L "$link" ]] && ! is_our_link "$link" "$dest"; then
      echo "warning: $link isn't this installation's fmc link; leaving it alone. Remove it and rerun to install fmc." >&2
      link_cli=0
    fi
  fi
  if [[ -e "$dest" ]]; then
    backup="$transaction/previous.app"
    mv "$dest" "$backup"
  fi
  mv "$staged" "$dest" || die "couldn't move the staged app into place; restoring the previous app."
  echo "Installed Find My Crew $(app_version "$dest") → $dest"

  if [[ "$link_cli" == 1 ]]; then
    ln -sfn "$dest/Contents/Helpers/fmc" "$link"
    fmc_version="$("$link" --version)" || die "the installed fmc --version failed."
    [[ -n "$fmc_version" ]] || die "the installed fmc reported an empty version."
    echo "Linked fmc $fmc_version → $link"
  fi
  printf '%s\n' "$app_dir" > "$state_dir/app-dir"
  printf '%s\n' "$bin_dir" > "$state_dir/bin-dir"
  [[ "$link_cli" == 1 ]] || return 0

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
