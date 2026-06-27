#!/usr/bin/env bash
# Track 5 — live Spaces empirical repro harness (SANDBOX ONLY, safe).
#
# Drives ONLY ScrollWM's `sandbox` mode (disposable .accessory windows the real
# app never enumerates) and records timestamped ground truth across native-Space
# events. NEVER touches the user's real windows. Refuses to run while the screen
# is locked (AX degraded -> ScrollWM stays inert by design, nothing to observe).
#
# It captures, with millisecond timestamps:
#   - the sandbox strip state (`scrollwm status` JSON over the sandbox socket)
#   - the WindowServer on-screen list size (current Space) via `WindowLab probe`
# before/after each scripted event so we can SEE the stale strip / phantom
# column / viewport jump as it happens.
#
# Usage: scripts/track5-spaces-repro.sh [window_count]
# Then follow the printed prompts; press RETURN after performing each manual
# Space action (Ctrl-Left/Right, Mission Control drag, fullscreen toggle).
set -u
cd "$(dirname "$0")/.."

BIN=.build/debug/WindowLab
SOCK="/tmp/scrollwm-sandbox-track5.sock"
LOG="/tmp/track5-spaces-repro.$(date +%Y%m%d-%H%M%S).log"
N="${1:-4}"

ts() { python3 -c 'import datetime; print(datetime.datetime.now().strftime("%H:%M:%S.%f")[:-3])'; }
say() { echo "[$(ts)] $*" | tee -a "$LOG"; }

# --- Guard: screen must be UNLOCKED for any of this to be meaningful. ---
LOCKED=$(python3 - <<'PY'
import ctypes, ctypes.util
cg = ctypes.CDLL(ctypes.util.find_library('CoreGraphics'))
cf = ctypes.CDLL(ctypes.util.find_library('CoreFoundation'))
cg.CGSessionCopyCurrentDictionary.restype = ctypes.c_void_p
cf.CFDictionaryGetValue.restype = ctypes.c_void_p
cf.CFDictionaryGetValue.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
cf.CFStringCreateWithCString.restype = ctypes.c_void_p
cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
cf.CFNumberGetValue.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
d = cg.CGSessionCopyCurrentDictionary()
if not d:
    print("nosession"); raise SystemExit
key = cf.CFStringCreateWithCString(None, b"CGSSessionScreenIsLocked", 0x08000100)
v = cf.CFDictionaryGetValue(d, key)
if not v:
    print("0"); raise SystemExit
out = ctypes.c_int(0)
cf.CFNumberGetValue(v, 9, ctypes.byref(out))  # kCFNumberIntType
print(out.value)
PY
)
if [ "$LOCKED" != "0" ]; then
  say "ABORT: screen is locked (CGSSessionScreenIsLocked=$LOCKED). ScrollWM stays inert while locked; unlock and re-run."
  exit 3
fi

snap() { # snapshot: label
  local on
  on=$($BIN probe 2>/dev/null | head -1)
  local st
  st=$(SCROLLWM_CONTROL_SOCK="$SOCK" $BIN status 2>/dev/null \
        | python3 -c 'import sys,json
try:
  d=json.load(sys.stdin)
  cols=d.get("columns",[])
  print("managing=%s ws=%s focus=%s cols=%d titles=%s"%(
    d.get("managing"), d.get("workspace"), d.get("focusedColumn"),
    len(cols), [c["title"] for c in cols]))
except Exception as e:
  print("status-unavailable(%s)"%e)' 2>/dev/null)
  say "SNAP[$1] strip{$st} | wsonscreen{$on}"
}

cleanup() {
  say "cleaning up sandbox (pid $(cat /tmp/track5-sandbox.pid 2>/dev/null))"
  kill "$(cat /tmp/track5-sandbox.pid 2>/dev/null)" 2>/dev/null
  pkill -f "WindowLab testwindow" 2>/dev/null
  rm -f "$SOCK"
}
trap cleanup EXIT

say "=== Track 5 live Spaces repro start (N=$N) — log: $LOG ==="
rm -f "$SOCK"
SCROLLWM_CONTROL_SOCK="$SOCK" $BIN sandbox "$N" > /tmp/track5-sandbox.out 2>&1 &
echo $! > /tmp/track5-sandbox.pid
say "sandbox launched pid=$(cat /tmp/track5-sandbox.pid); waiting for arrange..."
sleep 3
cat /tmp/track5-sandbox.out | sed 's/^/    sandbox: /' | tee -a "$LOG"
snap "after-arrange"

prompt() { # message
  echo
  echo ">>> MANUAL STEP: $1"
  echo ">>> Press RETURN immediately AFTER you do it."
  read -r _
}

# E1: switch native Space away and back while strip manages sandbox windows.
prompt "E1a: Ctrl-Right to the NEXT native Space (away from the sandbox)."
snap "E1a-on-other-space"
prompt "E1b: Ctrl-Left back to the sandbox's Space."
snap "E1b-back"

# E2: open a new sandbox window while on ANOTHER Space, then come back.
prompt "E2a: Ctrl-Right to another Space, then run (in another shell): kill -USR1 \$(pgrep -f 'WindowLab testwindow' | head -1)"
snap "E2a-newwin-other-space"
prompt "E2b: Ctrl-Left back to the sandbox Space."
snap "E2b-back"

# E3: send a sandbox window to another Space (Mission Control drag).
prompt "E3: drag the FOCUSED sandbox window to another Desktop in Mission Control, then return to the sandbox Space."
snap "E3-after-send"

# E4: fullscreen a sandbox window (creates a fullscreen Space), then exit.
prompt "E4a: green-button fullscreen the focused sandbox window."
snap "E4a-fullscreen"
prompt "E4b: exit fullscreen (Ctrl-Cmd-F or green button)."
snap "E4b-exit-fullscreen"

say "=== repro complete; full log at $LOG ==="
echo "Log: $LOG"
