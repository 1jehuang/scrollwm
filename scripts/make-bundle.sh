#!/bin/bash
# make-bundle.sh - assemble (and sign) ScrollWM.app from a built binary.
#
# Single source of truth for HOW the .app bundle is shaped: Info.plist, icon,
# CLI-preserving wrapper, and code signature. Both scripts/install.sh (local
# install) and the GitHub Actions release workflow call this so the bundle is
# identical everywhere.
#
# Usage:
#   scripts/make-bundle.sh <app-path> <binary-path> [sign-id] [version]
#
#   <app-path>     where to write the bundle, e.g. ~/Applications/ScrollWM.app
#   <binary-path>  the built WindowLab executable (arm64 or universal)
#   [sign-id]      codesign identity; "-" for ad-hoc (default), or a cert name
#   [version]      CFBundleShortVersionString (default: 0.0.0-dev)
set -euo pipefail

APP="${1:?usage: make-bundle.sh <app-path> <binary-path> [sign-id] [version]}"
BIN="${2:?missing binary path}"
SIGN_ID="${3:--}"
VERSION="${4:-0.0.0-dev}"
BUNDLE_ID="dev.scrollwm.app"

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ICON_SRC="$REPO_DIR/Resources/AppIcon.icns"

[[ -x "$BIN" ]] || { echo "make-bundle: binary not found/executable: $BIN" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

ICON_KEY=""
if [[ -f "$ICON_SRC" ]]; then
    cp "$ICON_SRC" "$APP/Contents/Resources/AppIcon.icns"
    ICON_KEY="    <key>CFBundleIconFile</key><string>AppIcon</string>"
fi

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
$ICON_KEY
</dict>
</plist>
PLIST

# Wrapper keeps the CLI harness available: ScrollWM with no args = production
# app (run); subcommands still work for diagnostics (probe/bench/run --selftest).
# It resolves symlinks so a `scrollwm` symlink on PATH (e.g. /opt/homebrew/bin)
# still finds ScrollWM.bin inside the bundle.
cp "$BIN" "$APP/Contents/MacOS/ScrollWM.bin"
cat > "$APP/Contents/MacOS/ScrollWM" <<'WRAPPER'
#!/bin/bash
# Resolve this script through any symlinks to locate the real bundle dir.
SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SOURCE" ]]; do
    TARGET="$(readlink "$SOURCE")"
    if [[ "$TARGET" == /* ]]; then SOURCE="$TARGET"; else SOURCE="$(dirname "$SOURCE")/$TARGET"; fi
done
DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
if [[ $# -eq 0 ]]; then
    exec "$DIR/ScrollWM.bin" run
fi
exec "$DIR/ScrollWM.bin" "$@"
WRAPPER
chmod +x "$APP/Contents/MacOS/ScrollWM"

# Sign the inner binary first, then the bundle. A stable identity keeps the
# designated requirement constant across rebuilds (Accessibility persists);
# "-" is ad-hoc (fine for downloads, re-grant on each update).
codesign --force --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$APP/Contents/MacOS/ScrollWM.bin"
codesign --force --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$APP"

codesign --verify --deep "$APP"
echo "make-bundle: wrote $APP (version $VERSION, sign '$SIGN_ID')"
