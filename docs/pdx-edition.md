# MacParakeet (PDX Edition)

> Status: **ACTIVE**
> Branch: `feature/streaming-overlay` on `jnzn/macparakeet`
> Bundle ID: `com.macparakeet.pdx`
> First shipped: 2026-04-18

PDX Edition is Jensen's personal fork of MacParakeet — same core
engine, different identity, several upstream surfaces removed
because they don't make sense for a personal build (auto-update,
telemetry, in-app feedback form, Discover sidebar).

This doc lists the deltas vs. the `moona3k/macparakeet` upstream
so a future code-archaeology pass — or a fresh AI agent picking
up the branch — can understand what was changed and why.

---

## Identity

| Surface | Upstream | PDX Edition |
|---|---|---|
| Bundle name | `MacParakeet` | `MacParakeet (PDX Edition)` |
| Bundle ID (dist) | `com.macparakeet.MacParakeet` | `com.macparakeet.pdx` |
| Bundle ID (dev script) | `com.macparakeet.dev` | `com.macparakeet.dev` (kept; preserves dev TCC) |
| App icon | Cream + warm coral | Forest-green diagonal gradient |
| UI accent | Coral-orange | Forest green (`(0.16, 0.45, 0.27)` light / `(0.32, 0.72, 0.46)` dark) |
| Window title | "MacParakeet" | "MacParakeet (PDX Edition)" |
| Menu bar dropdown | "Open MacParakeet" / "Quit MacParakeet" | "Open PDX Edition" / "Quit PDX Edition" |
| Onboarding welcome | "Welcome to MacParakeet" | "Welcome to MacParakeet (PDX Edition)" |
| Onboarding done button | "Open MacParakeet" | "Open MacParakeet (PDX Edition)" |
| Meeting pill menu | "Open MacParakeet" | "Open PDX Edition" |

## Removed surfaces

| Surface | Why removed |
|---|---|
| **Sparkle auto-update** (`Package.swift`, `MenuBarCoordinator`, `SettingsView` Updates card, `Info.plist` SU* keys) | Upstream's `SUFeedURL` points at `macparakeet.com/appcast.xml`. A "Check for Updates" click on PDX would download upstream's notarized DMG, replace the PDX bundle with stock MacParakeet, and silently delete every personal modification. PDX users update by rebuilding from source. |
| **Discover sidebar** (`MainWindowView.discover` case, `DiscoverView`, `DiscoverSidebarCard`) | Pulled curated content from upstream. Not useful in a personal fork. (`SacredGeometryShapes.swift` was moved from `Discover/` to `Components/` because `PromptLibraryView` still uses `MerkabaShape`.) |
| **In-app feedback form** (`FeedbackView` rewrite) | Posted to upstream's Cloudflare Pages function which routes to `moona3k/macparakeet` GitHub Issues — won't authenticate from a fork, and submissions would land in the wrong tracker. Replaced with a single mailto card. |
| **Telemetry opt-in toggle** (`SettingsView.privacyCard`) | The "Help improve MacParakeet" toggle defaulted on (opt-out). PDX users shouldn't be sending events to upstream's endpoint. `AppPreferences.isTelemetryEnabled` now hard-returns `false`. |
| **EntitlementsService keychain bootstrap** | `bootstrapTrialIfNeeded` + `refreshValidationIfNeeded` were dormant remnants of the upstream paid build. Each launch read 5 keychain items (trialStartISO / installID / licenseKey / licenseInstanceID / lastValidatedISO). On an ad-hoc-signed PDX bundle, every item triggered a separate "wants to use your keychain" prompt because the items' ACL was bound to the upstream binary's signature. Both methods are now no-ops; keychain prompts at launch dropped from ~5 to ≤1. |

## Contact

The Feedback panel is now a single card that opens
`mailto:pdxedition@fastmail.com` with a pre-filled subject. There
is no shared issue tracker — bug reports / ideas go straight to
that email.

## Onboarding additions

The first-run wizard added an optional **Ask AI Assistant** step
between Hotkeys and the speech-model preflight (ADR-005 amendment
2026-04-18). It detects Claude Code / Codex / Gemini CLIs on the
user's login-shell PATH, probes a local Ollama daemon over HTTP,
and offers a remote-Ollama branch with host / port + a "Use HTTPS"
toggle (default on, because Tailscale serves valid Let's Encrypt
certs on `*.ts.net`). Skipping every card is valid — the Fn /
Globe hotkey just stays inactive until the user wires providers
later in Settings → AI Assistant.

