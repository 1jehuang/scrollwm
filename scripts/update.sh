#!/bin/bash
# Rebuild ScrollWM from the current repo and replace the installed app in
# place, then relaunch it. This is the "get my latest change running" button.
#
# Usage:
#   ./scripts/update.sh                 # update ~/Applications/ScrollWM.app
#   ./scripts/update.sh /Applications   # update a system-wide install
#
# It just delegates to install.sh (single source of truth for how the bundle
# is built/signed), but additionally quits the running instance first and
# relaunches afterward so you don't have to.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEST_DIR="${1:-$HOME/Applications}"
APP="$DEST_DIR/ScrollWM.app"

echo "==> quitting running ScrollWM (windows are restored on quit)"
# Ask nicely first so the app restores managed windows; fall back to kill.
osascript -e 'tell application "ScrollWM" to quit' >/dev/null 2>&1 || true
pkill -x ScrollWM.bin >/dev/null 2>&1 || true
sleep 0.5

echo "==> reinstalling from $REPO_DIR"
"$REPO_DIR/scripts/install.sh" "$DEST_DIR"

echo "==> relaunching"
open "$APP"

echo
echo "Updated and relaunched: $APP"
echo "If macOS asks for Accessibility again, that means the build is ad-hoc"
echo "signed. Run scripts/setup-signing.sh once to keep the permission across"
echo "future updates."
