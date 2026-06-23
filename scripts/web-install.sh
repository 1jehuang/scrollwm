#!/bin/bash
# ScrollWM web installer.
#
# Downloads the latest released ScrollWM.app, removes the Gatekeeper quarantine
# (the build is ad-hoc signed, not notarized), installs it to ~/Applications,
# and launches it. No sudo, no system files touched, nothing arranged until you
# click Arrange.
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

say()  { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m!! \033[0m %s\n' "$1"; }
die()  { printf '\033[1;31mxx \033[0m %s\n' "$1" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "ScrollWM is macOS-only."

# Resolve download URL for the requested (or latest) release zip.
if [[ -n "${SCROLLWM_VERSION:-}" ]]; then
    TAG="v$SCROLLWM_VERSION"
    API="https://api.github.com/repos/$REPO/releases/tags/$TAG"
else
    API="https://api.github.com/repos/$REPO/releases/latest"
fi

say "finding latest release"
JSON="$(curl -fsSL "$API")" || die "could not reach GitHub releases API."
URL="$(printf '%s' "$JSON" \
    | grep -o '"browser_download_url": *"[^"]*ScrollWM-[^"]*\.zip"' \
    | head -1 | sed 's/.*"https/https/; s/"$//')"
[[ -n "$URL" ]] || die "no .zip asset found in the release yet. Try again later or build from source: https://github.com/$REPO#build-from-source"

VER="$(basename "$URL" | sed 's/^ScrollWM-//; s/\.zip$//')"
say "downloading ScrollWM $VER"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fSL --progress-bar "$URL" -o "$TMP/ScrollWM.zip" || die "download failed."

say "unpacking"
ditto -x -k "$TMP/ScrollWM.zip" "$TMP/extracted"
[[ -d "$TMP/extracted/ScrollWM.app" ]] || die "archive did not contain ScrollWM.app"

# Quit any running instance (restores managed windows first).
if pgrep -f "ScrollWM.app/Contents/MacOS/ScrollWM" >/dev/null 2>&1; then
    say "quitting running ScrollWM (windows restore on quit)"
    osascript -e 'tell application "ScrollWM" to quit' >/dev/null 2>&1 || true
    sleep 0.5
    pkill -f "ScrollWM.app/Contents/MacOS/ScrollWM" >/dev/null 2>&1 || true
fi

say "installing to $DEST"
mkdir -p "$DEST"
rm -rf "$APP"
ditto "$TMP/extracted/ScrollWM.app" "$APP"

# Remove the quarantine flag so the ad-hoc-signed app opens without the
# "unidentified developer" block (equivalent to right-click -> Open once).
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

say "launching"
open "$APP"

cat <<DONE

ScrollWM $VER installed to:
  $APP

Next:
  1. A menu bar icon appears. Nothing on your desktop is touched yet.
  2. Grant Accessibility when asked:
     System Settings -> Privacy & Security -> Accessibility -> enable ScrollWM
  3. Menu bar icon -> "Arrange Windows into Strip", or press ctrl+opt+esc.

Release / Quit from the menu restores every window to where it was.
Update later by re-running this same command.
DONE
