#!/bin/bash
# release.sh - one command to cut a ScrollWM release.
#
# Does, in order:
#   1. build + sign the universal app and package zip/dmg   (package-release.sh)
#   2. notarize + staple if a Developer ID cert is available (notarize.sh)
#   3. refresh the Homebrew cask sha256                       (update-cask.sh)
#   4. optionally publish a GitHub Release with the artifacts (gh, if available)
#
# It degrades gracefully: with no Developer ID cert it still produces an ad-hoc
# build (step 2 skipped, cask keeps the quarantine workaround). Nothing here
# touches your live windows.
#
# NOTE: the in-app updater (Sources/WindowLab/Updater.swift) consumes the
# uploaded `ScrollWM-<ver>.zip` + `SHA256SUMS.txt` from each `v<ver>` Release to
# self-update installed apps. Keep both assets in the publish step below, or
# installed users stop receiving updates.
#
# IMPORTANT for seamless auto-update: sign releases with a STABLE identity
# (Developer ID, or at minimum a reused self-signed cert). macOS ties the
# Accessibility grant to the app's code signature, so an ad-hoc release (new
# cdhash every build) makes the updater unable to install silently: it detects
# that the grant would reset and asks the user to re-enable Accessibility once
# instead (it never silently breaks the window manager). A Developer ID build
# updates with zero user interaction. See docs/SIGNING.md.
#
# Usage:
#   ./scripts/release.sh [version] [--publish]
#     version    defaults to the VERSION file
#     --publish  create/upload a GitHub Release for vVERSION (needs gh)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=signing-lib.sh
source "$REPO_DIR/scripts/signing-lib.sh"

VERSION=""
PUBLISH=0
for arg in "$@"; do
    case "$arg" in
        --publish) PUBLISH=1 ;;
        *) VERSION="$arg" ;;
    esac
done
VERSION="${VERSION:-$(cat "$REPO_DIR/VERSION" 2>/dev/null || echo 0.0.0-dev)}"
DIST="$REPO_DIR/dist"

bold() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

cd "$REPO_DIR"

bold "1/4  Build + sign + package (v$VERSION)"
"$REPO_DIR/scripts/package-release.sh" "$VERSION"

SIGN_ID="$(scrollwm_detect_identity)"
if scrollwm_is_developer_id "$SIGN_ID"; then
    bold "2/4  Notarize + staple"
    "$REPO_DIR/scripts/notarize.sh" "$VERSION"
else
    bold "2/4  Notarize - SKIPPED"
    echo "    No Developer ID certificate ($(scrollwm_identity_note "$SIGN_ID"))."
    echo "    Run ./scripts/setup-developer-id.sh to enable notarized releases."
fi

bold "3/4  Refresh Homebrew cask"
"$REPO_DIR/scripts/update-cask.sh" "$VERSION"
if ! git diff --quiet -- Casks/scrollwm.rb 2>/dev/null; then
    echo "    Casks/scrollwm.rb changed - commit it:"
    echo "      git add Casks/scrollwm.rb && git commit -m 'cask: ScrollWM v$VERSION'"
fi

bold "4/4  Publish GitHub Release"
if [[ "$PUBLISH" != "1" ]]; then
    echo "    Skipped (pass --publish to upload). Artifacts are in dist/."
elif ! command -v gh >/dev/null 2>&1; then
    echo "    gh not installed; skipping. Upload dist/* to the release manually."
elif ! gh auth status >/dev/null 2>&1; then
    echo "    gh not authenticated ('gh auth login'); skipping."
else
    TAG="v$VERSION"
    echo "    Creating/uploading release $TAG ..."
    if gh release view "$TAG" >/dev/null 2>&1; then
        gh release upload "$TAG" \
            "$DIST/ScrollWM-$VERSION.zip" "$DIST/ScrollWM-$VERSION.dmg" \
            "$DIST/SHA256SUMS.txt" --clobber
    else
        gh release create "$TAG" \
            "$DIST/ScrollWM-$VERSION.zip" "$DIST/ScrollWM-$VERSION.dmg" \
            "$DIST/SHA256SUMS.txt" \
            --title "ScrollWM $TAG" --generate-notes
    fi
    echo "    Published $TAG."
fi

bold "Release v$VERSION ready"
ls -la "$DIST"
