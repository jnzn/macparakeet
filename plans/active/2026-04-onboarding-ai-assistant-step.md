# Onboarding — AI Assistant Step (Sequential Card Walk)

> Status: **ACTIVE**
> Date: 2026-04-18
> Related ADRs: `spec/adr/005-onboarding-first-run.md` (amendment required), `spec/adr/011-llm-cloud-and-local-providers.md`
> Related plans: `plans/completed/2026-04-onboarding-screen-recording-permission.md` (template for step-addition pattern)

## Objective

Add an **optional** "Ask AI Assistant" step to first-run onboarding that:

1. Detects which of the four AI Assistant bubble providers (Claude Code, Codex, Gemini, Ollama) are installed on the machine — via the user's real login-shell PATH, not a hardcoded location.
2. Walks the user through them **one card at a time**, each with an Enable / Skip choice.
3. Handles the Ollama "not local, maybe remote" case by prompting for host + port and running a live connection test before enabling.
4. Writes the user's choices into `AIAssistantConfig` (enabled providers list + default provider) so the Fn / Globe hotkey is active with their preferred tools as soon as onboarding ends.
5. Updates the existing `hotkey` step copy to reference both hotkeys (dictation on right-Option, AI Assistant on Fn) now that there are two.

## Why this and why now

- AI Assistant bubble (`AIAssistantConfig` — Claude / Codex / Gemini / Ollama) shipped in 0.0.19 but is entirely off-by-default. First launch gives the user no indication these providers exist, and the Fn/Globe hotkey (default as of the 2026-04-18 change in `AIAssistantService.swift:161`) does nothing until the user digs into Settings → AI Assistant.
- Jensen's Brandon-build scenario (`OneDrive/BCBSMA/cortex notes/` and the `jnzn/macparakeet` fork's `feature/streaming-overlay` branch — see `docs/Streaming Dictation App.md` in Obsidian) specifically needs "build from GitHub for himself, no $99 Dev Program" — which means Brandon will first-launch cold with no saved config. Onboarding is the right moment to surface what's available.
- All the detection plumbing already exists (`LocalCLIExecutor.discoverPATH`) and is PATH-aware across zsh / bash / fish / path_helper fallback, so nvm/volta/asdf/homebrew/custom prefix installs all resolve correctly.
- Ollama host-override validator already exists (`LLMSettingsDraft.isAllowedBaseURLOverride`) and accepts localhost, Tailscale `*.ts.net`, CGNAT `100.64.0.0/10`, RFC1918, and `*.local` — exactly what a remote-Ollama card needs.

## Scope

### In scope

