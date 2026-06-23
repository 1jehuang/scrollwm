# shellcheck shell=bash
# signing-lib.sh - shared code-signing helpers, sourced by the other scripts.
#
# ONE place that knows how ScrollWM picks a signing identity, so local installs
# (install.sh), release packaging (package-release.sh), and notarization
# (notarize.sh) all agree.
#
# Identity preference (best first):
#   1. Developer ID Application  - Apple-issued; enables notarization so
#                                  DOWNLOADED copies open with no Gatekeeper
#                                  warning. Also a stable identity, so the local
#                                  Accessibility grant persists across rebuilds.
#   2. ScrollWM Self-Signed      - local-only stable identity (setup-signing.sh);
#                                  keeps Accessibility across rebuilds but is NOT
#                                  notarizable (downloads still warn).
#   3. ad-hoc ("-")              - no identity; fine for local dev, re-grant
#                                  Accessibility on each rebuild, downloads warn.
#
# This file only DEFINES functions; sourcing it has no side effects.

# Print the best available code-signing identity's common-name (or "-" for
# ad-hoc) on stdout. Honors an explicit override via $SCROLLWM_SIGN_ID.
scrollwm_detect_identity() {
    if [[ -n "${SCROLLWM_SIGN_ID:-}" ]]; then
        printf '%s' "$SCROLLWM_SIGN_ID"
        return 0
    fi
    local ids
    ids="$(security find-identity -v -p codesigning 2>/dev/null)"
    if grep -q "Developer ID Application" <<<"$ids"; then
        # Extract the full CN of the first Developer ID Application identity.
        sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' <<<"$ids" | head -1
        return 0
    fi
    if grep -q "ScrollWM Self-Signed" <<<"$ids"; then
        printf 'ScrollWM Self-Signed'
        return 0
    fi
    printf '%s' '-'
}

# True (0) when the given identity is an Apple Developer ID Application cert,
# i.e. one that can be notarized and gets hardened-runtime signing.
scrollwm_is_developer_id() {
    [[ "${1:-}" == "Developer ID Application"* ]]
}

# A short human note describing what an identity means for the user.
scrollwm_identity_note() {
    local id="$1"
    if scrollwm_is_developer_id "$id"; then
        printf 'Developer ID (hardened runtime; notarizable; Accessibility persists)'
    elif [[ "$id" == "-" ]]; then
        printf 'ad-hoc (Accessibility may need re-granting after updates; downloads warn)'
    else
        printf 'stable self-signed (Accessibility persists; downloads still warn)'
    fi
}
