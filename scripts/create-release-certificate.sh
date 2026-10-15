#!/usr/bin/env bash
# Creates the self-signed certificate that the release workflow signs with,
# and stores it as GitHub Actions secrets.
#
# macOS keys the Accessibility grant to the app's designated requirement. Signed
# with this certificate it is `identifier "dev.kosmodock.Kosmodock" and
# certificate leaf = H"<SHA-1 of the certificate>"`, the same for every release,
# so users keep the permission when they update. It doesn't notarize the app:
# Gatekeeper still asks once per downloaded version.
#
#   bash scripts/create-release-certificate.sh           # create (refuses to replace one)
#   bash scripts/create-release-certificate.sh --rotate  # replace it: every user grants Accessibility again
#
# Sets the MACOS_SELF_SIGNED_P12 and MACOS_SELF_SIGNED_P12_PASSWORD secrets,
# keeps the identity in your login keychain as the backup, and writes the
# certificate's SHA-1 to .github/release-signing-certificate.sha1. The workflow
# refuses to publish a build signed with any other certificate. Commit that file.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAME="Kosmodock Release Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
PIN="$ROOT/.github/release-signing-certificate.sha1"
ROTATE=false
[[ "${1:-}" == "--rotate" ]] && ROTATE=true
REPO="${REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"

if ! $ROTATE; then
    if gh secret list --repo "$REPO" --json name -q '.[].name' | grep -qx MACOS_SELF_SIGNED_P12; then
        echo "✗ $REPO already has a release certificate (MACOS_SELF_SIGNED_P12)."
        echo "  A new one changes the app's identity, and every user has to grant Accessibility again."
        echo "  If that's intended, run again with --rotate."
        exit 1
    fi
    if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
        echo "✗ Your login keychain already has \"$NAME\" but $REPO has no secret for it."
        echo "  Delete it first: security delete-identity -c \"$NAME\" \"$KEYCHAIN\""
        exit 1
    fi
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

# 20 years: replacing the certificate costs every user a new Accessibility grant.
/usr/bin/openssl req -x509 -newkey rsa:3072 -nodes -days 7300 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cnf" 2>/dev/null
PASSWORD="$(uuidgen)"
/usr/bin/openssl pkcs12 -export -name "$NAME" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$WORK/identity.p12" -passout "pass:$PASSWORD"
SHA1="$(/usr/bin/openssl x509 -in "$WORK/cert.pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g' | tr 'A-F' 'a-f')"

# Secrets go through stdin so they never appear in a process list.
base64 -i "$WORK/identity.p12" | gh secret set MACOS_SELF_SIGNED_P12 --repo "$REPO"
printf '%s' "$PASSWORD" | gh secret set MACOS_SELF_SIGNED_P12_PASSWORD --repo "$REPO"
echo "$SHA1" > "$PIN"

if $ROTATE; then
    security delete-identity -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1 || true
fi
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null

echo "✓ Created \"$NAME\" and stored it in $REPO's Actions secrets"
echo "  Designated requirement: identifier \"dev.kosmodock.Kosmodock\" and certificate leaf = H\"$SHA1\""
echo "  Backup: your login keychain (Keychain Access → My Certificates → $NAME → Export)."
echo "  Commit .github/release-signing-certificate.sha1 so the release workflow accepts it."
