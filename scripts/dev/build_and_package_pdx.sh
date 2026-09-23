#!/usr/bin/env bash
# Build, sign with "MacParakeet PDX", and zip the PDX Edition app.
#
# Uses the canonical scripts/dist/build_app_bundle.sh, which:
#   - builds the app + CLI in Release (xcodebuild)
#   - auto-bundles the Silero VAD model from BundledModels/SileroVAD
#   - bundles the meeting echo-suppression dylibs + model from the local seed
#
# Helper binaries (ffmpeg / yt-dlp / node) are reused from the previous dist
# bundle when present so the build does not re-download ~220 MB each time.
# Signing is inside-out (Frameworks dylibs + nested helpers, then the outer app)
# with the self-signed "MacParakeet PDX" identity — no hardened runtime, local
# distribution only.
#
# Override the version with: VERSION=0.9.2-pdx scripts/dev/build_and_package_pdx.sh
set -euo pipefail

cd "$(dirname "$0")/../.."
ROOT="$(pwd)"

VERSION="${VERSION:-0.9.1-pdx}"
APP_NAME="MacParakeet (PDX Edition)"
BUNDLE_ID="com.macparakeet.pdx"
IDENTITY="MacParakeet PDX"
DERIVED="/tmp/mp-pdx-dist"
HELPERS="/tmp/mp-pdx-helpers"
ECHO_SEED="$HOME/Library/Application Support/MacParakeetPDXBuild/localvqe"
ZIP="$HOME/Desktop/MacParakeet-PDX-Edition-${VERSION}.zip"

SRC="dist/${APP_NAME}.app"

# --- 1. Seed helper cache from the prior bundle before the build wipes dist/.
mkdir -p "$HELPERS"
for h in ffmpeg yt-dlp node; do
  if [[ ! -x "$HELPERS/$h" && -x "$SRC/Contents/Resources/$h" ]]; then
    cp "$SRC/Contents/Resources/$h" "$HELPERS/$h"
    chmod +x "$HELPERS/$h"
    echo "Cached helper: $h"
  fi
done

# --- 2. Validate echo seed assets are present.
for f in liblocalvqe.dylib localvqe-v1.4-aec-200K-f32.gguf; do
  if [[ ! -f "$ECHO_SEED/$f" ]]; then
    echo "Error: missing meeting echo seed asset: $ECHO_SEED/$f" >&2
    exit 1
  fi
done

echo "[1/5] Building $APP_NAME $VERSION (Release, xcodebuild)…"
build_env=(
  "APP_NAME=$APP_NAME"
  "BUNDLE_ID=$BUNDLE_ID"
  "VERSION=$VERSION"
  "XCODE_DERIVED_DATA=$DERIVED"
  "MACPARAKEET_MEETING_ECHO_LIBRARY=$ECHO_SEED/liblocalvqe.dylib"
  "MACPARAKEET_MEETING_ECHO_MODEL=$ECHO_SEED/localvqe-v1.4-aec-200K-f32.gguf"
  "MACPARAKEET_MEETING_ECHO_DYLIB_DIR=$ECHO_SEED"
  "REQUIRE_MEETING_ECHO_ASSETS=1"
)
# Reuse cached helpers when available (skip network).
[[ -x "$HELPERS/ffmpeg" ]] && build_env+=("FFMPEG_PATH=$HELPERS/ffmpeg")
[[ -x "$HELPERS/yt-dlp" ]] && build_env+=("YTDLP_PATH=$HELPERS/yt-dlp")
NODE_REUSE=0
if [[ -x "$HELPERS/node" ]]; then build_env+=("BUNDLE_NODE=0"); NODE_REUSE=1; fi

env "${build_env[@]}" bash scripts/dist/build_app_bundle.sh

# --- 3. Inject reused node (build skipped it when BUNDLE_NODE=0).
if [[ "$NODE_REUSE" == "1" ]]; then
  cp "$HELPERS/node" "$SRC/Contents/Resources/node"
  chmod +x "$SRC/Contents/Resources/node"
  echo "Injected reused node runtime"
fi

# --- 4. Inside-out code signing with the self-signed PDX identity.
echo "[2/5] Signing '$APP_NAME' with '$IDENTITY' (inside-out)…"
APP="$SRC"
xattr -cr "$APP"
# Frameworks dylibs (liblocalvqe + libggml*)
find "$APP/Contents/Frameworks" -type f -name "*.dylib" -print0 \
  | while IFS= read -r -d '' f; do codesign --force --sign "$IDENTITY" "$f"; done
# Loose helper executables in Resources (ffmpeg, yt-dlp, node, nested bundle binaries)
find "$APP/Contents/Resources" -type f -perm -111 -print0 \
  | while IFS= read -r -d '' f; do codesign --force --sign "$IDENTITY" "$f"; done
# Bundled CLI
[[ -f "$APP/Contents/MacOS/macparakeet-cli" ]] \
  && codesign --force --sign "$IDENTITY" "$APP/Contents/MacOS/macparakeet-cli"

# Outer app (deep catches any remaining nested bundles).
xattr -cr "$APP"
codesign --force --deep --sign "$IDENTITY" "$APP"

echo "[3/5] Verifying signature…"
codesign --verify --deep --verbose=2 "$APP"

echo "[4/5] Smoke-testing bundled helpers…"
"$APP/Contents/Resources/yt-dlp" --version >/dev/null && echo "  yt-dlp OK"
"$APP/Contents/MacOS/macparakeet-cli" --version || true

echo "[5/5] Zipping → $ZIP"
rm -f "$ZIP"
ditto -c -k --keepParent --sequesterRsrc "$APP" "$ZIP"

echo "✓ Done: $ZIP"
echo "  version=$VERSION  size=$(du -h "$ZIP" | awk '{print $1}')"
