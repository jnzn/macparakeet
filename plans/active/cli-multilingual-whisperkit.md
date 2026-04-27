# Plan: macparakeet-cli multilingual STT via WhisperKit

> Status: **ACTIVE**
> Author: Daniel + agent (Claude)
> Date: 2026-04-27 (cut to actually-simple after self-correction on cross-process ANE extrapolation)
> Targets: CLI 1.3.0, MacParakeet v0.7.x

---

## TL;DR

Add WhisperKit as a second STT engine in `macparakeet-cli`. Parakeet stays the default. User opts in to WhisperKit when they have languages outside Parakeet's coverage.

```
macparakeet-cli transcribe file.wav                                  # → Parakeet (default, fast)
macparakeet-cli transcribe file.wav --engine whisper                 # → WhisperKit (slower, 99 languages)
macparakeet-cli transcribe file.wav --engine whisper --language ko   # → WhisperKit forced to Korean
```

**No auto-routing, no cross-process coordination, no abstraction layers.** User passes a flag, CLI dispatches, done.

---

## Language coverage (user-facing doc copy)

Parakeet TDT v3 is the high-quality default for languages it supports. Whisper is the escape hatch for everything else.

**Important runtime nuance (verified against FluidAudio 0.14.1 source):** `TokenLanguageFilter`'s `Language` enum has no CJK entries — only Latin/Cyrillic, 21 cases. The `tdtJa` decode path bypasses token language filtering entirely. So `--language` is effectively a no-op for any non-Latin/Cyrillic target with `--engine parakeet`. We silently don't pass the hint to Parakeet in those cases (no error, no warning).

| If your audio is… | Use | Notes |
|---|---|---|
| English or one of the 25 European languages Parakeet supports | **Parakeet (default)** | Fastest, highest quality on Apple Silicon. Just `transcribe file.wav`. |
| Japanese or Mandarin | **Parakeet** first; switch to Whisper if quality isn't adequate | Parakeet's `tdtJa`/`tdtZh` decode paths handle these. `--language` is ignored by Parakeet (auto-detect). |
| Korean, or any other language | **Whisper** | Pass `--engine whisper` (and optionally `--language <bcp47>`). |

No quantitative WER claims. User picks.

---

## What we're building

```
1. Add `argmaxinc/argmax-oss-swift` dep to Package.swift
   - Pin to a specific tag
   - Reference only the WhisperKit product: .product(name: "WhisperKit", package: "argmax-oss-swift")
   - This is a meta-package; without explicit product naming, SpeakerKit + TTSKit get dragged in

2. New: Sources/CLI/Engines/WhisperEngine.swift
   - Actor wrapping WhisperKit
   - One static factory: `WhisperEngine.make(model:) async throws -> WhisperEngine`
   - One method: `transcribe(audioURL:language:onProgress:) async throws -> STTResult`
   - Maps WhisperKit's TranscriptionResult to existing STTResult (text + words)
   - Conditionally compiled: #if canImport(WhisperKit)

3. Modify: Sources/CLI/Commands/TranscribeCommand.swift
   - Add `--engine [parakeet|whisper]` flag (default: parakeet)
   - Add `--language <bcp47>` flag
   - Switch on engine: parakeet → existing STTClient path; whisper → WhisperEngine
   - Pass --language to WhisperKit always; pass to Parakeet only if FluidAudio Language enum has it (silently drop otherwise)

4. Modify: Sources/CLI/Commands/ModelsCommand.swift
   - Extend `models download <variant>` to recognize whisper-* identifiers
   - For whisper-*, call WhisperKit.download(variant:progressCallback:) — Argmax handles the actual download
   - Storage: ~/Library/Application Support/MacParakeet/models/stt/whisper/<variant>/
   - Override WhisperKit's HF cache default so deleting MacParakeet wipes everything

5. Help text + CHANGELOG + brief integrations/README.md note about engine selection
```

That's the whole feature. Maybe 300-400 lines of code. A few days for a senior engineer.

---

