#!/bin/bash
# Generate Resources/AppIcon.icns from scripts/make-icon.swift.
#
# Produces every size macOS needs (16..1024, @1x and @2x), packs them into an
# .iconset, and runs iconutil to emit a single .icns. Re-run this only when the
# icon design (make-icon.swift) changes; the resulting .icns is committed so the
# normal build/install path and CI need no Swift-at-build-time icon step.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RENDER="$REPO_DIR/scripts/make-icon.swift"
RES_DIR="$REPO_DIR/Resources"
ICNS="$RES_DIR/AppIcon.icns"
PREVIEW="$RES_DIR/icon-preview.png"

mkdir -p "$RES_DIR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"

echo "==> rendering icon sizes"
# name                pixels
gen() { swift "$RENDER" "$2" "$ICONSET/$1"; }
gen icon_16x16.png        16
gen icon_16x16@2x.png     32
gen icon_32x32.png        32
gen icon_32x32@2x.png     64
gen icon_128x128.png      128
gen icon_128x128@2x.png   256
gen icon_256x256.png      256
gen icon_256x256@2x.png   512
gen icon_512x512.png      512
gen icon_512x512@2x.png   1024

echo "==> packing .icns"
iconutil -c icns "$ICONSET" -o "$ICNS"
cp "$ICONSET/icon_512x512@2x.png" "$PREVIEW"

echo "    wrote $ICNS"
echo "    wrote $PREVIEW"
