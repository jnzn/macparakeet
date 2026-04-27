# Plan: MacParakeet multilingual support via WhisperKit

> Status: **ACTIVE**
> Author: Daniel + agent (Claude)
> Date: 2026-04-27 (expanded from CLI-only to full multilingual: CLI + dictation + meeting recording, single PR)
> Targets: CLI 1.3.0, MacParakeet v0.7.0

---

## TL;DR

Add WhisperKit as a second STT engine across **all three MacParakeet surfaces**: CLI file transcription, GUI dictation, GUI meeting recording. Parakeet stays the default everywhere. One Settings toggle flips the GUI between engines; CLI takes a `--engine` flag per invocation.

**CLI usage:**
```
macparakeet-cli transcribe file.wav                                  # → Parakeet (default, fast)
macparakeet-cli transcribe file.wav --engine whisper                 # → WhisperKit (slower, 99 languages)
macparakeet-cli transcribe file.wav --engine whisper --language ko   # → WhisperKit forced to Korean
```

**GUI:** Settings → Speech Recognition → toggle Parakeet ↔ Whisper. Affects dictation hotkey + meeting recording transcription.

**Single PR.** Integration cost is small once `WhisperEngine` exists — same engine wrapper used by all three surfaces. Doing it all together delivers "MacParakeet supports Korean" as one coherent ship moment, instead of a half-shipped state where CLI works but GUI doesn't.

**Primary user:** Daniel consumes Korean content (YouTube videos, podcasts, meetings). Wants every MacParakeet surface to handle Korean — transcribe Korean videos via CLI, dictate Korean via hotkey, record Korean meetings. WhisperKit's broader multilingual coverage (Vietnamese, Thai, Hindi, Arabic, 95+ others) is a free side-benefit of the same code paths.

**No auto-routing, no abstraction layers, no protocol/registry.** Two engines, switch-statement dispatch.

---

## Language coverage (user-facing doc copy)

Parakeet TDT v3 is the high-quality default for languages it supports. Whisper is the escape hatch for everything else.

**Important runtime nuance (verified against FluidAudio 0.14.1 source):** `TokenLanguageFilter`'s `Language` enum has no CJK entries — only Latin/Cyrillic, 21 cases. So `--language` is a no-op for any non-Latin/Cyrillic target with `--engine parakeet`. We silently don't pass the hint to Parakeet in those cases (no error, no warning).

| If your audio is… | Use | Notes |
|---|---|---|
| English or one of the 25 European languages Parakeet supports | **Parakeet (default)** | Fastest, highest quality on Apple Silicon. |
| Japanese or Mandarin | **Parakeet** first; switch to Whisper if quality isn't adequate | Parakeet's `tdtJa`/`tdtZh` decode paths handle these. `--language` is ignored (auto-detect). |
| Korean, or any other language | **Whisper** | Whisper supports 99 languages. |

No quantitative WER claims. User picks.

---

## What we're building

### Shared core (used by all three surfaces)

- **`Sources/MacParakeetCore/STT/WhisperEngine.swift`** — actor wrapping `WhisperKit`. One static factory `WhisperEngine.make(model:)`, one method `transcribe(audioURL:language:onProgress:) -> STTResult`. Conditionally compiled `#if canImport(WhisperKit)`.
- **`Sources/MacParakeetCore/Settings/SpeechEnginePreference.swift`** — small enum `{ parakeet, whisper }` + UserDefaults persistence + default-language pref.
- **`Package.swift`** — add `argmaxinc/argmax-oss-swift` dep. **Important:** explicit product reference `.product(name: "WhisperKit", package: "argmax-oss-swift")` — meta-package would otherwise pull in SpeakerKit + TTSKit.

### CLI (file transcription)

- **Modify `Sources/CLI/Commands/TranscribeCommand.swift`:** add `--engine [parakeet|whisper]` flag (default parakeet) + `--language <bcp47>`. Switch on engine: parakeet → existing `STTClient` path; whisper → `WhisperEngine`.
- **Modify `Sources/CLI/Commands/ModelsCommand.swift`:** extend `models download <variant>` to recognize `whisper-*` identifiers. For whisper-*, call `WhisperKit.download(variant:progressCallback:)`. Storage at `~/Library/Application Support/MacParakeet/models/stt/whisper/<variant>/`.
- **Help text + CHANGELOG entry.**

### GUI dictation

- **Modify `Sources/MacParakeetCore/STT/STTRuntime.swift`:** read `SpeechEnginePreference` at the entry point of dictation transcription. If `parakeet` (default) → existing path unchanged. If `whisper` → route to `WhisperEngine`. Lazy-load Whisper on first use after toggle; unload Parakeet from ANE when Whisper is active to free working memory (and vice-versa).
- **Dictation overlay (`Sources/MacParakeet/Views/Dictation/...`):** when engine is Whisper, show a "Transcribing…" state on the overlay between hotkey release and text paste (Whisper takes ~2-5 seconds for a 5-second clip). Existing overlay's recording state stays the same; only the post-release period gets the new state.
- **Settings UI (below):** the toggle gates this entire path.