- New `aiAssistant` step in `OnboardingViewModel.Step`, positioned after `.hotkey` and before `.engine`.
- Internal sub-flow state machine within the step — each card is a distinct sub-state, not a separate `Step` enum case. The sidebar shows a single "Ask AI Assistant" progress row; internal card progress lives in the main content area only.
- Card sequence (fixed order):
  1. **Intro** — "pick your tools" framing + [Continue] / [Skip all →]
  2. **Claude Code** — detect `which claude`, show resolved path or "not detected," [Enable] / [Skip]
  3. **Codex** — detect `which codex`, same UX
  4. **Gemini** — detect `which gemini`, same UX
  5. **Ollama** — detect `GET localhost:11434/api/tags` (2s timeout). Two states:
     - **Found local:** list installed models from response, dropdown-pick one, [Enable] / [Skip]
     - **Not found local:** branch to "Is Ollama on another computer?" → [Yes] expands host/port inputs + [Test connection] → on success, populate model dropdown from remote `/api/tags` → [Enable]
  6. **Default provider** — radio picker over providers the user enabled in 2-5 (disabled if zero enabled), [Finish AI setup] / [Skip — don't enable hotkey]
- Update the existing `.hotkey` step copy to document both hotkeys: "Dictate → Right Option. Ask AI Assistant → Fn / Globe." Icon + title may need to become plural ("Hotkeys").
- New ViewModel `AIAssistantOnboardingViewModel` (separate from `OnboardingViewModel` — keeps the main ViewModel from bloating). Owns card sub-state, detection state, per-provider enable toggles, remote-Ollama draft, default-provider selection.
- Persistence: on **Finish AI setup**, write to `AIAssistantConfigStore` with:
  - `provider` = chosen default
  - `enabledProviders` = raw values of all enabled providers
  - `providerCommandTemplates` = default templates (no custom edits in onboarding)
  - `providerModelNames` = per-provider chosen model (only Ollama surfaces model choice in onboarding; others use their defaults from `Provider.defaultModel`)
  - For Ollama remote, also write the HTTP endpoint via the existing `LLMProviderConfig.ollama(...)` path — onboarding hands this off to the same config store Settings uses (`LLMConfigStoreProtocol`) so Settings → AI Provider reflects the onboarding choice.
- Tests (ViewModel-level): card advance/back, skip semantics, detection mock points, remote-Ollama draft validation, persistence payload shape.
- ADR-005 amendment: append a note dated 2026-04-18 adding the `aiAssistant` step to the step list, same format as the 2026-04-10 Screen & System Audio Recording amendment.

### Out of scope

- **Gemini API (cloud) in onboarding.** Only `gemini-cli` is surfaced. The `LLMProviderID.gemini` (API-key HTTP provider) stays Settings-only.
- **Any LLM Provider path** (Anthropic API, OpenAI API, OpenRouter, LM Studio, Local CLI template picker). The "AI Formatter / live cleanup" configuration in Settings → AI Provider is intentionally untouched — two systems stay separate.
- **Installing missing CLIs.** If `claude` / `codex` / `gemini` isn't found, the card says "not detected, skip" and moves on. No install instructions, no "Check again" button. Per Jensen: "if the user already uses gemini-cli that's enough."
- **Editing command templates in onboarding.** Users who want to tweak `--model` / `--yolo` / `--dangerously-skip-permissions` flags do it later in Settings → AI Assistant. Onboarding ships each provider's default template unchanged.
- **Re-onboarding existing users.** Users past `hasCompletedOnboarding` do not see the new step. (The Settings → AI Assistant UI is unchanged and still discoverable for them.)
- **Retroactive Fn-hotkey rebinding for already-configured users.** The 2026-04-18 default change to `HotkeyTrigger.fn` only affects users whose `AIAssistantConfig.hotkeyTrigger` is nil (unset — falls back to the default). Users who previously saved Control+Option+Shift keep that binding.

### Invariants (must not change)

- `OnboardingViewModel.Step` remains a linear wizard — sub-cards inside the `aiAssistant` step are internal; the sidebar still shows one row per `Step` case.
- `canContinueFromCurrentStep()` must return `true` on the `aiAssistant` step regardless of whether any provider was enabled. Skipping everything is valid.
- Existing `hotkey` step behavior (dictation hotkey selection + validation) must not regress. The copy update is text-only — no change to the recording/validation path.
- No network or filesystem probe runs until the user actually enters the `aiAssistant` step. Detection is not part of app launch.
- `LocalCLIExecutor.discoverPATH` is the single source of truth for binary lookup. No hardcoded paths, no `/opt/homebrew/bin/...` assumption.
- Ollama remote-host validation reuses `LLMSettingsDraft.isAllowedBaseURLOverride` verbatim — no divergence between onboarding and Settings validation rules.
- First-use AI Assistant hotkey behavior (pressing Fn on a selection) must continue to work for users who completed onboarding *and* for users who skipped — the latter just get the "no provider configured" path that already exists in `AIAssistantFlowCoordinator`.
- **Rerun setup never clobbers user-entered values.** When onboarding is relaunched from Settings ("Rerun setup"), every field in the `aiAssistant` step must pre-populate from the user's currently saved config — per-provider command templates, model names, Ollama endpoint (host + port + model), default provider, enabled-providers set. Rerun does **not** reset to shipped template defaults. The user can still click a per-card "Reset to defaults" affordance if they explicitly want the template, but entering rerun never silently overwrites their customizations.

## Current state snapshot

### Already true

- `OnboardingViewModel.Step`: `welcome → microphone → accessibility → meetingRecording → hotkey → engine → done` (`Sources/MacParakeetViewModels/OnboardingViewModel.swift:12-33`).
- `AIAssistantConfig.Provider` enum has `claude`, `codex`, `gemini`, `ollama` with default templates, models, icons, and brand colors (`Sources/MacParakeetCore/Services/AIAssistantService.swift:37-117`).
- `AIAssistantConfig.defaultHotkeyTrigger` = `.fn` as of 2026-04-18 (`Sources/MacParakeetCore/Services/AIAssistantService.swift:161`).
- `AIAssistantConfigStore` (UserDefaults-backed, `ai_assistant_config` key) persists full config JSON (`AIAssistantService.swift:373-385`).
- `LocalCLIExecutor.discoverPATH` probes `$SHELL` → zsh/bash/fish fallbacks → `path_helper` to recover full user PATH for Finder-launched apps (`LocalCLIExecutor.swift:776-802`).
- `LLMSettingsDraft.isAllowedBaseURLOverride` validates host overrides (localhost / `*.ts.net` / CGNAT / RFC1918 / `*.local`) (`LLMSettingsDraft.swift:216-250`).
- `LLMConfigStoreProtocol` already handles Ollama configs via `LLMProviderConfig.ollama(model:baseURL:)` — the same path onboarding would write to.
- `OnboardingFlowView` has a sidebar with per-step rows and a main content switch on `viewModel.step`. Adding a new case touches step icon, title/subtitle, continue-button maps, and main `stepBody()` switch — the compiler flags anything missed.
- `Assets/AppIcon.icns` + `CFBundleIconFile` wiring in `scripts/dev/run_app.sh` (2026-04-18 change) means the dev bundle shows the actual icon now.

### Gaps this plan closes

- First-launch users have no path to discover the AI Assistant bubble or configure its providers.
- Users with Ollama on a remote machine (Tailscale / LAN) have no onboarding UX — they must go to Settings → AI Provider and paste a URL, then separately go to Settings → AI Assistant to wire the bubble to Ollama. Onboarding can collapse both steps.
- `hotkey` step copy documents only the dictation hotkey. Now that Fn is also a default, the text is incomplete.

## Locked design decisions

### 1. Sequential cards, not single summary screen

Per Jensen 2026-04-18: "seq". Each provider gets a dedicated card so the Ollama remote-connect branching has room to breathe. Summary-screen pattern (matching the existing Settings UI) rejected.

### 1a. Each card explains the feature, not just enables it

Cards lead with **what the tool does** (one-sentence product description) and **how the bubble uses it** (one-sentence integration note — e.g. "we invoke it with `--dangerously-skip-permissions` so the session auto-approves tool use"). The Enable button isn't a black-box toggle; the user should know exactly what they're turning on before clicking.

### 1b. Post-Enable smoke test per card

When the user clicks **Enable** on a CLI-provider card, the card runs a live smoke test before advancing:

- **Claude / Codex / Gemini cards:** reuse `LocalCLIExecutor.testConnection(config:)` (already built — sends "reply with OK" with a 10s timeout). Success shows the round-trip duration and [Continue]. Failure shows the specific error inline + [Try again] / [Skip].
- **Ollama card:** the `/api/tags` probe is already the live test (same call powers detection and the remote-Ollama [Test connection] button). No additional inference call — `/api/tags` succeeding is enough.

Purpose: catch broken installs, auth issues, or misconfigurations before the user walks out of onboarding and presses Fn expecting magic.

### 2. Skip is silent and final

If a user skips a card, that provider is not enabled. If a user skips **all** cards (or clicks [Skip all →] on the intro), no `AIAssistantConfig` is written and the hotkey stays inactive. Onboarding does not re-nag on next launch. Users find the providers in Settings → AI Assistant.

No per-card "remind me later" flag. Same pattern as `meetingRecordingSkipped` in the screen-recording plan, but there's no persisted `aiAssistantSkipped` — because the presence/absence of `AIAssistantConfigStore.load()` is already the source of truth for "did the user engage with this."

### 3. Detection uses real login-shell PATH

Every `which <binary>` runs through `LocalCLIExecutor.discoverPATH` (new thin wrapper `LocalCLIExecutor.resolve(binary:)` — returns `URL?`). No hardcoded `/opt/homebrew/bin` assumption. Detected-path string is shown in the card so the user can verify before enabling.

### 4. Ollama detection goes through HTTP, not `which`

The Ollama daemon is what matters, not the `ollama` CLI binary. Card pings `GET <baseURL>/api/tags` with a 2-3s timeout. Same call doubles as the "Test connection" button in the remote-Ollama branch. Success = HTTP 200 + parseable JSON with a `models` array.

### 4a. One Ollama configuration, fan-out to both stores

Per Jensen 2026-04-18: "it should be 1 ollama config for both options." Onboarding collects host + port + model once. On Enable, the same values are written to **both** config stores in a single persistence step:

1. **`AIAssistantConfigStore`** — adds `ollama` to `enabledProviders`, writes the remote endpoint into `providerCommandTemplates["ollama"]` (or an equivalent endpoint override field — see §9 in Implementation order).
2. **`LLMConfigStoreProtocol`** — saves `LLMProviderConfig.ollama(model:, baseURL:)` so Settings → AI Provider reflects the same endpoint. This makes Ollama immediately usable for the AI Formatter / live-cleanup path without the user re-entering the URL.

If the user later changes the Ollama endpoint in either Settings panel, the two stores diverge — same as today. Onboarding just seeds both from one input.

### 5. Model picker populates from `/api/tags`

Once Ollama responds (local or remote), the card shows an actual dropdown of installed models — not a free-text field. Less typing, no typos, signals what's available.

### 6. Remote-Ollama errors surface inline, specific

Connection refused / timeout / TLS / JSON parse failures each map to a specific message on the card so the user can diagnose. Generic "couldn't reach — check host and port" is only the fallback when the error is unclassifiable.

### 7. `hotkey` step becomes plural and live

Rename in-place to "Hotkeys" (icon stays `keyboard`) and upgrade the body to document both defaults with a live press-detection demo for each:

- Two stacked rows — one for each hotkey (Right Option / Fn).
- Each row has a labeled "press indicator" that lights up while the key is held down and confirms "✓ Detected" once released. No transcription, no AI invocation — just visual confirmation that macOS is delivering the keyDown/keyUp events to MacParakeet (i.e., Accessibility is granted and the hotkey manager is registered).
- Failure mode: if the press indicator doesn't light up within 15 seconds of the user trying, show a "Nothing detected? Check Accessibility permission" link that deep-jumps back to the `.accessibility` step.

Full dictation / AI-bubble round-trip demos are explicitly deferred — they would require selection capture, STT pipeline, and bubble rendering inside the onboarding window, none of which are on the critical path. Press detection alone tells the user "the hotkey is wired." That's enough.

### 8. ADR-005 amendment, not new ADR

Same pattern as the 2026-04-10 Screen Recording amendment. Append a dated note listing the new step. No new ADR because this is an additive, optional step fitting the existing "linear, step-based" pattern the ADR already locks.

## Implementation order

Keep each step independently mergeable. Run `swift test` after each.

1. **Detection helper** — add `LocalCLIExecutor.resolve(binary:)` returning `URL?`. Unit-tested with a fake shell harness (reuse the existing `discoverPATH` test scaffolding).
2. **Ollama probe service** — new `OllamaReachability` (struct or enum) with `check(baseURL:) async -> Result<[String], ProbeError>`. Separate file, Core target. Unit-tested with URLProtocol mock.
3. **ViewModel** — `AIAssistantOnboardingViewModel` in `MacParakeetViewModels`. Sub-state enum, enable-provider set, remote-Ollama draft, default-provider selection, persistence helper that writes `AIAssistantConfig` + optionally `LLMProviderConfig.ollama(...)`.
4. **Step insertion** — add `.aiAssistant` case to `OnboardingViewModel.Step`; wire sidebar icon/title; extend `canContinueFromCurrentStep()` to always-true; update any `allCases`-driven count in tests.
5. **View** — `AIAssistantOnboardingContainerView` in `Views/Onboarding/`. Switches on sub-state. Pulls `AIAssistantOnboardingViewModel` from the coordinator.
6. **Hotkey step copy update** — in `OnboardingFlowView`, update the `hotkey`-case title to "Hotkeys" and body to the two-line template.
7. **ADR-005 amendment** — append dated note.
8. **Tests** — ViewModel tests for each sub-state transition, detection branching, remote-Ollama validation, persistence payload shape. Reuse `OnboardingViewModelTests` structure where possible.

## Testing

| Layer | What |
|---|---|
| Unit (`LocalCLIExecutor.resolve`) | resolves binary on PATH, returns nil when missing, respects shell-probe fallback order |
| Unit (`OllamaReachability`) | 200 + JSON → models list; 200 + bad JSON → parse error; 404 → http error; connection refused → network error; timeout → timeout error |
| ViewModel (`AIAssistantOnboardingViewModel`) | card ordering, intro-skip bypasses rest, per-card Enable adds to enabled set, per-card Skip doesn't, remote-Ollama "Yes" expansion, "Test connection" routes through OllamaReachability mock, "Finish" with zero-enabled writes nothing, "Finish" with N-enabled writes expected config payload |
| ViewModel (`OnboardingViewModel`) | `.aiAssistant` step is reachable from `.hotkey`, `canContinueFromCurrentStep()` always true, `allCases`-driven step count updated |

No SwiftUI view tests (policy per CLAUDE.md).

## Risks

- **Detection timing.** `discoverPATH` runs an external shell. If it's slow or a shell is misconfigured, the Claude/Codex/Gemini cards could feel sticky. Mitigation: run detection when the user enters the step, show a spinner, cache the PATH result across cards.
- **Ollama port collision.** If some unrelated service listens on `localhost:11434`, GET `/api/tags` might return unexpected content. JSON parse will catch it; surface as a parse-error state, not a false positive.
- **Upgrade collision with existing users.** An existing user whose `AIAssistantConfig` is already saved won't see onboarding — but their `hotkeyTrigger` field persists. If it's nil in their config (they never customized), they now fall back to `.fn` instead of the old Control+Option+Shift combo. Acceptable — `.fn` is the new ship default and the Settings UI still lets them rebind.
- **Tailscale reachability.** On a Mac that isn't yet added to the user's tailnet, the remote-Ollama card will accept a `*.ts.net` hostname but DNS resolution fails until the device joins the tailnet. Expected — user skips the card, enables local providers, and sets up Tailscale separately.

## Open questions

None at plan-write time. All design decisions above were confirmed in the 2026-04-18 planning conversation.

## Follow-up plans (not this one)

- Shared capability-based readiness coordinator (unifying onboarding and Settings permission/provider state) — reference the Screen Recording plan's follow-up for the same architectural idea.
- Onboarding re-entry: allow users who skipped the AI step to return to just that step from Settings → "Reconfigure AI Assistant…" — currently requires a full onboarding relaunch.
- Install-from-onboarding: detect missing CLI → surface `brew install / npm install -g` command copy-paste. Explicitly deferred per 2026-04-18 decision.
