#!/bin/bash
# notarize.sh - submit a Developer ID-signed ScrollWM.app to Apple's notary
# service, staple the ticket, and repackage so DOWNLOADS open with no warning.
#
# Prerequisites (one-time):
#   1. A "Developer ID Application" certificate in your keychain
#      (Xcode > Settings > Accounts > Manage Certificates > + ).
#      Verify: security find-identity -v -p codesigning | grep "Developer ID"
#   2. Stored notary credentials in your keychain under a profile name. Create
#      with an app-specific password (https://account.apple.com > App-Specific
#      Passwords) OR an App Store Connect API key:
#        xcrun notarytool store-credentials scrollwm-notary \
#          --apple-id "you@example.com" --team-id "ABCDE12345" \
#          --password "abcd-efgh-ijkl-mnop"
#      Then this script just works. Override the profile name with
#      SCROLLWM_NOTARY_PROFILE=...
#
# Flow:
#   build + Developer ID sign  (scripts/package-release.sh, if dist/ is empty)
#     -> submit dist/ScrollWM-<ver>.zip to notarytool --wait
#     -> staple the ticket onto dist/ScrollWM.app
#     -> REPACKAGE the zip/dmg so they carry the stapled app (offline launch)
#     -> Gatekeeper assessment (spctl) as a final sanity check
#
# Usage:
#   scripts/notarize.sh [version]
#   SCROLLWM_NOTARY_PROFILE=my-profile scripts/notarize.sh 0.1.1
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=signing-lib.sh
source "$REPO_DIR/scripts/signing-lib.sh"
# shellcheck source=package-lib.sh
source "$REPO_DIR/scripts/package-lib.sh"

VERSION="${1:-$(cat "$REPO_DIR/VERSION" 2>/dev/null || echo 0.0.0-dev)}"
PROFILE="${SCROLLWM_NOTARY_PROFILE:-scrollwm-notary}"
DIST="$REPO_DIR/dist"
APP="$DIST/ScrollWM.app"
ZIP="$DIST/ScrollWM-$VERSION.zip"

die() { echo "notarize: $*" >&2; exit 1; }

# --- Preflight checks (fail early with actionable messages) -----------------
command -v xcrun >/dev/null 2>&1 || die "xcrun not found (install Xcode command line tools)."
xcrun --find notarytool >/dev/null 2>&1 || die "notarytool not found (needs Xcode 13+)."

SIGN_ID="$(scrollwm_detect_identity)"
scrollwm_is_developer_id "$SIGN_ID" || die "no 'Developer ID Application' certificate found.
  Notarization REQUIRES an Apple Developer ID cert. Install one via
  Xcode > Settings > Accounts > Manage Certificates > + Developer ID Application,
  then re-run. (Detected identity: '$SIGN_ID')"

# Confirm stored notary credentials exist for the profile.
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    die "no stored notary credentials for profile '$PROFILE'.
  Create them once with:
    xcrun notarytool store-credentials $PROFILE \\
      --apple-id \"you@example.com\" --team-id \"YOURTEAMID\" \\
      --password \"app-specific-password\"
  (or pass --key/--key-id/--issuer for an App Store Connect API key), then re-run.
  Override the profile name with SCROLLWM_NOTARY_PROFILE=..."
fi

# --- Build + Developer ID sign if there is no fresh bundle ------------------
if [[ ! -d "$APP" || ! -f "$ZIP" ]]; then
    echo "==> no dist/ bundle for $VERSION; building + signing first"
    "$REPO_DIR/scripts/package-release.sh" "$VERSION"
fi
[[ -d "$APP" ]] || die "expected $APP after packaging."
[[ -f "$ZIP" ]] || die "expected $ZIP after packaging."

# Re-verify the bundle really is hardened-runtime signed before we waste a
# round-trip to Apple (the notary service rejects non-hardened submissions).
codesign -d --verbose=2 "$APP" 2>&1 | grep -q "flags=.*runtime" \
    || die "bundle is not hardened-runtime signed; rebuild with the Developer ID cert."

# --- Submit + wait ----------------------------------------------------------
echo "==> submitting $(basename "$ZIP") to Apple notary service (profile '$PROFILE')..."
echo "    this can take a few minutes; --wait blocks until Apple finishes."
if ! xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait; then
    echo "notarize: submission FAILED. Inspect the log with:" >&2
    echo "  xcrun notarytool history --keychain-profile $PROFILE" >&2
    echo "  xcrun notarytool log <submission-id> --keychain-profile $PROFILE" >&2
    exit 1
fi

# --- Staple + repackage -----------------------------------------------------
echo "==> stapling the notarization ticket onto $(basename "$APP")"
xcrun stapler staple "$APP" || die "stapler failed (ticket may not be ready yet)."

echo "==> repackaging zip/dmg with the stapled bundle"
scrollwm_package_artifacts "$DIST" "$APP" "$VERSION"

# Staple the dmg too so the disk image itself is self-contained offline.
xcrun stapler staple "$DIST/ScrollWM-$VERSION.dmg" 2>/dev/null \
    && echo "    dmg stapled" || echo "    (dmg staple skipped)"

# --- Final Gatekeeper assessment -------------------------------------------
echo "==> Gatekeeper assessment (spctl)"
if spctl --assess --type execute --verbose=2 "$APP" 2>&1 | grep -q "accepted"; then
    echo "    Gatekeeper: ACCEPTED (notarized + stapled)"
else
    echo "    Gatekeeper: NOT accepted - check 'spctl --assess --verbose=4 $APP'" >&2
fi
xcrun stapler validate "$APP" >/dev/null 2>&1 \
    && echo "    staple validated" || echo "    staple validation reported an issue" >&2

cat <<DONE

Notarized + stapled: $APP (v$VERSION)
Published-ready artifacts (open with NO Gatekeeper warning):
  $ZIP
  $DIST/ScrollWM-$VERSION.dmg
  $DIST/SHA256SUMS.txt

Next:
  - Update the Homebrew cask sha256 to the notarized zip:
      scripts/update-cask.sh $VERSION
  - Upload the artifacts to the GitHub release for v$VERSION.
DONE