### GUI meeting recording

- **Modify `Sources/MacParakeetCore/STT/...`** (wherever meeting transcription dispatches): read `SpeechEnginePreference` at meeting transcription time (post-recording). Audio capture is engine-agnostic — the change only affects transcription dispatch.
- **No UI change to the recording flow itself.** Recording captures audio same way; transcription engine is the only thing that changes.
- Meeting transcription is async/batch — Whisper's latency doesn't matter here.

### Settings UI

New section in `Sources/MacParakeet/Views/Settings/...`:

```
Speech Recognition
──────────────────
●  Parakeet (default)   Fast. English + 25 European languages + Japanese + Mandarin.
○  Whisper              Slower. 99 languages including Korean.

  When using Whisper:
  • Dictation has a 2-5 second delay (vs Parakeet's near-instant response)
  • First use after switching loads the model (~5-15 seconds)
  • Meeting transcription quality benefits from picking the right language below

Default language for Whisper:  [ Auto-detect ▼ ]   (only used with Whisper)
```

~50 lines of SwiftUI. Pref persists via UserDefaults.

---

## What we're NOT doing

- **Per-surface toggles** (separate Whisper-for-dictation vs Whisper-for-meeting). One toggle covers GUI surfaces. If users ask for split control later, add it.
- **Auto-detection / `--engine auto`.** Speculative product complexity. v0.8+ if demand surfaces.
- **Streaming WhisperKit (`--stream`).** v0.8+
- **WhisperKit translation mode (`--task translate`).** Defer.
- **Mid-session engine switching.** Toggle is a Settings change between sessions; not changeable mid-recording or mid-dictation.
- **Cross-process ANE coordination.** macOS daemon mediates; many CoreML apps coexist in production without locks. Add ~50 lines of `flock` only if real crashes appear post-ship.
- **`STTProvider` protocol + registry.** Two engines, switch-statement dispatch. Add abstraction when a third engine arrives.
- **`models verify --sha256`.** WhisperKit handles its own integrity. Defer.
- **Disk preflight, retry/backoff, per-variant locks.** Defensive engineering for unobserved risks. Add if we see operational pain.
- **`STTTranscription` wrapper / `--include-metadata` flag.** v0.7 ships byte-identical v1.2 JSON envelope.
- **Telemetry allowlist coordination.** Existing `cliOperation` event is sufficient. Add new events only when we have specific reason.

---

## Implementation notes (things to know during coding, not as gating spikes)

- **WhisperKit Sendable / @MainActor.** WhisperKit 1.x has had `@MainActor`-bound progress callbacks. Verify on the version we pin; if hops to MainActor deadlock the CLI (no `NSApplication` run loop), wrap calls in `Task { @MainActor in ... }`. The GUI doesn't have this concern.
- **Audio normalization is already done.** `Sources/CLI/AudioFileConverter.swift` produces 16 kHz mono Float32 WAV. Both engines receive the converted file URL. FFmpeg runs once.
- **Engine switching evicts ANE.** When the user toggles in Settings, the previously-active engine should `unload()` so the new one can specialize without ANE memory pressure. Toggle only happens between sessions — not in the middle of a dictation.
- **First-use after toggle pays specialization cost.** Communicate this in Settings copy. Lazy-load on first dictation/meeting transcription rather than at app launch.
- **WhisperKit issue #300:** `loadModels()` duplicates `.bundle` files in memory each call. Reuse the WhisperKit instance within a session.
- **JSON envelope contract:** existing v1.2 in `Sources/CLI/CHANGELOG.md` is flat `{ ok, error, errorType }`. v1.3.0 adds `--engine` support without changing this shape.
- **In-process double-load:** the GUI loads only one engine at a time (toggle determines which). The CLI loads only one per invocation. Never both simultaneously. So we don't need an in-process semaphore.
- **Cross-process (GUI + CLI both running):** macOS daemon mediates ANE access. Memory is fine — Parakeet ~66 MB ANE working set + WhisperKit large-v3-turbo ~600 MB working set, in separate process address spaces.

---

## Risks

| Risk | Probability | Impact | Mitigation |
|---|---|---|---|
| WhisperKit `@MainActor` deadlock in headless CLI | Possible (version-dependent) | High (CLI hangs) | Verify during impl; `Task { @MainActor in ... }` wrapper if needed |
| `argmax-oss-swift` meta-package drags in SpeakerKit/TTSKit | Real | Low (binary bloat) | Explicit `.product(name: "WhisperKit", ...)` |
| Korean transcription quality unusable in practice | Low (Whisper is well-validated on Korean) | High (kills the load-bearing use case) | Daniel sniff-tests on real Korean content during dev; reversal triggers below |
| Dictation latency on Whisper is unacceptable | Real (2-5 sec is slow) | Low (users self-select via toggle, copy sets expectation) | Settings copy clearly states the trade-off |
| Engine toggle leaks ANE memory across switches | Possible | Medium | `unload()` previous engine when toggle fires |
| CLI invocation while GUI is active triggers ANE collision | Theoretical, no observed instances on macOS | High if real | Ship without lock; `flock` fast-follow if telemetry shows crashes |

