#!/bin/bash
# Create a persistent, self-signed code-signing identity for ScrollWM, once.
#
# WHY: the default install uses an ad-hoc signature (codesign --sign -). Ad-hoc
# signatures have no stable identity, so every rebuild looks like a brand-new
# app to macOS and your Accessibility grant is dropped. Signing with a stable
# self-signed certificate keeps the app's designated requirement constant
# across rebuilds, so the Accessibility permission sticks through updates.
#
# This creates a local self-signed cert in your login keychain. It is NOT an
# Apple Developer ID (so no Gatekeeper/notarization), but for a locally built
# personal tool that is exactly what we want: stable identity, no Apple account.
#
# Run once:
#   ./scripts/setup-signing.sh
# Then install/update as usual; install.sh will auto-detect and use it.
set -euo pipefail

CERT_NAME="ScrollWM Self-Signed"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "Signing identity already exists: \"$CERT_NAME\""
    echo "install.sh will use it automatically."
    exit 0
fi

echo "==> creating self-signed code-signing certificate: \"$CERT_NAME\""
echo "    (you may be prompted to allow keychain access)"

TMPDIR_CERT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_CERT"' EXIT
CONFIG="$TMPDIR_CERT/cert.conf"

# A code-signing-capable self-signed cert. The codeSigning EKU is what lets
# codesign use it; basicConstraints CA:false keeps it a leaf identity.
cat > "$CONFIG" <<EOF
[ req ]
distinguished_name = dn
prompt = no
x509_extensions = v3

[ dn ]
CN = $CERT_NAME

[ v3 ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

KEY="$TMPDIR_CERT/key.pem"
CRT="$TMPDIR_CERT/cert.pem"
P12="$TMPDIR_CERT/identity.p12"
P12_PASS="scrollwm"

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$KEY" -out "$CRT" -days 3650 \
    -config "$CONFIG" >/dev/null 2>&1

openssl pkcs12 -export -inkey "$KEY" -in "$CRT" \
    -out "$P12" -passout "pass:$P12_PASS" >/dev/null 2>&1

# Import into the login keychain and allow codesign to use it without prompting.
security import "$P12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P "$P12_PASS" -T /usr/bin/codesign >/dev/null 2>&1 || \
security import "$P12" -P "$P12_PASS" -T /usr/bin/codesign >/dev/null 2>&1

# Trust the cert for code signing so codesign accepts it without warnings.
security add-trusted-cert -d -r trustRoot \
    -p codeSign -k "$HOME/Library/Keychains/login.keychain-db" "$CRT" >/dev/null 2>&1 || \
security add-trusted-cert -r trustRoot -p codeSign "$CRT" >/dev/null 2>&1 || true

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "==> done. Identity \"$CERT_NAME\" is ready."
    echo "    Now run ./scripts/install.sh (or scripts/update.sh) once. After"
    echo "    granting Accessibility this time, future updates keep it."
else
    echo "WARNING: identity not found after import. The install will fall back"
    echo "to ad-hoc signing (permission may need re-granting on each update)."
    exit 1
fi
