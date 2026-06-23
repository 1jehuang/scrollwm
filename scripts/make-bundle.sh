#!/bin/bash
# make-bundle.sh - assemble (and sign) ScrollWM.app from a built binary.
#
# Single source of truth for HOW the .app bundle is shaped: Info.plist, icon,
# main executable, and code signature. Both scripts/install.sh (local install)
# and the GitHub Actions release workflow call this so the bundle is identical
# everywhere.
#
# Usage:
#   scripts/make-bundle.sh <app-path> <binary-path> [sign-id] [version]
#
#   <app-path>     where to write the bundle, e.g. ~/Applications/ScrollWM.app
#   <binary-path>  the built WindowLab executable (arm64 or universal)
#   [sign-id]      codesign identity; "-" for ad-hoc (default), a self-signed
#                  cert name, or a "Developer ID Application: ..." identity.
#                  Omit to auto-detect the best available (see signing-lib.sh).
#   [version]      CFBundleShortVersionString (default: 0.0.0-dev)
#
# Signing tiers (see scripts/signing-lib.sh):
#   - Developer ID Application -> hardened runtime + entitlements + secure
#     timestamp, so the bundle is NOTARIZABLE (downloads open with no warning).
#   - self-signed / ad-hoc     -> plain signature (local use; downloads warn).
#
# The bundle's main executable is the real Mach-O (CFBundleExecutable=ScrollWM).
# It decides what to do from how it was launched: a bare launch as an .app runs
# the production menu-bar agent; subcommands (status/arrange/probe/...) still
# work for the `scrollwm` CLI and the lab harness (see Sources/.../main.swift).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=signing-lib.sh
source "$REPO_DIR/scripts/signing-lib.sh"

APP="${1:?usage: make-bundle.sh <app-path> <binary-path> [sign-id] [version]}"
BIN="${2:?missing binary path}"
SIGN_ID="${3:-}"
VERSION="${4:-0.0.0-dev}"
BUNDLE_ID="dev.scrollwm.app"

# Auto-detect the identity when the caller did not pin one.
[[ -n "$SIGN_ID" ]] || SIGN_ID="$(scrollwm_detect_identity)"

ICON_SRC="$REPO_DIR/Resources/AppIcon.icns"
ENTITLEMENTS="$REPO_DIR/Resources/ScrollWM.entitlements"

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

# The Mach-O IS the bundle's main executable (CFBundleExecutable). No shell
# wrapper: a script main-executable cannot carry a hardened-runtime signature
# and breaks notarization. The binary itself defaults to `run` when launched as
# an .app and otherwise dispatches subcommands, so the `scrollwm` CLI symlink
# (install.sh / the cask) points straight at this file.
cp "$BIN" "$APP/Contents/MacOS/ScrollWM"
chmod +x "$APP/Contents/MacOS/ScrollWM"

# Signing. A Developer ID identity gets the hardened runtime + entitlements +
# secure timestamp (all required for notarization). Self-signed/ad-hoc get a
# plain signature: enough for local use, but Gatekeeper still warns on download.
SIGN_FLAGS=(--force --sign "$SIGN_ID" --identifier "$BUNDLE_ID")
if scrollwm_is_developer_id "$SIGN_ID"; then
    SIGN_FLAGS+=(--options runtime --timestamp)
    [[ -f "$ENTITLEMENTS" ]] && SIGN_FLAGS+=(--entitlements "$ENTITLEMENTS")
    echo "make-bundle: signing with Developer ID (hardened runtime, notarizable)"
fi

# Sign inner Mach-O first, then the bundle.
codesign "${SIGN_FLAGS[@]}" "$APP/Contents/MacOS/ScrollWM"
codesign "${SIGN_FLAGS[@]}" "$APP"

codesign --verify --deep --strict "$APP"
# For Developer ID builds, confirm the runtime flag actually stuck (catches a
# silently-dropped hardened runtime before it fails at the notary service).
if scrollwm_is_developer_id "$SIGN_ID"; then
    if codesign -d --verbose=2 "$APP" 2>&1 | grep -q "flags=.*runtime"; then
        echo "make-bundle: hardened runtime confirmed"
    else
        echo "make-bundle: WARNING - hardened runtime flag not present after signing" >&2
    fi
fi
echo "make-bundle: wrote $APP (version $VERSION, sign '$SIGN_ID')"
echo "make-bundle: $(scrollwm_identity_note "$SIGN_ID")"
