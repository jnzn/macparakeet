#!/usr/bin/env bash
# One-time cleanup: remove all "MacParakeet PDX" certs from login keychain.
# Run this before re-running create_pdx_cert.sh if you had failed attempts.
set -euo pipefail

CERT_NAME="MacParakeet PDX"
KEYCHAIN=~/Library/Keychains/login.keychain-db

hashes=$(security find-certificate -a -c "$CERT_NAME" -Z "$KEYCHAIN" 2>/dev/null \
  | awk '/SHA-1/{print $3}')

if [[ -z "$hashes" ]]; then
  echo "No '$CERT_NAME' certificates found. Nothing to do."
  exit 0
fi

while IFS= read -r hash; do
  security delete-certificate -Z "$hash" "$KEYCHAIN" \
    && echo "Deleted cert $hash"
done <<< "$hashes"

echo ""
echo "Done. Now open Keychain Access → login → search '$CERT_NAME'"
echo "and delete any remaining key (lock icon) entries manually."
echo "Then run: scripts/dev/create_pdx_cert.sh"
