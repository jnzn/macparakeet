# ADR 005: First-Run Onboarding Window

Date: 2026-02-10
> Note: Qwen LLM warm-up step referenced below was removed 2026-02-23. As of 2026-04-06, onboarding prepares the local speech stack: Parakeet STT plus any required default-on speaker-detection assets. Addendum 2026-04-10: onboarding now includes an optional Screen & System Audio Recording step for meeting capture. Addendum 2026-04-18: onboarding now includes an optional "Ask AI Assistant" step (after Hotkeys, before Speech Stack) that detects installed Claude Code / Codex / Gemini CLIs via the user's login-shell PATH, probes any local or remote (Tailscale / LAN) Ollama daemon over HTTP, and writes the user's choices to `AIAssistantConfigStore` (and, for Ollama, also `LLMConfigStore`). Each provider card has Enable / Skip; skip-all is valid and writes nothing. The Hotkeys step (formerly singular) was renamed to plural and now demos both default hotkeys (right-Option for dictation, Fn / Globe for AI Assistant) with live press detection.

## Context

MacParakeet is a menu bar app with a configurable global hotkey (default: Fn) and paste automation. To deliver a premium first-run experience, we need to:

- Explain the core interaction model (hotkey, stop/paste, cancel).
- Acquire permissions (Microphone, Accessibility, plus optional Screen Recording for meeting capture).
- Prepare the local speech stack so dictation and default-on file-transcription features are ready on first use.

Without onboarding, users encounter failures out of context (missing permissions, slow first warm-up) and the product feels brittle.

## Decision

Implement a dedicated first-run onboarding window that appears automatically when the app starts and onboarding has not been completed.

The onboarding flow is linear and step-based:

1. Welcome
2. Microphone permission
3. Accessibility permission
4. Meeting recording permission (optional Screen & System Audio Recording)
5. Hotkeys instructions (live press demo for both default keys: right-Option for dictation, Fn / Globe for AI Assistant)
6. Ask AI Assistant (optional; detects Claude Code / Codex / Gemini on PATH, probes local + remote Ollama daemons, fans Ollama config out to both `AIAssistantConfigStore` and `LLMConfigStore`; skip-all valid)
7. Speech stack setup (Parakeet + required speaker-detection assets, retry available)
8. Ready

The onboarding can also be launched manually from Settings.

If onboarding is closed before completion, the app shows an explicit confirmation dialog. If the user exits setup anyway, onboarding is shown again on the next app activation until completion.
During speech-stack setup, onboarding runs lightweight preflight checks (disk space + network readiness) before downloading required assets.
While onboarding is visible, permission state is polled so changes made in System Settings are reflected automatically.

## Consequences

- Users get a guided, premium setup that reduces first-run friction.
- Hotkey manager is restarted after onboarding to reliably start listening once Accessibility is granted.
- The Parakeet STT model is downloaded/warmed during onboarding to reduce first-use latency for dictation.
- If speaker detection is enabled by default, its diarization assets are also prepared before onboarding reports file transcription ready.
- Preflight checks fail fast with actionable guidance, reducing avoidable warm-up failures.
- Onboarding completion is stored in `UserDefaults` as an ISO8601 timestamp.
- Incomplete setup is never silently dismissed; users either continue setup or explicitly defer it.

## Alternatives Considered

- Inline onboarding inside the main window: rejected because the app is menu-bar-first and may never open the main window on first launch.
- No onboarding: rejected due to permission and warm-up failures appearing as unexplained errors.
