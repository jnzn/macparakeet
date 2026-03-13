# Distribution (Developer ID + Notarization)

This repo is SwiftPM-based, so we assemble a `.app` bundle manually for Developer ID distribution.

## 1) Build the app bundle

From the repo root:

```bash
scripts/dist/build_app_bundle.sh
```

This creates `dist/MacParakeet.app` and bundles:
- `Assets/AppIcon.icns` into `Contents/Resources/AppIcon.icns` (app icon for Dock, Finder, DMG)
- SwiftPM resource bundles into `Contents/Resources/`
- Standalone helper binaries (yt-dlp and FFmpeg) into `Contents/Resources/` when configured by the build scripts
- No Python runtime or `uv` bootstrap is bundled (FluidAudio/CoreML STT is native Swift)

`build_app_bundle.sh` automatically downloads a **statically-linked FFmpeg** from [ffmpeg.martin-riedl.de](https://ffmpeg.martin-riedl.de/) (macOS arm64, SHA256-verified). No Homebrew dependency. To use a custom binary instead, set `FFMPEG_PATH`:

```bash
FFMPEG_PATH=/absolute/path/to/static-ffmpeg scripts/dist/build_app_bundle.sh
```

The script verifies the bundled binary has no non-system dylib dependencies (portability check via `otool -L`).

Optional licensing config (recommended for production):

```bash
export MACPARAKEET_CHECKOUT_URL="https://..."
export MACPARAKEET_LS_VARIANT_ID="12345"
scripts/dist/build_app_bundle.sh
```

These are embedded into `Info.plist` as:
- `MacParakeetCheckoutURL`
- `MacParakeetLemonSqueezyVariantID`

## 2) Sign + notarize (recommended)

Prereqs:
- A **Developer ID Application** certificate in Keychain.
- `notarytool` credentials stored in Keychain under the profile `AC_PASSWORD` (shared with Oatmeal):

```bash
xcrun notarytool store-credentials "AC_PASSWORD" \
  --apple-id "moona3k@gmail.com" \
  --team-id "FYAF2ZD7RM" \
  --password "app-specific-password"
```

Verify credentials work:

```bash
xcrun notarytool history --keychain-profile "AC_PASSWORD"
```

Then:

```bash
NOTARYTOOL_PROFILE="AC_PASSWORD" scripts/dist/sign_notarize.sh
```

Outputs:
- `dist/MacParakeet.app` (signed + stapled)
- `dist/MacParakeet.dmg` (signed + stapled)

## 3) Upload to Cloudflare R2

The signed DMG is hosted on Cloudflare R2 at `downloads.macparakeet.com`.

**Bucket:** `macparakeet-downloads` (Cloudflare R2)
**Custom domain:** `downloads.macparakeet.com`
**Public URL:** `https://downloads.macparakeet.com/MacParakeet.dmg`

Upload a new release:

```bash
npx wrangler r2 object put macparakeet-downloads/MacParakeet.dmg \
  --file dist/MacParakeet.dmg \
  --content-type "application/x-apple-diskimage" \
  --remote
```

Verify:

```bash
curl -sI https://downloads.macparakeet.com/MacParakeet.dmg | head -5
```

Because Cloudflare may serve a cached object briefly, also verify with a cache-busting query:

```bash
curl -sI "https://downloads.macparakeet.com/MacParakeet.dmg?ts=$(date +%s)" | head -10
```

Confirm `content-length`, `last-modified`, and `etag` match the newly uploaded DMG.

## Full release workflow

```bash
# 1. Build app bundle (auto-downloads static FFmpeg, embeds Sparkle.framework)
scripts/dist/build_app_bundle.sh

# 2. Sign + notarize (signs Sparkle.framework, helper binaries, then app; creates .dmg)
NOTARYTOOL_PROFILE="AC_PASSWORD" scripts/dist/sign_notarize.sh

# 3. Upload DMG to R2
npx wrangler r2 object put macparakeet-downloads/MacParakeet.dmg \
  --file dist/MacParakeet.dmg \
  --content-type "application/x-apple-diskimage" \
  --remote

# 4. Sign the DMG for Sparkle and update the appcast
.build/artifacts/sparkle/Sparkle/bin/sign_update dist/MacParakeet.dmg
# Copy the sparkle:edSignature and length values into appcast.xml

# 5. Upload updated appcast.xml to macparakeet-website repo
# (deployed automatically via Cloudflare Pages)

# 6. Verify fresh object metadata (cache-busted HEAD)
curl -sI "https://downloads.macparakeet.com/MacParakeet.dmg?ts=$(date +%s)" | head -10

# 7. Website download buttons already point to:
#    https://downloads.macparakeet.com/MacParakeet.dmg
```

## Auto-Updates (Sparkle)

MacParakeet uses [Sparkle 2](https://sparkle-project.org/) for in-app auto-updates. Users are prompted when a new version is available — no manual DMG download needed.

### How it works

1. On launch, Sparkle checks `https://macparakeet.com/appcast.xml` for new versions
2. If a newer version exists, a native update dialog appears
3. User clicks "Install Update" → Sparkle downloads the DMG, replaces the app, relaunches

### EdDSA signing keys

The private key is stored in the developer's macOS Keychain (generated once via `generate_keys`). The public key is embedded in `Info.plist` as `SUPublicEDKey`.

To retrieve the public key or verify the Keychain entry:

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys
```

### Appcast

The appcast XML lives in the [macparakeet-website](https://github.com/moona3k/macparakeet-website) repo at `public/appcast.xml` and is served at `https://macparakeet.com/appcast.xml`.

Template for a new release:

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>MacParakeet Updates</title>
    <item>
      <title>Version X.Y.Z</title>
      <link>https://macparakeet.com</link>
      <sparkle:version>BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>X.Y.Z</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.2</sparkle:minimumSystemVersion>
      <description><![CDATA[
        <h2>What's New</h2>
        <ul>
          <li>Feature or fix description</li>
        </ul>
      ]]></description>
      <pubDate>DATE_RFC2822</pubDate>
      <enclosure
        url="https://downloads.macparakeet.com/MacParakeet.dmg"
        sparkle:edSignature="SIGNATURE_FROM_SIGN_UPDATE"
        length="FILE_SIZE_BYTES"
        type="application/octet-stream" />
    </item>
  </channel>
</rss>
```

### Signing an update

```bash
# Sign the DMG and get the signature + length for appcast.xml
.build/artifacts/sparkle/Sparkle/bin/sign_update dist/MacParakeet.dmg
```

This outputs `sparkle:edSignature="..."` and `length="..."` — paste both into the appcast `<enclosure>` element.

### Auto-generate appcast from a directory of releases

```bash
# Place all versioned DMGs in a directory, then:
.build/artifacts/sparkle/Sparkle/bin/generate_appcast /path/to/releases/
```

This generates/updates `appcast.xml` with signatures and optional delta updates.

### Info.plist keys

These are set automatically by `build_app_bundle.sh`:

| Key | Value |
|-----|-------|
| `SUFeedURL` | `https://macparakeet.com/appcast.xml` |
| `SUPublicEDKey` | `2aqRU0Agz+xxZwt0kLybmKz/SAvZUsyn+z9fU0I6ynY=` |

### Settings UI

Users can control auto-update behavior in Settings > Updates:
- Toggle automatic update checks
- Toggle automatic update downloads
- Manual "Check for Updates..." button

"Check for Updates..." is also available in the app menu and menu bar dropdown.

## Notes

- The scripts default to a single-arch Release build. For a universal binary:

```bash
UNIVERSAL=1 scripts/dist/build_app_bundle.sh
```

- `MacParakeet` requests microphone permission. The app bundle `Info.plist` includes `NSMicrophoneUsageDescription`.
- **Users must install to /Applications before launching.** Running directly from a mounted DMG (`/Volumes/MacParakeet/`) will not register with macOS TCC — the app won't appear in System Settings > Privacy & Security > Microphone, and permission requests will silently fail. The DMG includes an Applications symlink for drag-to-install.
- If a user's microphone permission gets stuck as "Denied", reset it with: `tccutil reset Microphone com.macparakeet.MacParakeet`
- The Cloudflare R2 bucket uses a custom domain via `wrangler r2 bucket domain add`. The `r2.dev` public URL is also enabled as a fallback.
- Cloudflare Pages has a 25MB file size limit, so the DMG (27MB) cannot be hosted directly in the website repo's `public/` folder.
