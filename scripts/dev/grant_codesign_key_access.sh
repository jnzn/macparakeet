#!/usr/bin/env bash
# Grant codesign access to the MacParakeet PDX key in login keychain.
# Run once after create_pdx_cert.sh if codesign says "no identity found".
# Requires your login keychain password (same as macOS login password).
set -euo pipefail

KEYCHAIN=~/Library/Keychains/login.keychain-db

read -rsp "Login keychain password: " KP
echo

security set-key-partition-list \
  -S apple-tool:,apple: \
  -s \
  -k "$KP" \
  "$KEYCHAIN"

echo "✓ Key access granted. Test with:"
echo "  cp /bin/ls /tmp/test_sign && codesign --force --sign \"MacParakeet PDX\" /tmp/test_sign && echo SUCCESS"