The Hotkeys step (formerly singular "Hotkey") was rewritten to
demo both default keys live: right-Option for dictation, Fn /
Globe for AI Assistant. A 15-second fallback link points back to
the Accessibility step if the press detector hasn't seen either
key.

The Welcome card and the engine-step copy now respect cache
state: when the speech model is already on disk (e.g., migrated
from upstream), the body reads "Loading the cached speech model
into memory" instead of the misleading "Downloading the speech
model (~6 GB)".

## Networking

`scripts/dist/build_app_bundle.sh` injects an
`NSAppTransportSecurity` block into the dist Info.plist:

- `NSAllowsLocalNetworking = true` for RFC 1918 / `.local` /
  link-local hosts (LAN Ollama, LM Studio).
- `NSExceptionDomains[ts.net]` with
  `NSExceptionAllowsInsecureHTTPLoads = true` for Tailscale
  MagicDNS hosts (`http://macstudio.<tailnet>.ts.net:11434/...`).
  Tailscale's WireGuard tunnel encrypts the transport below the
  HTTP layer, so plain HTTP inside the tailnet is safe.

`OllamaURLValidator` (lifted out of `LLMSettingsDraft` so
onboarding and Settings share verbatim) accepts loopback,
`*.ts.net`, the Tailscale CGNAT range `100.64.0.0/10`, RFC 1918
private LAN, `*.local`, and any HTTPS URL.

## CLI detection

`LocalCLIExecutor.resolve(binary:)` walks the user's login-shell
PATH to find Claude / Codex / Gemini binaries. Discovery has
several improvements over the original 3-second `$SHELL -lc`
probe:

- **Process-wide cache** (`sharedPATHCache`) — `preWarmPATHCache()`
  runs in a detached background Task at
  `applicationDidFinishLaunching`, so by the time onboarding
  reaches the AI Assistant step, the resolved PATH is already in
  cache and detection is instant.
- **10-second probe budget** instead of 3 — slow `~/.zshrc` (NVM
  lazy-load, conda init, asdf, large dotfiles) routinely chews
  through 3s on cold launch.
- **User-bin dir sweep** — `~/.local/bin`, `~/.cargo/bin`,
  `~/.npm-global/bin`, `~/.npm/bin`, `~/.bun/bin`, `~/.deno/bin`,
  `~/.volta/bin`, `~/.asdf/shims`, `~/go/bin`,
  `~/.local/share/pnpm` are merged into the PATH whenever they
  exist, even when the shell probe times out.

## First-run UX

- The "Global Hotkey Unavailable" alert is now suppressed during
  onboarding (`onboardingWindowController.isVisible`) and on
  first launch (`onboarding.completedAtISO` not yet set). The
  onboarding's own Accessibility step is the right place to
  request that permission; the alert was popping before the
  wizard's UI had a chance to render.

## TCC quirks specific to ad-hoc PDX builds

- macOS Accessibility allowlist entries are bound to the binary's
  code signature. Each rebuild gets a fresh ad-hoc signature →
  macOS treats it as a new identity → previously-granted access
  goes stale. Workflow: open Privacy & Security → Accessibility,
  remove orphan "MacParakeet (PDX Edition)" entries, then
  re-grant on next launch.
- After granting Accessibility, **quit + relaunch** the app.
  `AXIsProcessTrusted()` is reliable for new processes but
  caches stale during the running process's lifetime. The
  onboarding polling can't see the change until restart.

## Migration from upstream MacParakeet

