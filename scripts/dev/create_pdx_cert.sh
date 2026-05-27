#!/usr/bin/env bash
# Run ONCE per build machine to create a stable self-signed code-signing identity.
# After running this, sign PDX builds with --sign "MacParakeet PDX" instead of --sign -.
# The same cert across builds gives TCC a stable identity so permissions survive
# drag-replace app updates.
#
# Trust on the build machine is NOT required for TCC stability — TCC on the
# target Mac reads the certificate embedded in the signed binary.  The only
# thing full trust would enable is codesign --verify --deep --strict passing
# without warnings, which is cosmetic for an ad-hoc personal build.
#
# If you want to manually trust the cert (removes the "untrusted" warning in
# Keychain Access), open Keychain Access → login → find "MacParakeet PDX" →
# double-click → Trust → Code Signing → Always Trust.
#
# TROUBLESHOOTING — "no identity found" after running this script:
# The login keychain may be missing from codesign's session search list
# (seen on macOS 15; security list-keychains shows only System.keychain).
# Fix: export the identity from Keychain Access as a .p12, then import it
# into System.keychain:
#   Keychain Access → login → Certificates → right-click MacParakeet PDX
#     → Export → save as Certificates.p12 (set a password)
#   sudo security import ~/Desktop/Certificates.p12 \
#     -k /Library/Keychains/System.keychain -P "yourpassword" \
#     -T /usr/bin/codesign -A
# After that, run grant_codesign_key_access.sh with your keychain password
# and codesign --sign "MacParakeet PDX" will work.
set -euo pipefail

CERT_NAME="MacParakeet PDX"
KEYCHAIN=~/Library/Keychains/login.keychain-db
TMPDIR_LOCAL=$(mktemp -d)
trap 'rm -rf "$TMPDIR_LOCAL"' EXIT

if security find-certificate -c "$CERT_NAME" "$KEYCHAIN" &>/dev/null; then
  echo "✓ '$CERT_NAME' already exists in login keychain. Nothing to do."
  exit 0
fi

echo "Creating self-signed certificate '$CERT_NAME'…"
echo "Enter your login keychain password when prompted:"
security unlock-keychain "$KEYCHAIN"

KEY="$TMPDIR_LOCAL/key.pem"
CERT="$TMPDIR_LOCAL/cert.pem"
CNF="$TMPDIR_LOCAL/codesign.cnf"

openssl genrsa -out "$KEY" 2048 2>/dev/null

# Code-signing extensions required for the cert to embed as a codesign identity
cat > "$CNF" << EOF
[req]
distinguished_name = req_dn
x509_extensions = v3_codesign
prompt = no

[req_dn]
CN = $CERT_NAME

[v3_codesign]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
basicConstraints = CA:FALSE
EOF

openssl req -new -x509 \
  -key "$KEY" \
  -out "$CERT" \
  -days 3650 \
  -config "$CNF" \
  2>/dev/null

# Import private key
security import "$KEY" \
  -k "$KEYCHAIN" \
  -T /usr/bin/codesign \
  -A

# Import certificate
security import "$CERT" \
  -k "$KEYCHAIN" \
  -T /usr/bin/codesign \
  -A

# Grant codesign access to the key without per-use prompts.
# Pass empty string for keychain password if your login keychain has none;
# if this fails, codesign will show a one-time Allow dialog on first use.
security set-key-partition-list \
  -S apple-tool:,apple: \
  -s \
  -k "" \
  "$KEYCHAIN" 2>/dev/null || true

echo "✓ Certificate '$CERT_NAME' created. Sign future PDX builds with:"
echo "  codesign --force --sign \"$CERT_NAME\" \"\$APP\""
echo ""
echo "NOTE: The cert is not marked as trusted in Keychain Access (macOS 15 blocks"
echo "scripted trust). This is fine for TCC identity stability — TCC reads the cert"
echo "embedded in the binary. To silence Keychain Access warnings, open it manually:"
echo "  login keychain → MacParakeet PDX → double-click → Trust → Code Signing → Always Trust"
