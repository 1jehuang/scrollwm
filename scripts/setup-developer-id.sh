#!/bin/bash
# setup-developer-id.sh - guided ONE-TIME setup for notarized distribution.
#
# Walks you through the only steps that need your Apple ID (so they can't be
# fully automated), validates each one, and optionally pushes the GitHub Actions
# secrets so CI can notarize on a tag too.
#
# Run it interactively:
#   ./scripts/setup-developer-id.sh
#
# It is idempotent: re-run anytime; already-done steps are detected and skipped.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=signing-lib.sh
source "$REPO_DIR/scripts/signing-lib.sh"

PROFILE="${SCROLLWM_NOTARY_PROFILE:-scrollwm-notary}"
bold() { printf '\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
todo() { printf '  \033[33m●\033[0m %s\n' "$1"; }
ask()  { local p="$1" v; read -r -p "$p" v; printf '%s' "$v"; }

echo
bold "ScrollWM notarization setup"
echo "This configures the bits that need your Apple Developer account."
echo

# ---------------------------------------------------------------------------
# Step 1: Developer ID Application certificate
# ---------------------------------------------------------------------------
bold "1. Developer ID Application certificate"
SIGN_ID="$(scrollwm_detect_identity)"
if scrollwm_is_developer_id "$SIGN_ID"; then
    ok "found: $SIGN_ID"
else
    todo "no 'Developer ID Application' certificate in your keychain."
    cat <<INSTR

    Create one (needs your Apple ID + 2FA - I cannot do this part):
      a. Open Xcode > Settings (Cmd+,) > Accounts.
      b. Add your Apple ID if it is not listed, select your Team.
      c. Click "Manage Certificates..." > the + button (bottom-left) >
         "Developer ID Application".
      d. It installs into your login keychain automatically.

    No Xcode? Create the cert at https://developer.apple.com/account >
    Certificates > + > "Developer ID Application", download the .cer, and
    double-click it to add it to Keychain Access.

INSTR
    if [[ "$(ask "    Open Xcode Accounts settings now? [y/N] ")" =~ ^[Yy] ]]; then
        open -b com.apple.dt.Xcode 2>/dev/null || open -a Xcode 2>/dev/null || true
        echo "    (In Xcode: Settings > Accounts > Manage Certificates > + )"
    fi
    echo
    echo "    Re-run this script once the certificate is installed."
    exit 1
fi
echo

# ---------------------------------------------------------------------------
# Step 2: Notary credentials (stored in your keychain)
# ---------------------------------------------------------------------------
bold "2. Notary credentials (keychain profile '$PROFILE')"
if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    ok "profile '$PROFILE' already stored"
    APPLE_ID=""; TEAM_ID=""; APP_PW=""
else
    todo "no notary profile '$PROFILE' yet."
    cat <<INSTR

    You need an APP-SPECIFIC PASSWORD (not your normal Apple password):
      a. Go to https://account.apple.com > Sign-In and Security >
         App-Specific Passwords > +  (name it e.g. "scrollwm-notary").
      b. Copy the generated abcd-efgh-ijkl-mnop password.
    And your 10-character Team ID (https://developer.apple.com/account >
    Membership details).

INSTR
    APPLE_ID="$(ask "    Apple ID email: ")"
    TEAM_ID="$(ask "    Team ID (10 chars): ")"
    APP_PW="$(ask "    App-specific password: ")"
    echo "    Storing credentials in your keychain..."
    if xcrun notarytool store-credentials "$PROFILE" \
        --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PW"; then
        ok "stored profile '$PROFILE'"
    else
        echo "    notarytool store-credentials failed; check the values and re-run." >&2
        exit 1
    fi
fi
echo

# ---------------------------------------------------------------------------
# Step 3 (optional): GitHub Actions secrets so CI notarizes on a tag
# ---------------------------------------------------------------------------
bold "3. GitHub Actions secrets (optional - only for CI-driven releases)"
if ! command -v gh >/dev/null 2>&1; then
    todo "GitHub CLI (gh) not installed; skipping. Local releases still work."
elif ! gh auth status >/dev/null 2>&1; then
    todo "gh not authenticated (run 'gh auth login'); skipping CI secrets."
else
    echo "    CI can notarize automatically on a 'v*' tag if these 5 secrets exist."
    if [[ "$(ask "    Push them to GitHub now? (needs your exported .p12) [y/N] ")" =~ ^[Yy] ]]; then
        P12_PATH="$(ask "    Path to your exported Developer ID .p12: ")"
        P12_PATH="${P12_PATH/#\~/$HOME}"
        if [[ ! -f "$P12_PATH" ]]; then
            echo "    file not found: $P12_PATH (export it from Keychain Access:" >&2
            echo "    right-click the Developer ID identity > Export...) - skipping." >&2
        else
            P12_PW="$(ask "    Password for that .p12: ")"
            # Reuse step-2 answers if we just collected them; else prompt.
            [[ -n "${APPLE_ID:-}" ]] || APPLE_ID="$(ask "    Apple ID email: ")"
            [[ -n "${TEAM_ID:-}" ]]  || TEAM_ID="$(ask "    Team ID: ")"
            [[ -n "${APP_PW:-}" ]]   || APP_PW="$(ask "    App-specific password: ")"
            echo "    Setting secrets via gh..."
            base64 -i "$P12_PATH" | gh secret set DEVELOPER_ID_CERT_P12
            printf '%s' "$P12_PW"   | gh secret set DEVELOPER_ID_CERT_PASSWORD
            printf '%s' "$APPLE_ID" | gh secret set NOTARY_APPLE_ID
            printf '%s' "$TEAM_ID"  | gh secret set NOTARY_TEAM_ID
            printf '%s' "$APP_PW"   | gh secret set NOTARY_PASSWORD
            ok "pushed 5 secrets; CI will notarize on the next v* tag"
        fi
    else
        echo "    Skipped. You can run this script again later to add them."
    fi
fi
echo

bold "Done."
cat <<NEXT
You can now cut a notarized release locally:
  ./scripts/release.sh 0.1.2        # build + sign + notarize + staple + cask
or, if you pushed the CI secrets, just tag:
  git tag v0.1.2 && git push origin v0.1.2
NEXT