`migrate-to-pdx.sh` (lives on the user's Desktop) copies
`UserDefaults`, Caches, HTTPStorages, WebKit, and Saved
Application State from `com.macparakeet.MacParakeet` to
`com.macparakeet.pdx`. The SQLite DB, STT models, and LLM API
keys live at fixed paths shared by both bundles, so they need
no migration:

- Database: `~/Library/Application Support/MacParakeet/macparakeet.db`
- STT models: `~/Library/Application Support/MacParakeet/models/stt/`
- Keychain LLM API keys: service `com.macparakeet.llm` (hardcoded,
  not bundle-ID-keyed)

TCC permissions cannot be migrated by any script (SIP-protected);
the user re-grants Microphone + Accessibility (+ Screen Recording
if they want meeting recording) on first launch.

## Building / shipping

PDX dist build differs from upstream only via env vars passed to
`scripts/dist/build_app_bundle.sh`:

```bash
APP_NAME="MacParakeet (PDX Edition)" \
BUNDLE_ID="com.macparakeet.pdx" \
VERSION="0.6.0-pdx" \
XCODE_DERIVED_DATA="/tmp/mp-pdx-dist" \
scripts/dist/build_app_bundle.sh
```

Then ad-hoc sign and zip (no notarization — PDX is personal-use
only):

```bash
APP="dist/MacParakeet (PDX Edition).app"
xattr -cr "$APP"
find "$APP/Contents/Resources" -maxdepth 1 -type f -perm -111 -print0 \
  | while IFS= read -r -d '' h; do codesign --force --sign - "$h"; done
xattr -cr "$APP"
codesign --force --sign - "$APP"
ditto -c -k --keepParent --sequesterRsrc "$APP" dist/MacParakeet-PDX-Edition.zip
```

Important: do **not** use `codesign --options runtime` for the
ad-hoc path. Hardened runtime + ad-hoc + library validation =
dyld rejects every bundled framework with "different Team IDs".

## Files at a glance

PDX-specific files (don't exist upstream):

- `docs/pdx-edition.md` — this document
- `scripts/dev/run_app.sh` — wraps the dev bundle as
  `MacParakeet (PDX Edition).app` (rename only; bundle ID stays
  `com.macparakeet.dev` for TCC stability)

Touched / removed across the codebase:

- `Package.swift` — Sparkle dependency removed
- `Sources/MacParakeet/AppDelegate.swift` — no Sparkle, no
  Discover, calls `LocalCLIExecutor.preWarmPATHCache()`,
  hotkey-unavailable alert gated on onboarding completion
- `Sources/MacParakeet/App/AppWindowCoordinator.swift` /
  `Sources/MacParakeet/App/MenuBarCoordinator.swift` — Sparkle
  + Discover wiring removed
- `Sources/MacParakeet/Views/MainWindowView.swift` — `.discover`
  SidebarItem removed
- `Sources/MacParakeet/Views/Settings/SettingsView.swift` —
  Updates + Privacy cards removed
- `Sources/MacParakeet/Views/Feedback/FeedbackView.swift` —
  rewritten as one-card mailto contact
- `Sources/MacParakeet/Views/Components/DesignSystem.swift` —
  forest-green accent triplet
- `Sources/MacParakeet/Views/Components/MarkdownContentView.swift`
  — chat-bubble inline-link color matches the green accent
- `Sources/MacParakeet/Views/Components/SacredGeometryShapes.swift`
  — moved from `Discover/`
- `Sources/MacParakeet/Views/Discover/*` — deleted
- `Sources/MacParakeet/Views/Onboarding/OnboardingFlowView.swift`
  — branding, hotkeys live demo, engine cache-aware copy
- `Sources/MacParakeet/Views/Onboarding/AIAssistantOnboardingContainerView.swift`
  — new container for the AI Assistant step
- `Sources/MacParakeetCore/Services/LocalCLIExecutor.swift` —
  `resolve(binary:)`, user-bin sweep, process-wide PATH cache,
  pre-warm static
- `Sources/MacParakeetCore/Services/OllamaReachability.swift` —
  new HTTP probe
- `Sources/MacParakeetCore/Services/OllamaURLValidator.swift` —
  shared host-allowlist validator
- `Sources/MacParakeetCore/Services/AIAssistantService.swift` —
  default hotkey trigger now `.fn`
- `Sources/MacParakeetCore/AppPreferences.swift` —
  `isTelemetryEnabled` returns `false`
- `Sources/MacParakeetCore/Licensing/EntitlementsService.swift` —
  bootstrap + refresh are no-ops
- `Sources/MacParakeetViewModels/AIAssistantOnboardingViewModel.swift`
  — new state-machine VM
- `Sources/MacParakeetViewModels/OnboardingViewModel.swift` —
  `.aiAssistant` step, `isSpeechModelAlreadyCached`
- `Sources/MacParakeetViewModels/LLMSettingsDraft.swift` —
  validator now forwards to `OllamaURLValidator`
- `scripts/dist/build_app_bundle.sh` — Sparkle embedding +
  `SUFeedURL` removed; `NSAppTransportSecurity` block added
- `Assets/AppIcon.icns` / `Assets/AppIcon-1024x1024.png` —
  forest-green art
- `spec/adr/005-onboarding-first-run.md` — amendment 2026-04-18
- `plans/active/2026-04-onboarding-ai-assistant-step.md` —
  the plan that drove the AI Assistant step
