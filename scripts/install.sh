#!/bin/bash
# Build and install ScrollWM.app to /Applications (or ~/Applications).
#
# Safe by design:
#   - builds release binary from this repo
#   - creates a proper .app bundle with stable bundle ID + ad-hoc signature
#   - installs to ~/Applications by default (no sudo, no system files touched)
#   - never auto-launches; never touches windows until you click Arrange
#
# Usage:
#   ./scripts/install.sh                 # install to ~/Applications
#   ./scripts/install.sh /Applications   # install system-wide (may need perms)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEST_DIR="${1:-$HOME/Applications}"
APP="$DEST_DIR/ScrollWM.app"
BUNDLE_ID="dev.scrollwm.app"
VERSION="0.1.0"

echo "==> building release binary"
cd "$REPO_DIR"
swift build -c release 2>&1 | tail -1

BIN="$REPO_DIR/.build/release/WindowLab"
[[ -x "$BIN" ]] || { echo "build failed: $BIN missing"; exit 1; }

echo "==> assembling bundle"
mkdir -p "$DEST_DIR"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>ScrollWM</string>
    <key>CFBundleDisplayName</key><string>ScrollWM</string>
    <key>CFBundleExecutable</key><string>ScrollWM</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Wrapper keeps the CLI harness available: ScrollWM with no args = production
# app; subcommands still work for diagnostics (probe/bench/run --selftest...).
cp "$BIN" "$APP/Contents/MacOS/ScrollWM.bin"
cat > "$APP/Contents/MacOS/ScrollWM" <<'WRAPPER'
#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ $# -eq 0 ]]; then
    exec "$DIR/ScrollWM.bin" run
fi
exec "$DIR/ScrollWM.bin" "$@"
WRAPPER
chmod +x "$APP/Contents/MacOS/ScrollWM"

echo "==> signing (ad-hoc, stable identifier)"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP/Contents/MacOS/ScrollWM.bin"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"

echo "==> verifying"
codesign --verify --deep "$APP" && echo "    signature ok"
"$APP/Contents/MacOS/ScrollWM.bin" help >/dev/null && echo "    binary runs"

cat <<DONE

Installed: $APP

First run:
  1. open "$APP"      (menu bar icon appears; nothing is touched yet)
  2. grant Accessibility when prompted:
     System Settings -> Privacy & Security -> Accessibility -> enable ScrollWM
  3. relaunch, then use the menu bar icon -> "Arrange Windows into Strip"

Controls:
  ctrl+opt+left/right   focus previous/next column
  ctrl+opt+1..9         jump to column N
  opt+1/2/3/4           focused column width 25/50/75/100%
  cmd+h / cmd+l         move focused column left/right
  cmd+q                 close focused window
  ctrl+opt+esc          toggle arrange/release
  menu -> Release       restore all windows to original positions
  menu -> Quit          also restores everything

Note: ad-hoc signature means Accessibility must be re-granted if you
reinstall after changing the binary. For personal use this is fine.
DONE
