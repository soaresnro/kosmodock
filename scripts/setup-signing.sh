#!/usr/bin/env bash
# Creates a self-signed code-signing identity for local Kosmodock builds.
#
# macOS keys privacy grants (Accessibility) to an app's code identity. Ad-hoc
# signatures change with every build, so the grant is lost on each rebuild.
# Signing with a stable certificate keeps the identity — and the grant — fixed.
#
#   bash scripts/setup-signing.sh          # create (idempotent)
#   bash scripts/setup-signing.sh --remove # delete the identity again
set -euo pipefail

IDENTITY="${SIGN_IDENTITY_NAME:-Kosmodock Local Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if [[ "${1:-}" == "--remove" ]]; then
    security delete-identity -c "$IDENTITY" "$KEYCHAIN" && echo "✓ Removed \"$IDENTITY\""
    exit 0
fi

if security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "✓ \"$IDENTITY\" already exists"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

# The system LibreSSL writes PKCS#12 files that `security import` accepts.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cnf" 2>/dev/null
PASSWORD="$(uuidgen)"
/usr/bin/openssl pkcs12 -export -name "$IDENTITY" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$WORK/identity.p12" -passout "pass:$PASSWORD"

# -T pre-authorises codesign to use the private key without a keychain prompt.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null

echo "✓ Created \"$IDENTITY\" in your login keychain"
echo "  bundle.sh now signs with it automatically."
