<p align="center">
  <img src="Assets/AppIcon-1024x1024.png" width="128" height="128" alt="MacParakeet (PDX Edition) app icon">
</p>

<h1 align="center">MacParakeet (PDX Edition)</h1>

<p align="center">
  Personal fork of <a href="https://github.com/moona3k/macparakeet">moona3k/macparakeet</a> — a fast, fully-local voice app for Mac. This branch is built for personal use: no auto-update phoning home, no telemetry, no shared issue tracker. Same engine, smaller surface area.
</p>

<p align="center">
  <a href="https://github.com/jnzn/macparakeet/releases/latest"><img src="https://img.shields.io/badge/Download-Latest%20Release-2E7D43.svg?style=for-the-badge&logo=apple&logoColor=white" alt="Download Latest Release"></a>
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0-blue.svg" alt="GPL-3.0 License"></a>
  <img src="https://img.shields.io/badge/macOS-14.2%2B-000000.svg" alt="macOS 14.2+">
  <img src="https://img.shields.io/badge/Swift-6.0-F05138.svg" alt="Swift 6">
  <img src="https://img.shields.io/badge/Apple%20Silicon-only-333333.svg" alt="Apple Silicon only">
</p>

---

## What this is?

PDX Edition is the same MacParakeet engine — local Parakeet TDT speech recognition on the Apple Neural Engine via [FluidAudio](https://github.com/FluidInference/FluidAudio) — packaged for personal use. It does three things equally well:

- **System-wide dictation** — hold a hotkey, talk anywhere on macOS, text gets pasted at your cursor.
- **File / URL transcription** — drag in audio or video, or paste a YouTube link.
- **Meeting recording** — captures system audio + microphone together, transcribes locally.

All speech recognition happens on your machine. Audio never leaves the Mac.

## What's different from upstream

This fork strips out everything that makes sense for a public product but doesn't make sense for a personal build:

| Surface | Upstream | PDX Edition |
|---|---|---|
| Auto-update | Sparkle 2 with EdDSA-signed appcast at macparakeet.com | **Removed.** Update by re-downloading from Releases. |
| Telemetry | Opt-out, posts to upstream's Cloudflare endpoint | **Removed.** Hard-off in `AppPreferences`. |
| Discover sidebar | Curated content card | **Removed.** |
| Feedback panel | In-app form posting to upstream's GitHub Issues | **Replaced** with a single mailto card. |
| Trial / licensing keychain bootstrap | Reads 5 keychain items at every launch | **Disabled** (vestigial — app is GPL-3.0 free). |
| Identity | `MacParakeet`, bundle ID `com.macparakeet.MacParakeet` | `MacParakeet (PDX Edition)`, bundle ID `com.macparakeet.pdx` |
| Accent color | Coral-orange | Forest green |

The full delta is documented in [`docs/pdx-edition.md`](docs/pdx-edition.md), including which specific files were touched.

## Notable additions

- **Optional AI Assistant onboarding step** — first-run wizard detects installed Claude Code / Codex / Gemini CLIs on your login-shell PATH, probes any local Ollama daemon over HTTP, and offers a remote-Ollama branch with HTTPS toggle (default-on, since Tailscale serves valid Let's Encrypt certs on `*.ts.net`). All optional; skipping is silent.
- **Live hotkey-press demo** in the onboarding Hotkeys step — confirms macOS is delivering keyDown/keyUp events to the app for both default hotkeys (right-Option for dictation, Fn / Globe for AI Assistant).
- **App Transport Security exceptions** for Tailscale `*.ts.net` and RFC 1918 / `.local` LAN addresses, so plain HTTP to Ollama on the tailnet works without TLS termination.
- **PATH discovery hardening** — process-wide cache pre-warmed at app launch, 10-second probe budget for slow `~/.zshrc`, and a sweep of common user-bin dirs (`~/.local/bin`, `~/.cargo/bin`, `~/.npm-global/bin`, `~/.bun/bin`, `~/.deno/bin`, `~/.volta/bin`, `~/.asdf/shims`, `~/go/bin`, `~/.local/share/pnpm`).
- **Cache-aware engine setup copy** — when the speech model is already on disk (e.g., migrated from upstream), onboarding says "Loading the cached speech model into memory" instead of misleadingly claiming a 6 GB download.

## Get it

### Pre-built binary (recommended for personal use)

Grab `MacParakeet-PDX-Edition.zip` from the [Releases page](https://github.com/jnzn/macparakeet/releases/latest), then in Terminal:

```bash
cd ~/Downloads
unzip MacParakeet-PDX-Edition.zip
mv "MacParakeet (PDX Edition).app" /Applications/
xattr -cr "/Applications/MacParakeet (PDX Edition).app"
open "/Applications/MacParakeet (PDX Edition).app"
```

The `xattr -cr` step is required because the build is **ad-hoc signed** (no Apple Developer Program membership). Without it, macOS Gatekeeper blocks the launch.

The parakeet icon appears in the **menu bar (top-right)** — this is a menu-bar app, no Dock icon.

### Build from source

```bash
git clone --branch feature/streaming-overlay https://github.com/jnzn/macparakeet.git
cd macparakeet
swift test --build-path /tmp/mp-test-build
scripts/dev/run_app.sh
```

Requires Xcode 15+ on an Apple Silicon Mac. The dev script wraps the binary in `MacParakeet (PDX Edition).app` and signs with the best local identity available (Apple Development cert if installed; ad-hoc otherwise).

### First-run permissions

The app asks for:

- **Microphone** — required for dictation.
- **Accessibility** — required for the global hotkey + paste automation. After granting in System Settings, **quit and relaunch the app** so the new permission state takes effect (`AXIsProcessTrusted()` is cached per-process by macOS).
- **Screen & System Audio Recording** — only required for meeting recording. Skippable.

First launch downloads ~6 GB of speech-recognition models (one-time, fully local thereafter). If you're migrating from an existing MacParakeet install, the models live at `~/Library/Application Support/MacParakeet/models/stt/` and are shared between bundles — no re-download.

## Default hotkeys

- **Right Option** held — dictate (release to paste).
- **Right Option** double-tapped — persistent dictation mode.
- **Fn / Globe** held — Ask AI Assistant about selected text (only when configured).
- **Esc** during dictation — cancel.

All rebindable in Settings → Hotkeys.

## Tech stack

| Layer | Choice |
|-------|--------|
| STT | Parakeet TDT 0.6B-v3 via [FluidAudio](https://github.com/FluidInference/FluidAudio) CoreML (Neural Engine) |
| STT orchestration | Shared runtime + scheduler across dictation, meeting recording, and transcription |
| Language | Swift 6.0 + SwiftUI |
| Database | SQLite via GRDB |
| Audio | AVAudioEngine + Core Audio Taps |
| YouTube | bundled yt-dlp + Node runtime |
| Media demux | bundled FFmpeg |
| Platform | macOS 14.2+, Apple Silicon |

## CLI

```bash
swift run macparakeet-cli transcribe /path/to/audio.mp3
swift run macparakeet-cli models status
swift run macparakeet-cli history
```

## Performance

- ~155x realtime — 60 min of audio in ~23 seconds
- ~2.5% word error rate (Parakeet TDT 0.6B-v3)
- ~66 MB working memory per active inference slot
- 25 European languages with auto-detection (no CJK)

## Privacy

Same as upstream, with telemetry permanently disabled:

- Speech recognition runs on the Neural Engine, fully on-device.
- No cloud STT, no accounts, no analytics, no crash reports.
- Audio temp files deleted after transcription unless you save them.
- AI features (summaries, chat, AI Assistant bubble) connect to whatever LLM provider you configure — Anthropic, OpenAI, Gemini, OpenRouter, Ollama, LM Studio, or local CLI tools (Claude Code, Codex, gemini-cli). All entirely opt-in. Pure local setup is supported.

## Sharing this with someone

The Releases page is the friendly path. There's a copy-paste install guide friends can follow without touching anything but Terminal — see [the install guide note](https://github.com/jnzn/macparakeet/releases/latest) on the release page.

## Contact

- Bug reports / ideas: **pdxedition@fastmail.com**
- Source: [github.com/jnzn/macparakeet (feature/streaming-overlay branch)](https://github.com/jnzn/macparakeet/tree/feature/streaming-overlay)

There is no shared issue tracker — this is a personal fork, not a public product.

## Credits

This is a fork of [**MacParakeet** by moona3k](https://github.com/moona3k/macparakeet). All the heavy lifting — the STT pipeline, the meeting-recording architecture, the onboarding flow, the design system — is upstream's work. PDX Edition just adapts the surface for personal-build use.

If MacParakeet is useful to you and you want to support the project, [sponsor moona3k upstream](https://github.com/sponsors/moona3k) — that's where the real maintenance happens.

## License

GPL-3.0, same as upstream. [Full license](LICENSE).
