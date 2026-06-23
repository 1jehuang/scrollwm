#!/bin/bash
# Build and install ScrollWM.app to ~/Applications (or a path you pass).
#
# Safe by design:
#   - builds release binary from this repo
#   - assembles a proper .app bundle via scripts/make-bundle.sh
#   - installs to ~/Applications by default (no sudo, no system files touched)
#   - never auto-launches; never touches windows until you click Arrange
#
# Usage:
#   ./scripts/install.sh                   # arm64, install to ~/Applications
#   ./scripts/install.sh /Applications     # install system-wide (may need perms)
#   ./scripts/install.sh --universal       # build a universal (Intel+ARM) bundle
#   ./scripts/install.sh --universal /Applications
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(cat "$REPO_DIR/VERSION" 2>/dev/null || echo 0.0.0-dev)"

UNIVERSAL=0
DEST_DIR=""
for arg in "$@"; do
    case "$arg" in
        --universal) UNIVERSAL=1 ;;
        *) DEST_DIR="$arg" ;;
    esac
done
DEST_DIR="${DEST_DIR:-$HOME/Applications}"
APP="$DEST_DIR/ScrollWM.app"

cd "$REPO_DIR"
if [[ "$UNIVERSAL" == "1" ]]; then
    echo "==> building universal release binary (arm64 + x86_64)"
    swift build -c release --arch arm64 --arch x86_64 2>&1 | tail -1
    BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/WindowLab"
else
    echo "==> building release binary"
    swift build -c release 2>&1 | tail -1
    BIN="$(swift build -c release --show-bin-path)/WindowLab"
fi
[[ -x "$BIN" ]] || { echo "build failed: $BIN missing"; exit 1; }

# Prefer a stable self-signed identity (see scripts/setup-signing.sh) so the
# Accessibility grant persists across updates; otherwise fall back to ad-hoc.
SIGN_ID="-"
SIGN_NOTE="ad-hoc (Accessibility may need re-granting after updates)"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "ScrollWM Self-Signed"; then
    SIGN_ID="ScrollWM Self-Signed"
    SIGN_NOTE="stable self-signed (Accessibility persists across updates)"
fi

echo "==> assembling + signing bundle ($SIGN_NOTE)"
mkdir -p "$DEST_DIR"
"$REPO_DIR/scripts/make-bundle.sh" "$APP" "$BIN" "$SIGN_ID" "$VERSION"

echo "==> verifying"
"$APP/Contents/MacOS/ScrollWM.bin" help >/dev/null && echo "    binary runs"

cat <<DONE

Installed: $APP  (v$VERSION)

First run:
  1. open "$APP"      (menu bar icon appears; nothing is touched yet)
  2. grant Accessibility when prompted:
     System Settings -> Privacy & Security -> Accessibility -> enable ScrollWM
  3. use the menu bar icon -> "Arrange Windows into Strip"

Controls (also in the in-app tutorial):
  ctrl+opt+left/right   focus previous/next column
  ctrl+opt+1..9         jump to column N
  opt+1/2/3/4           focused column width 25/50/75/100%
  cmd+shift+h / cmd+shift+l   move focused column left/right
  cmd+q                 close focused window
  ctrl+opt+esc          toggle arrange/release
  menu -> Release       restore all windows to original positions
  menu -> Quit          also restores everything

Note: $SIGN_NOTE.
DONE
