#!/usr/bin/env bash
# Run ONCE per build machine to create a stable self-signed code-signing identity.
# After running this, sign PDX builds with --sign "MacParakeet PDX" instead of --sign -.
# The same cert across builds gives TCC a stable identity so permissions survive
# drag-replace app updates.
set -euo pipefail

CERT_NAME="MacParakeet PDX"
KEYCHAIN=~/Library/Keychains/login.keychain-db
TMPDIR_LOCAL=$(mktemp -d)
trap 'rm -rf "$TMPDIR_LOCAL"' EXIT

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "\"$CERT_NAME\""; then
  echo "✓ '$CERT_NAME' already exists in login keychain. Nothing to do."
  exit 0
fi

echo "Creating self-signed certificate '$CERT_NAME'…"

KEY="$TMPDIR_LOCAL/key.pem"
CERT="$TMPDIR_LOCAL/cert.pem"
P12="$TMPDIR_LOCAL/cert.p12"

openssl genrsa -out "$KEY" 2048 2>/dev/null

openssl req -new -x509 \
  -key "$KEY" \
  -out "$CERT" \
  -days 3650 \
  -subj "/CN=$CERT_NAME" \
  2>/dev/null

openssl pkcs12 -export \
  -inkey "$KEY" \
  -in "$CERT" \
  -out "$P12" \
  -passout pass: \
  2>/dev/null

security import "$P12" \
  -k "$KEYCHAIN" \
  -P "" \
  -T /usr/bin/codesign \
  -A

security add-trusted-cert \
  -d \
  -r trustAsRoot \
  -k "$KEYCHAIN" \
  "$CERT"

echo "✓ Certificate '$CERT_NAME' created and trusted. Sign future PDX builds with:"
echo "  codesign --force --sign \"$CERT_NAME\" \"\$APP\""
