#!/bin/bash
# package-release.sh - build a universal ScrollWM.app and package it for release.
#
# Produces, under dist/:
#   ScrollWM.app                  universal (arm64 + x86_64) bundle
#   ScrollWM-<version>.zip        ditto zip of the bundle (for curl installer/brew)
#   ScrollWM-<version>.dmg        drag-to-Applications disk image
#   SHA256SUMS.txt                checksums for the artifacts
#
# Signing is ad-hoc by default (no Apple account required). Downloaded ad-hoc
# apps are quarantined by Gatekeeper; the curl installer and README explain the
# one-time right-click-Open / xattr step.
#
# Usage: scripts/package-release.sh [version]
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-$(cat "$REPO_DIR/VERSION" 2>/dev/null || echo 0.0.0-dev)}"
DIST="$REPO_DIR/dist"
APP="$DIST/ScrollWM.app"

cd "$REPO_DIR"
rm -rf "$DIST"
mkdir -p "$DIST"

echo "==> building universal release binary (arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64 2>&1 | tail -1
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/WindowLab"
[[ -x "$BIN" ]] || { echo "build failed: $BIN missing"; exit 1; }
echo "    $(lipo -archs "$BIN" 2>/dev/null || echo arm64)"

echo "==> assembling bundle (ad-hoc signed)"
"$REPO_DIR/scripts/make-bundle.sh" "$APP" "$BIN" "-" "$VERSION"

ZIP="$DIST/ScrollWM-$VERSION.zip"
echo "==> zipping -> $(basename "$ZIP")"
# ditto preserves the bundle's signature/metadata correctly (unlike plain zip).
( cd "$DIST" && ditto -c -k --sequesterRsrc --keepParent "ScrollWM.app" "$ZIP" )

DMG="$DIST/ScrollWM-$VERSION.dmg"
echo "==> building dmg -> $(basename "$DMG")"
DMG_STAGE="$(mktemp -d)"
trap 'rm -rf "$DMG_STAGE"' EXIT
cp -R "$APP" "$DMG_STAGE/ScrollWM.app"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -volname "ScrollWM" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG" >/dev/null
echo "    wrote $(basename "$DMG")"

echo "==> checksums"
( cd "$DIST" && shasum -a 256 "ScrollWM-$VERSION.zip" "ScrollWM-$VERSION.dmg" | tee SHA256SUMS.txt )

echo
echo "Release artifacts in: $DIST"
ls -la "$DIST"