---

## Reversal triggers (when to reconsider engine choice)

Revisit WhisperKit if:

1. **Argmax ships Qwen3-ASR (or equivalent)** in WhisperKit. Verifiable from their releases.
2. **`mlx-qwen3-asr` reaches agent-grade quality** — tagged release, green CI on macOS 14+, zero open P0 for ≥30 days, ≥50 external transcribe operations without crash, mature Swift wrapper.
3. **Field signal:** ≥3 distinct users report "WhisperKit Chinese (or other CJK) output is unusable for my use case."
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

## Implementation order (within the single PR)

Not phases-with-gates — just a suggested order for the implementing engineer:

1. **Add WhisperKit dep** to `Package.swift` with explicit product reference.
2. **Implement `WhisperEngine.swift`** in `MacParakeetCore`. Basic actor + transcribe method + STTResult mapping. Verify it works in isolation via a unit test or scratch script.
3. **Add CLI surface** — `--engine` flag, `--language` flag, `models download whisper-*`. CLI is the easiest validation surface.
4. **Daniel sniff-tests Korean content via CLI.** Run `macparakeet-cli transcribe <korean.mp3> --engine whisper --language ko`. Verify quality is adequate. **This is the load-bearing decision point** — if Korean output is unusable, the rest of the PR is wasted; reversal triggers fire.
5. **Add `SpeechEnginePreference` + UserDefaults plumbing.**
6. **Wire `STTRuntime` to read pref and dispatch.**
7. **Settings UI** with toggle + language picker + latency copy.
8. **Dictation overlay "Transcribing…" state.**
9. **Meeting recording dispatch.**
10. **CHANGELOG, integrations docs, THIRD_PARTY_LICENSES.**
11. **Tests** — engine routing, toggle persistence, lazy-load + unload lifecycle, Korean sniff test on a known-good fixture.

Total estimate: ~5-7 days of focused work for a senior engineer.

---

## Success signals

The honest validation:
1. **Daniel transcribes Korean YouTube content via CLI** — output is good enough to read.
2. **Daniel dictates Korean text** via the GUI hotkey — text appears, accepts the latency.
3. **Daniel records a Korean meeting** and the post-recording transcription is usable.

If all three work for Daniel on real Korean content, the feature ships and is a success regardless of broader uptake.

Secondary signals (4–8 weeks post-ship, gravy):
- Non-zero opt-in usage of Whisper toggle / CLI flag — proves the option is reachable for users beyond Daniel
- ≤1 P0 issue on the Whisper path in first month
- Anyone publishing a "MacParakeet for Korean (or other) transcription" writeup

Bad ship: Korean output is unusable in practice → reversal triggers fire toward Qwen3-ASR.

---

## References

### Internal
- `Sources/CLI/CHANGELOG.md` — v1.2 envelope contract (do not break)
- `plans/active/cli-as-canonical-parakeet-surface.md` — broader CLI positioning
- `Sources/CLI/AudioFileConverter.swift` — produces 16 kHz mono Float32 WAV (used by both engines)
- `Sources/MacParakeetCore/STT/STTRuntime.swift` — current Parakeet-only dispatch; gets a toggle-based switch in this PR

### External
- `argmaxinc/argmax-oss-swift` — WhisperKit, pinned product at meta-package level
- FluidAudio 0.14.1 — `TokenLanguageFilter.swift` `Language` enum (Latin/Cyrillic only); `AsrManager.swift` `tdtJa`/`tdtZh` paths
- VoiceInk, Hex, Dictus — shipping examples of dual Parakeet + WhisperKit (single-process GUI architectures; informed our switch-statement-not-protocol decision)

### Multi-LLM review (2026-04-27, initial CLI-only scope)
3 Gemini + 3 Codex reviewers ran against an earlier 774-line draft. Their HIGH/CRITICAL findings:
- **FluidAudio CJK enum gap** (Codex 3) → reflected in language coverage table
- **JSON envelope contract preservation** (Gemini 3) → no envelope changes in v1
- **Cross-process ANE collision** (Gemini 1+2) → rejected after self-audit; was extrapolation from iOS to macOS without observed evidence
- **Operational discipline (retries, preflight, locks, telemetry coordination)** (Codex 1+2) → deferred as defensive engineering for unobserved risks

Strategy unchallenged: zero reviewers questioned Parakeet-default + Whisper-opt-in or WhisperKit-over-Qwen3.
