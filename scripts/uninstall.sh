#!/bin/bash
# Uninstall ScrollWM: quit it (restoring all windows), remove the app bundle,
# and optionally delete its support files (config + crash-recovery state).
#
# Usage:
#   ./scripts/uninstall.sh           # remove the app, keep your config
#   ./scripts/uninstall.sh --purge   # also delete config + app support data
set -euo pipefail

PURGE=0
[[ "${1:-}" == "--purge" ]] && PURGE=1

say() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }

say "quitting ScrollWM (windows restore on quit)"
osascript -e 'tell application "ScrollWM" to quit' >/dev/null 2>&1 || true
sleep 0.5
pkill -x ScrollWM.bin >/dev/null 2>&1 || true

for APP in "$HOME/Applications/ScrollWM.app" "/Applications/ScrollWM.app"; do
    if [[ -d "$APP" ]]; then
        say "removing $APP"
        rm -rf "$APP"
    fi
done

SUPPORT="$HOME/Library/Application Support/ScrollWM"
SANDBOX="$HOME/Library/Application Support/ScrollWM-Sandbox"
if [[ "$PURGE" == "1" ]]; then
    for d in "$SUPPORT" "$SANDBOX"; do
        [[ -d "$d" ]] && { say "deleting $d"; rm -rf "$d"; }
    done
else
    [[ -d "$SUPPORT" ]] && say "kept your config: $SUPPORT (use --purge to delete)"
fi

say "done. If ScrollWM still appears in System Settings -> Privacy & Security ->"
say "Accessibility, remove it there with the '-' button."