## What we're NOT doing in v1 (and why)

- **Cross-process ANE lock.** Theoretical risk, no observed instances on macOS. macOS has `anecompilerservice` daemon for exactly this mediation; many CoreML apps (Photos, Mail, MacWhisper, VoiceInk, Hex) coexist in production without cross-process locks. If we see a real crash post-ship, we add ~50 lines of `flock` then.
- **`STTProvider` protocol + `STTRuntime` refactor.** Only justified by the lock above. No lock → no refactor → GUI hot path stays out of the diff.
- **`STTTranscription` wrapper / `--include-metadata` flag.** Defer. JSON envelope stays byte-identical to v1.2.
- **`models verify --sha256`.** WhisperKit handles its own download integrity. Defer until users ask.
- **Disk preflight, retry/backoff with jitter, per-variant locks, stale-file reapers.** Defensive engineering for risks that may not be real. OS errors are reasonable user feedback. Add when we see actual operational pain.
- **New telemetry events / `cliWarmupStarted` bracketing.** Existing `cliOperation` event is sufficient for v1. Adding new events triggers the two-repo allowlist coordination — defer until we have something to instrument.
- **Auto-routing / `--engine auto`.** Speculative product complexity. Defer to v0.8+ if there's demand.
- **Streaming, translation mode, multiple languages, GUI multilingual UX.** All v0.8+ or later.

The discipline here: ship the feature; defer defensive work until evidence shows it's needed.

---

## Implementation notes (things to know during coding, not as gating spikes)

- **WhisperKit Sendable / @MainActor.** WhisperKit 1.x has had `@MainActor`-bound progress callbacks. CLI runs without an `NSApplication` run loop, so `@MainActor` hops can deadlock. If you hit this during implementation: wrap `WhisperKit` calls in `Task { @MainActor in ... }` blocks, or use `dispatchMain()`. Verify on the version we pin; if it's been fixed in current `argmax-oss-swift`, no work needed.
- **Audio normalization is already done.** `Sources/CLI/AudioFileConverter.swift` produces 16 kHz mono Float32 WAV (`-ar 16000 -ac 1 -acodec pcm_f32le`). `WhisperEngine.transcribe()` receives the converted file URL — FFmpeg runs once.
- **Watchdog cold-start gotcha.** If the CLI gains a no-progress watchdog later (not in v1), it must only start ticking *after* the first progress event from the engine. WhisperKit prewarm can take >60s on M1/M2; a watchdog that ticks during specialization would kill first-runs.
- **WhisperKit issue #300:** `loadModels()` duplicates `.bundle` files in memory each call. Reuse the `WhisperKit` instance within a CLI invocation; never re-init.
- **JSON envelope contract:** existing v1.2 is flat `{ ok, error, errorType }` (in `Sources/CLI/CHANGELOG.md`). Don't break it. v1.3.0 adds engine support without changing this shape.
- **In-process double-load:** the CLI is one-engine-per-process by construction. We don't need an in-process semaphore in v1. If we ever load both engines in one process (e.g., a future server mode), revisit.
- **`models download parakeet`** — currently the GUI's onboarding handles this. Headless CLI users may need an explicit command in a follow-up. Out of scope for v1 (Parakeet onboarding still required).

---

## Risks

| Risk | Probability | Impact | Mitigation |
|---|---|---|---|
| WhisperKit `@MainActor` deadlock in headless CLI | Possible (version-dependent) | High (CLI hangs) | Verify during implementation; `Task { @MainActor in ... }` wrapper if needed |
| `argmax-oss-swift` meta-package drags in SpeakerKit/TTSKit | Real | Low (binary bloat) | Explicit `.product(name: "WhisperKit", package: "argmax-oss-swift")` |
| WhisperKit Korean output is unusable in practice | Low | High | Reversal trigger #3 below; integrate Qwen3-ASR or other |
| Demand for multilingual is thin | Real (unverified) | Medium | Ship cheaply; success metrics are targets, not baselines |
| Watchdog kills legitimate long transcribes | N/A (no watchdog in v1) | — | Defer until needed |

