#!/bin/bash
# Install a "Restart ScrollWM" launcher entry into ~/Applications so app
# launchers (jauncher, Spotlight, Raycast, ...) can find and run it.
#
# It builds a tiny .app bundle whose only job is to invoke scripts/restart.sh
# (rebuild + reinstall + relaunch ScrollWM with the latest local changes).
#
# Usage: ./scripts/install-restart-launcher.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RESTART="$REPO_DIR/scripts/restart.sh"
DEST_DIR="$HOME/Applications"
APP="$DEST_DIR/Restart ScrollWM.app"
BUNDLE_ID="dev.scrollwm.restart"

chmod +x "$RESTART"

echo "==> assembling launcher bundle: $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>Restart ScrollWM</string>
    <key>CFBundleDisplayName</key><string>Restart ScrollWM</string>
    <key>CFBundleExecutable</key><string>RestartScrollWM</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# The launcher binary is a shell wrapper that calls the repo's restart script.
# It points at the live repo (this checkout) so it always rebuilds the latest.
cat > "$APP/Contents/MacOS/RestartScrollWM" <<WRAPPER
#!/bin/bash
exec "$RESTART"
WRAPPER
chmod +x "$APP/Contents/MacOS/RestartScrollWM"

# Reuse the ScrollWM app icon if one exists, so the entry is recognizable.
ICON_SRC="$HOME/Applications/ScrollWM.app/Contents/Resources/AppIcon.icns"
if [[ -f "$ICON_SRC" ]]; then
    mkdir -p "$APP/Contents/Resources"
    cp "$ICON_SRC" "$APP/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
fi

echo "==> signing (ad-hoc)"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" >/dev/null 2>&1 || true

# Nudge LaunchServices so the new bundle is discoverable immediately.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$APP" >/dev/null 2>&1 || true

echo "==> installed. Search your launcher for: Restart ScrollWM"
