#!/bin/bash
# Restart ScrollWM with the latest local changes.
#
#   1. Gracefully stops the running ScrollWM (SIGTERM -> it restores every
#      window to its original frame before exiting).
#   2. Rebuilds + reinstalls the app bundle from this repo (scripts/install.sh).
#   3. Relaunches ScrollWM.app.
#
# Safe to run from a launcher (jauncher): logs to a file and never blocks on
# input. Re-running while a build is in progress is fine (swift build locks).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP="$HOME/Applications/ScrollWM.app"
LOG="${TMPDIR:-/tmp}/scrollwm-restart.log"

exec > >(tee "$LOG") 2>&1
echo "==> restart-scrollwm $(date '+%H:%M:%S')  repo=$REPO_DIR"

# 1. Stop the running instance gracefully (restores windows). pkill matches the
#    installed bundle binary; the SIGTERM handler restores frames, then exits.
if pgrep -f "ScrollWM.app/Contents/MacOS/ScrollWM" >/dev/null 2>&1; then
    echo "==> stopping running ScrollWM (graceful restore)"
    pkill -TERM -f "ScrollWM.app/Contents/MacOS/ScrollWM" || true
    # Wait up to 5s for it to exit so we don't relaunch a second copy.
    for _ in $(seq 1 50); do
        pgrep -f "ScrollWM.app/Contents/MacOS/ScrollWM" >/dev/null 2>&1 || break
        sleep 0.1
    done
fi

# 2. Build + install the latest binary into ~/Applications.
echo "==> building + installing latest"
"$REPO_DIR/scripts/install.sh"

# 3. Relaunch.
echo "==> launching $APP"
open "$APP"
echo "==> done"