---

## Reversal triggers (when to reconsider engine choice)

Revisit WhisperKit if:

1. **Argmax ships Qwen3-ASR (or equivalent)** in WhisperKit. Verifiable from their releases.
2. **`mlx-qwen3-asr` reaches agent-grade quality** — tagged release, green CI on macOS 14+, zero open P0 for ≥30 days, ≥50 external transcribe operations without crash, mature Swift wrapper.
3. **Field signal:** ≥3 distinct agent operators report "WhisperKit Chinese (or other CJK) output is unusable for my use case."
4. **Quality benchmark:** Qwen3-ASR achieves ≥10% relative CER improvement on our own Mandarin/Japanese/Korean corpus.
5. **Apple ships native multilingual ASR** with WER ≤10% relative penalty vs Whisper-large-v3 on FLEURS-30.

When any trigger fires, integrate as a third engine — don't replace WhisperKit.

---

## License inventory (verified 2026-04-26)

| Component | License | GPL-3.0 compatibility |
|---|---|---|
| `argmaxinc/argmax-oss-swift` (WhisperKit) | MIT | ✅ |
| `FluidInference/FluidAudio` (existing) | Apache 2.0 | ✅ |
| OpenAI Whisper model weights | MIT | ✅ |
| NVIDIA Parakeet TDT v3 weights | CC-BY-4.0 | ✅ (attribution-only) |

**Deliverable:** add `THIRD_PARTY_LICENSES.md` at repo root. `--version --verbose` mentions Parakeet (CC-BY-4.0) and Whisper via WhisperKit (MIT) to satisfy CC-BY attribution.

---

## Success signals (4–8 weeks post-ship)

Demand evidence is thin. OpenClaw/Hermes integration docs are boilerplate. Metrics below are targets with no baseline.

- WhisperKit `--engine whisper` invocation rate ≥5% of CLI transcribes (telemetry, opt-in)
- ≤1 P0 issue from agent operators on the Whisper path in first month
- ≥1 external "macparakeet-cli for non-English transcription" guide published
- Argmax issue tracker: zero new MacParakeet-specific bug reports

Bad ship: Whisper usage <1%; or P0 reports of unusable Korean → reversal triggers fire.

---

## References

### Internal
- `Sources/CLI/CHANGELOG.md` — v1.2 envelope contract (do not break)
- `plans/active/cli-as-canonical-parakeet-surface.md` — broader CLI positioning
- `Sources/CLI/AudioFileConverter.swift` — produces 16 kHz mono Float32 WAV

### External
- `argmaxinc/argmax-oss-swift` — WhisperKit, pinned product at meta-package level
- FluidAudio 0.14.1 — `TokenLanguageFilter.swift` `Language` enum (Latin/Cyrillic only); `AsrManager.swift` `tdtJa`/`tdtZh` paths

### Multi-LLM review (2026-04-27)
3 Gemini + 3 Codex reviewers ran against the prior 774-line draft. Their HIGH/CRITICAL findings:
- **FluidAudio CJK enum gap** (Codex 3) → reflected in language coverage table above
- **JSON envelope contract preservation** (Gemini 3) → no envelope changes in v1
- **Cross-process ANE collision** (Gemini 1+2) → **rejected after self-audit:** the failure mode was extrapolated from iOS in-process behavior to a hypothetical macOS cross-process scenario. macOS has daemon mediation; no observed instances. Dropping the lock + the `STTRuntime` refactor + the `STTProvider` protocol that the lock necessitated.
- **Operational discipline (retries, preflight, locks, telemetry coordination)** (Codex 1+2) → **deferred** as defensive engineering for unobserved risks; add when evidence shows need.

The reviews surfaced real things the prior plan got wrong (FluidAudio enum, JSON envelope) and correctly identified theoretical risks. Folding every theoretical risk in turned a 4-day feature into a 4-week project. Ship the feature; iterate from telemetry.
