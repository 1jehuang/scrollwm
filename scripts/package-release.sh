#!/bin/bash
# package-release.sh - build a universal ScrollWM.app and package it for release.
#
# Produces, under dist/:
#   ScrollWM.app                  universal (arm64 + x86_64) bundle
#   ScrollWM-<version>.zip        ditto zip of the bundle (for curl installer/brew)
#   ScrollWM-<version>.dmg        drag-to-Applications disk image
#   SHA256SUMS.txt                checksums for the artifacts
#
# Signing identity is auto-detected (Developer ID > self-signed > ad-hoc; see
# scripts/signing-lib.sh) or pinned via SCROLLWM_SIGN_ID. With a Developer ID
# identity the bundle is hardened-runtime signed and ready for notarization:
# run scripts/notarize.sh afterward to submit + staple, then the zip/dmg open
# with no Gatekeeper warning. Ad-hoc/self-signed downloads are quarantined; the
# curl installer and README explain the one-time right-click-Open / xattr step.
#
# Usage: scripts/package-release.sh [version]
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=signing-lib.sh
source "$REPO_DIR/scripts/signing-lib.sh"
# shellcheck source=package-lib.sh
source "$REPO_DIR/scripts/package-lib.sh"

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

SIGN_ID="$(scrollwm_detect_identity)"
echo "==> assembling bundle ($(scrollwm_identity_note "$SIGN_ID"))"
"$REPO_DIR/scripts/make-bundle.sh" "$APP" "$BIN" "$SIGN_ID" "$VERSION"

scrollwm_package_artifacts "$DIST" "$APP" "$VERSION"

echo
echo "Release artifacts in: $DIST"
ls -la "$DIST"

if scrollwm_is_developer_id "$SIGN_ID"; then
    cat <<NEXT

Next step (Developer ID build): notarize so downloads open with no warning:
  scripts/notarize.sh $VERSION
NEXT
else
    cat <<NEXT

Note: this build is $(scrollwm_identity_note "$SIGN_ID").
To ship downloads with no Gatekeeper warning, install a "Developer ID
Application" certificate (Xcode > Settings > Accounts > Manage Certificates),
re-run this script, then scripts/notarize.sh $VERSION.
NEXT
fi
