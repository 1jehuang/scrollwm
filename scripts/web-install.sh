#!/bin/bash
# ScrollWM web installer.
#
# Downloads the latest released ScrollWM.app (prefers the .zip asset, falls back
# to the .dmg), strips the Gatekeeper quarantine (harmless if the build is
# notarized), installs it to ~/Applications, and launches it. No sudo, no system
# files touched, nothing on your desktop is arranged until you grant
# Accessibility (or, after that, until you click Arrange).
#
# Idempotent: re-run anytime to update in place. It quits a running ScrollWM
# first (which restores your windows), then swaps the bundle atomically.
#
# One-liner:
#   curl -fsSL https://raw.githubusercontent.com/1jehuang/scrollwm/main/scripts/web-install.sh | bash
#
# Options (env vars):
#   SCROLLWM_DEST=/Applications   install location (default: ~/Applications)
#   SCROLLWM_VERSION=0.1.0        pin a specific version (default: latest)
set -euo pipefail

REPO="1jehuang/scrollwm"
DEST="${SCROLLWM_DEST:-$HOME/Applications}"
APP="$DEST/ScrollWM.app"

say() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
die() { printf '\033[1;31mxx \033[0m %s\n' "$1" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "ScrollWM is macOS-only."
command -v curl >/dev/null 2>&1 || die "curl is required (it ships with macOS)."

# A temp dir for the download/extract; cleaned up (and any mounted dmg detached)
# on any exit path.
TMP="$(mktemp -d)"
MOUNT=""
cleanup() {
    [[ -n "$MOUNT" && -d "$MOUNT" ]] && hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
    rm -rf "$TMP"
}
trap cleanup EXIT

# --- Resolve the release + asset URL ---------------------------------------
# Pick the requested (or latest) release, then prefer its .zip asset (no mount
# needed) and fall back to the .dmg.
if [[ -n "${SCROLLWM_VERSION:-}" ]]; then
    API="https://api.github.com/repos/$REPO/releases/tags/v$SCROLLWM_VERSION"
else
    API="https://api.github.com/repos/$REPO/releases/latest"
fi

say "finding ${SCROLLWM_VERSION:+v$SCROLLWM_VERSION }release"
JSON="$(curl -fsSL --retry 3 --retry-delay 1 "$API")" \
    || die "could not reach the GitHub releases API (network down, or no such release)."

# Print the download URL of the ScrollWM asset with extension $1 (zip|dmg), or
# nothing. Pure text parsing kept off the main pipeline so a no-match (grep
# exit 1) under `set -o pipefail` can't abort the script before we report it.
asset_url() {
    printf '%s\n' "$JSON" \
        | grep -Eo '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]+"' \
        | sed -E 's/^.*"(https[^"]+)".*$/\1/' \
        | grep -E "/ScrollWM[^/]*\.$1$" \
        | head -n 1
}

URL=""; EXT=""
if URL="$(asset_url zip)" && [[ -n "$URL" ]]; then
    EXT="zip"
elif URL="$(asset_url dmg)" && [[ -n "$URL" ]]; then
    EXT="dmg"
fi
[[ -n "$URL" ]] || die "no ScrollWM .zip or .dmg asset in that release yet. Try later, or build from source: https://github.com/$REPO#build-from-source"

VER="$(basename "$URL" | sed -E 's/^ScrollWM-//; s/\.(zip|dmg)$//')"

# --- Download --------------------------------------------------------------
say "downloading ScrollWM $VER ($EXT)"
ARCHIVE="$TMP/ScrollWM.$EXT"
curl -fSL --retry 3 --retry-delay 1 --progress-bar "$URL" -o "$ARCHIVE" \
    || die "download failed (network interrupted?). Re-run to retry."

# --- Extract to $SRC_APP ---------------------------------------------------
SRC_APP=""
if [[ "$EXT" == "zip" ]]; then
    say "unpacking"
    ditto -x -k "$ARCHIVE" "$TMP/extracted" || die "could not unpack the archive (corrupt download?)."
    SRC_APP="$TMP/extracted/ScrollWM.app"
else
    say "mounting disk image"
    MOUNT="$TMP/mnt"
    mkdir -p "$MOUNT"
    hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" "$ARCHIVE" >/dev/null \
        || die "could not mount the disk image."
    say "copying out of the disk image"
    ditto "$MOUNT/ScrollWM.app" "$TMP/from-dmg/ScrollWM.app" || die "disk image did not contain ScrollWM.app"
    hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
    MOUNT=""
    SRC_APP="$TMP/from-dmg/ScrollWM.app"
fi
[[ -d "$SRC_APP" ]] || die "archive did not contain ScrollWM.app"

# Sanity-check the bundle so a wrong/corrupt asset can't be installed silently.
[[ -x "$SRC_APP/Contents/MacOS/ScrollWM" ]] || die "downloaded bundle is missing its executable."
BID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SRC_APP/Contents/Info.plist" 2>/dev/null || true)"
if [[ -n "$BID" && "$BID" != "dev.scrollwm.app" ]]; then
    die "downloaded bundle has unexpected id '$BID'; refusing to install."
fi

# --- Quit a running instance (restores managed windows first) --------------
if pgrep -f "ScrollWM.app/Contents/MacOS/ScrollWM" >/dev/null 2>&1; then
    say "quitting running ScrollWM (windows restore on quit)"
    osascript -e 'tell application "ScrollWM" to quit' >/dev/null 2>&1 || true
    sleep 0.5
    pkill -f "ScrollWM.app/Contents/MacOS/ScrollWM" >/dev/null 2>&1 || true
fi

# --- Install atomically ----------------------------------------------------
say "installing to $DEST"
mkdir -p "$DEST"
STAGE="$DEST/.ScrollWM.app.installing"
rm -rf "$STAGE"
ditto "$SRC_APP" "$STAGE"
# Remove the quarantine flag so the (ad-hoc-signed) app opens without the
# "unidentified developer" block. Equivalent to right-click -> Open once; a
# no-op on a notarized build.
xattr -dr com.apple.quarantine "$STAGE" 2>/dev/null || true
rm -rf "$APP"
mv "$STAGE" "$APP"

say "launching"
open "$APP"

cat <<DONE

ScrollWM $VER installed to:
  $APP

Next (first run only):
  1. A menu-bar icon appears and a short setup window opens. Nothing on your
     desktop is touched yet.
  2. ScrollWM opens System Settings to Privacy & Security -> Accessibility.
     Flip the ScrollWM switch ON -- that one permission is all it needs.
  3. The instant you do, ScrollWM continues automatically (no relaunch) and
     arranges your current windows into the strip. No second prompt, no restart.

After that, ScrollWM launches dormant: it touches nothing until you Arrange
(menu-bar icon -> "Arrange Windows into Strip", or press ctrl+opt+esc). Release
or Quit from the menu restores every window to exactly where it was.

Already granted Accessibility on a previous install? ScrollWM skips all of the
above and starts silently -- it never asks when it doesn't need to.

Update later by re-running this same command.
DONE
