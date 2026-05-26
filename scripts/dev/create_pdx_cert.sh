#!/usr/bin/env bash
# Run ONCE per build machine to create a stable self-signed code-signing identity.
# After running this, sign PDX builds with --sign "MacParakeet PDX" instead of --sign -.
# The same cert across builds gives TCC a stable identity so permissions survive
# drag-replace app updates.
#
# NOTE: macOS will show a keychain password dialog when importing the private key.
# That is expected — it is asking permission to store the key in your login keychain.
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
echo "Enter your login keychain password when prompted:"
security unlock-keychain "$KEYCHAIN"

KEY="$TMPDIR_LOCAL/key.pem"
CERT="$TMPDIR_LOCAL/cert.pem"

openssl genrsa -out "$KEY" 2048 2>/dev/null

openssl req -new -x509 \
  -key "$KEY" \
  -out "$CERT" \
  -days 3650 \
  -subj "/CN=$CERT_NAME" \
  2>/dev/null

# Import private key — macOS shows a keychain password prompt here
security import "$KEY" \
  -k "$KEYCHAIN" \
  -T /usr/bin/codesign \
  -A

# Import certificate
security import "$CERT" \
  -k "$KEYCHAIN" \
  -T /usr/bin/codesign \
  -A

# Trust the certificate for code signing
security add-trusted-cert \
  -r trustAsRoot \
  -k "$KEYCHAIN" \
  "$CERT"

echo "✓ Certificate '$CERT_NAME' created and trusted. Sign future PDX builds with:"
echo "  codesign --force --sign \"$CERT_NAME\" \"\$APP\""
