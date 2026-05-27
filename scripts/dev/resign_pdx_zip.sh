#!/usr/bin/env bash
# Re-sign the PDX Edition zip with the stable "MacParakeet PDX" identity.
# Run after create_pdx_cert.sh succeeds.
set -euo pipefail

ZIP=~/Desktop/MacParakeet-PDX-Edition-0.7.2.zip
WORK=/tmp/mp-pdx-resign
IDENTITY="MacParakeet PDX"

rm -rf "$WORK" && mkdir "$WORK"
ditto -x -k "$ZIP" "$WORK"

APP="$WORK/MacParakeet (PDX Edition).app"
xattr -cr "$APP"

find "$APP/Contents/Resources" -maxdepth 1 -type f -perm -111 -print0 \
  | while IFS= read -r -d '' h; do
      codesign --force --sign "$IDENTITY" "$h"
    done

codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --deep --verbose=2 "$APP"

ditto -c -k --keepParent --sequesterRsrc "$APP" "$ZIP"

echo "✓ Re-signed and zipped: $ZIP"
