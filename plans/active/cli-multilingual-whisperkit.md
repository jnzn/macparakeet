# Plan: macparakeet-cli multilingual STT via WhisperKit

> Status: **ACTIVE**
> Author: Daniel + agent (Claude)
> Date: 2026-04-27 (split into PR 1 / PR 2 after pre-implementation review)
> Targets: CLI 1.3.0, MacParakeet v0.7.x
> Related: `plans/active/cli-as-canonical-parakeet-surface.md`, ADR-016 (centralized STT runtime + scheduler)

---

## TL;DR

**Decision (locked):** Add WhisperKit as a second STT engine in `macparakeet-cli`. **Parakeet remains the default.** Users explicitly opt in to WhisperKit when they know they have non-European audio.

```
macparakeet-cli transcribe file.wav                                  # → Parakeet (default, fast)
macparakeet-cli transcribe file.wav --engine whisper                 # → WhisperKit (slower, 99 languages)
macparakeet-cli transcribe file.wav --engine whisper --language ko   # → WhisperKit forced to Korean
```

**No auto-routing, no runtime language detection, no confidence thresholds, no drift handling.** User chooses the engine; CLI obeys.

### Two-PR approach (locked 2026-04-27)

Pre-implementation review surfaced a real risk: refactoring `STTRuntime` (the GUI's process-wide STT actor used by dictation + meeting recording) inside the multilingual PR puts the GUI hot path in the diff for a CLI-only feature. Different risk profiles deserve different PRs.

- **PR 1 (this plan, v0.7):** Add WhisperKit to CLI as a second engine. Internal `--engine` dispatch in CLI's `TranscribeCommand` — `parakeet` calls existing `STTClient` path; `whisper` calls a new CLI-local `WhisperEngine` wrapper. **No `STTProvider` protocol, no registry actor, no `STTRuntime` refactor.** GUI's dictation/meeting hot path is not in this PR's diff.

- **PR 2 (separate plan, target v0.7.x or v0.8):** Extract a shared `STTProvider` abstraction in `MacParakeetCore`; refactor both `STTRuntime` (GUI) and `STTClient` (CLI helpers) to consume it. GUI becomes multi-engine-capable. No CLI-visible behavior change. **Out of scope for this plan** — drafted when PR 1 ships and we have real WhisperKit operational data.

**Why the split:** "Add WhisperKit" is a capability ship — additive, CLI-scoped, easy to roll back. "Unify STT abstractions" is a refactor — touches the GUI hot path, broader review surface. Sequencing means PR 1 ships without re-validating dictation/meeting, and PR 2 inherits real WhisperKit lessons from PR 1 instead of guessing the abstraction shape upfront.

The CLI and GUI today already use parallel STT wrappers around `AsrManager` (`STTClient` for CLI, `STTRuntime` for GUI). They share FluidAudio underneath, not Swift code on the transcribe path. PR 1 leaves that parallelism intact.

**Why WhisperKit, not `mlx-qwen3-asr`:** Reliability beats novelty for an agent-facing surface. WhisperKit has 2+ years of production deployment across many shipping apps; our MLX port is 2 months old, single-maintainer, untested in production. `mlx-qwen3-asr` stays as a tracked v0.8+ strategic move when reversal triggers fire.

**Why no auto-routing:** detecting language at runtime is real product complexity (multi-point sampling vs first-30s, VAD-aware vs fixed offsets, confidence weighting, drift handling). All of it is speculative without agent-operator demand signal. Defer to v0.8+ when there's actual evidence users want auto-detection.

**v0.7 scope is file transcription only.** Dictation and meeting recording stay Parakeet-only forever (or until Parakeet-Multilingual ships).

---

## Pre-work — Parakeet CJK quality test (informational, not blocking)

The FluidAudio 0.12.4 README states:

> "Parakeet TDT v3 (0.6b) and other TDT/CTC models for batch transcription supporting 25 European languages, Japanese, and Chinese"

Without auto-routing, the architecture doesn't depend on this claim. But we still need to know **what to tell users in the docs.** If Parakeet handles Japanese well, "use the default for Japanese audio" is reasonable advice. If it doesn't, docs say "Japanese requires `--engine whisper`."

### Test protocol

Multi-condition corpus per language (Japanese, Mandarin only — Korean is not in Parakeet's supported set per FluidAudio README; testing it would burn hours for a row that's already locked to "use whisper"):

1. Clean broadcast — news clip — 2 min
2. Conversational — podcast/interview — 2 min
3. Meeting-quality — Zoom recording (low bitrate AAC) — 2 min
4. Noisy — overlay 10 dB SNR background noise — 2 min
5. Code-switching — English preamble + content — 2 min

Use **Common Voice** (Mozilla, CC-0) and **FLEURS** (Google, CC-BY-4.0) — freely redistributable, unlike NHK/CCTV broadcast clips.

Compute WER against published reference transcripts.

### Output

A documentation table — not a routing decision matrix:

| Language | Parakeet WER (clean) | Parakeet WER (noisy) | Recommendation in user docs |
|---|---|---|---|
| ja | TBD | TBD | TBD after test |
| zh | TBD | TBD | TBD after test |
| ko | n/a | n/a | Always use `--engine whisper` |

This goes in `integrations/README.md` and the `/agents` page on macparakeet.com.

---

## Architecture (PR 1 — minimal, no new abstractions)

The CLI's `TranscribeCommand` dispatches on `--engine` to one of two code paths united only by returning `STTResult`. **No shared protocol; no provider registry; no refactor of `STTRuntime` or `STTClient`.** Two parallel paths.

```swift
// Sketch — actual code in TranscribeCommand
let result: STTResult = switch options.engine {
case .parakeet:
    let client = STTClient()                    // existing CLI path, untouched
    try await client.transcribe(audioPath: audio, job: .file)
case .whisper:
    let engine = try await WhisperEngine.make(model: options.model)
    try await engine.transcribe(
        audioURL: audio,
        language: options.language,
        onProgress: progressCallback
    )
}
```

### What's untouched in PR 1

- `Sources/MacParakeetCore/STT/STTRuntime.swift` — GUI's process-wide actor; not in the diff
- `Sources/MacParakeetCore/STT/STTClient.swift` — Parakeet path; signature unchanged
- `Sources/MacParakeetCore/STT/STTClientProtocol.swift` — keeps existing shape
- ADR-016 `STTScheduler` — does not apply (CLI is per-process)
- Dictation, meeting recording, and GUI file transcription — not in the diff

### What's new in PR 1

- `Sources/CLI/Engines/CLITranscribeEngine.swift` — `enum { parakeet, whisper }` for `--engine` parsing + `BCP47Language` typealias
- `Sources/CLI/Engines/WhisperEngine.swift` — actor wrapping `WhisperKit`; returns `STTResult`
- `Sources/CLI/Engines/WhisperModelStore.swift` — Handy-style download discipline (resumable, SHA256, RAII cleanup)
- `Sources/CLI/Engines/TranscribeWatchdog.swift` — no-progress + optional hard-timeout
- `Sources/CLI/Commands/TranscribeCommand.swift` — engine dispatch (modified, ~30 LOC change)
- `Sources/CLI/Commands/ModelsCommand.swift` — extended for `whisper-*` model identifiers (modified)
- `Package.swift` — add `argmaxinc/argmax-oss-swift` dep, gated `#if canImport(WhisperKit)` per VOX

### Why no protocol in PR 1 (CLAUDE.md "no premature abstractions")

Three engines deep, a protocol earns its keep. With two engines and a single dispatch site (`TranscribeCommand`'s switch), the protocol is decorative weight that complicates the diff and locks in a shape we'll want to revise once WhisperKit operational reality lands.

`CLITranscribeEngine` is an enum, not a protocol — a tag for dispatch, not an interface. When PR 2 introduces `STTProvider` in `MacParakeetCore`, the enum stays as the `--engine` flag's parsing target; the dispatch becomes "look up provider by ID."

### CRITICAL — cross-process ANE specialization collision (new failure mode)

Dictus' learned-the-hard-way comment is about *in-process* simultaneous CoreML specialization:

> "Never run Parakeet model load simultaneously with WhisperKit prewarm. Both use the Neural Engine for CoreML compilation. Simultaneous compilation causes ANE 'E5 bundle' crashes."
> — `getdictus/dictus-ios:ParakeetEngine.swift:14-17`

PR 1 sidesteps the in-process variant (CLI is one engine per process) but introduces a new variant: **the CLI is a separate process from the GUI; both can attempt ANE specialization concurrently.**

Reproducer:
1. User has GUI running, Parakeet specialized for dictation
2. User runs `macparakeet-cli transcribe ja.wav --engine whisper` for the first time
3. CLI invokes `WhisperKit(WhisperKitConfig(prewarm: true))` → ANE specialization
4. If GUI is simultaneously specializing (e.g., user just launched the app) → potential E5 crash

**Honest assessment:** the in-process variant is documented and observed in iOS production. The cross-process variant is **plausible but not yet confirmed** — Dictus is a single-app codebase. CoreML on macOS may handle concurrent cross-process specialization fine via the OS-mediated `ane_compiler` daemon. We do not have direct evidence either way.

**Mitigation strategy (graduated):**

1. **PR 1 ships without a cross-process lock.** The single common case (user manually invokes CLI when GUI is steady-state) does not trigger the race. Document the known risk in `integrations/README.md` under "running CLI alongside the desktop app."

2. **If field reports surface E5 crashes** (telemetry: `cli_warmup_failed` events with ANE error signature; or P0 issue from agent operators): fast-follow with PR 1.5 — add a CLI-side advisory `flock` at `~/Library/Application Support/MacParakeet/.ane.lock`. CLI takes the lock during prewarm; releases after specialization. **One-sided** (GUI doesn't take it yet) but sufficient because the lock makes CLI wait if a prior CLI invocation is still specializing, and a startup race window check (sleep ~3s if `NSRunningApplication` shows `com.macparakeet.app` started in the last N seconds) covers GUI cold-start.

3. **PR 2 promotes the lock to two-sided** by having `STTRuntime.warmUp()` also take it. PR 1.5's CLI lock stays compatible.

This staged approach trades some risk of a P0 crash report for a much smaller PR 1 diff. If the empirical hit rate is zero, we never ship the lock. If it's non-zero, mitigation is ~50 lines of code and lands within days.

### Two-phase model lifecycle (from Argmax canonical pattern)

Argmax separates `WhisperKit.download(variant:progressCallback:) -> URL` (static) from `loadModels()` (instance, fast once cached). Adopt the same shape:

```bash
macparakeet-cli models download whisper-large-v3-turbo  # explicit, exits when done
macparakeet-cli models list --json                       # what's installed/available
macparakeet-cli models verify --sha256                   # post-download integrity
macparakeet-cli transcribe file.m4a --engine whisper     # never blocks on download
```

A transcribe call against a missing model emits a structured error pointing to the download command — never auto-downloads silently in the agent path.

### Download discipline (lifted from Handy)

| Property | Adopt |
|---|---|
| Resume from `.partial` via Range header + 206/200 fallback | ✅ |
| SHA256 verification post-download (background thread) | ✅ |
| RAII cleanup guard on every error path | ✅ |
| Atomic extract-to-temp-then-rename | ✅ |
| Throttled progress events (10/sec) | ✅ |
| Cancellation token per model | ✅ |
| Idle-unload watcher with recording-state gating | ⚠️ Defer to v0.7.x |

**Storage:** `~/Library/Application Support/MacParakeet/models/whisper/<variant>/`. Don't let WhisperKit default to its HF cache (`~/Library/Caches/argmaxinc/whisperkit/`) — keeps "delete MacParakeet → all data gone" expectation intact.

### Engine selection (replaces "auto-routing")

User chooses; CLI obeys.

| Caller intent | Command | Behavior |
|---|---|---|
| Default (English / European audio) | `transcribe file.wav` | Parakeet, fast |
| Non-European audio | `transcribe file.wav --engine whisper` | WhisperKit, slower, 99 languages |
| Force language to Whisper | `transcribe file.wav --engine whisper --language ko` | WhisperKit forced to Korean |
| Force language to Parakeet | `transcribe file.wav --engine parakeet --language ja` | **Soft-accept.** If FluidAudio 0.14.1's `AsrManager.transcribe()` accepts a language hint, pass it through. If it does not, the flag is silently ignored (Parakeet is auto-only); when `--include-metadata` is set, surface `"language_hint_ignored": true` in the metadata wrapper so callers can audit. **Never exit non-zero on this combination** — agents that pass `--language` uniformly across engines must keep working. |

**Why no auto-routing:** detecting language at runtime is real product complexity (multi-point sampling vs first-30s, VAD-aware vs fixed offsets, confidence weighting, drift handling). All of it is speculative without agent-operator demand signal. Defer to v0.8+ when there's actual evidence users want auto-detection.

When auto-routing eventually ships (if it ever does), it slots in as `--engine auto` without changing existing behavior. `--engine parakeet` and `--engine whisper` keep doing exactly what they do today.

### Audio normalization

WhisperKit hard-requires **16 kHz mono Float32**. The CLI already does FFmpeg-based decoding for non-WAV input; ensure the post-decode pipeline produces this format before handing off to either engine.

### Watchdog / hang detection (Gemini finding — day-one requirement)

WhisperKit issues #352, #410, #198 are real production hang reports. Agents that subprocess this CLI **cannot tolerate hangs** — accumulated ghost processes will degrade Mac mini deployments running OpenClaw/Hermes.

**Implementation:**

- `--timeout <seconds>` flag. **Default: 0 (disabled, opt-in only.)** Hard SIGTERM at expiry; exit code 6. The hard timeout is opt-in because legitimate transcribes can run for hours (multi-hour batch jobs, unattended overnight runs); defaulting to a hard ceiling silently kills real work.
- Internal progress watchdog: if no progress event from the engine for N seconds (default N=60), emit structured timeout error and exit. Exit code 6. **This is the always-on safety net** — it catches genuine engine hangs without killing long-but-progressing transcribes.
- All temp files cleaned up on signal-driven exit (RAII pattern from Handy).
- JSON envelope on hang exit:
  ```json
  {
    "error": { "code": "engine_hang", "engine": "whisper", "stalled_for_seconds": 60, "last_progress_pct": 0.42 }
  }
  ```

**Exit codes:**

| Code | Meaning |
|---|---|
| 0 | Success |
| 2 | Model missing / not downloaded |
| 3 | Audio file invalid / unreadable |
| 4 | Cancelled (SIGINT/SIGTERM from caller) |
| 5 | Model verification failed (SHA256 mismatch) |
| 6 | Engine hang / timeout |
| 7 | Invalid argument combination (genuinely malformed input — e.g., unknown engine name. **Not** used for `--language` with `--engine parakeet`, which is soft-accepted.) |

### JSON envelope additions (gated behind `--include-metadata`)

Both reviewers flagged that adding **any** new top-level field — even a `metadata` wrapper — breaks consumers with `additionalProperties: false` JSON Schema or Pydantic `extra='forbid'` parsers. **The honest fix: gate metadata behind a flag.**

Default (`--json` alone) emits **byte-identical v1.2 output**. Strict parsers continue to work unchanged.

Opt-in (`--json --include-metadata`) adds a `metadata` wrapper:

```jsonc
{
  "text": "...",                      // unchanged
  "words": [...],                     // unchanged (when --word-timestamps)
  "duration_seconds": 123.45,         // unchanged
  // ... all existing v1.2 top-level fields preserved verbatim ...

  "metadata": {                       // ← only present when --include-metadata
    "engine": "parakeet",             // matches --engine value (no camelCase drift)
    "model": "parakeet-tdt-0.6b-v3",  // exact model variant
    "language": "ja",                 // omitted unless user passed --language or engine reported it
    "schema_version": "1.3"
  }
}
```

**Why opt-in instead of always-on:** preserves the contract for v1.2-pinned strict parsers while letting agent operators who want engine info ask for it. Zero-risk migration: nobody breaks who didn't opt in.

CLI bumps to **1.3.0** — additive minor. No removed fields, no semantic changes to existing default behavior.

### CLI flag set (v0.7 — minimal and honest)

```
macparakeet-cli transcribe <input> [options]

  --engine [parakeet|whisper]     Default: parakeet
  --model <variant>                Override default model for chosen engine
  --language <bcp47>               Force decode language. Honored by Whisper; soft-accepted (or ignored) by Parakeet — never errors.
  --word-timestamps                Word-level timing in output
  --timeout <seconds>              Hard timeout, default 0 (disabled). Internal no-progress watchdog (60s) is always on.
  --include-metadata               Add metadata wrapper to --json output
  --json                           Machine-readable output (required for agents)

macparakeet-cli engines list [--json]
  Show available engines and their supported languages

macparakeet-cli models <subcommand>
  download <variant>               Explicit, exits when done. Resumable.
  list [--json]                    What's installed, what's available.
  verify [--sha256]                Post-download integrity check.
  delete <variant>                 Free disk space.
```

**Concurrency handled internally**, not exposed: auto-scale based on `ProcessInfo.processInfo.activeProcessorCount` and available memory. Exposing `--concurrent-worker-count` was a leaky abstraction (Gemini finding) that lets users thermally throttle their own machines.

**Deferred flags** (add when they have real behavior, document in CHANGELOG):

- `--task translate` — Whisper-only translation; requires translation pipeline + tests + docs
- `--clip-timestamps` — partial-file decode logic
- `--prompt` — Whisper decoding prompt; requires validation + docs
- `--chunking-strategy [none|vad]` — VAD integration
- `--report` — SRT writer + sidecar JSON spec
- `--output-dir` — sidecar file convention
- `--language ja,ko,en` (multiple languages) — anarlog pattern; defer until single-language ships
- `--engine auto` — runtime language detection + routing; defer until agent-operator demand signal

---

## Lessons from comparable projects (research synthesis)

Three subagents researched Handy/VoiceInk, hyprnote (now `fastrepl/anarlog`)/Granola, and WhisperKit official + multi-engine reference impls.

### From VoiceInk (Beingpax/VoiceInk) — the structural model

- **`TranscriptionService` protocol + registry** with provider-enum dispatch. Single-method protocol, lazy-instantiated concrete services per provider. Adding a backend = one new file. **Adopt.**
- **`TranscriptionModel` protocol** as unified model descriptor (`id/name/provider/isMultilingualModel/supportedLanguages`). Concrete structs per backend. **Adopt.**

### From Handy (cjpais/Handy) — the operational discipline

- **Production-grade downloads:** resumable Range headers + 206/200 fallback, SHA256 on background thread, `.partial` suffix, RAII cleanup, throttled progress (10/sec), atomic extract-then-rename. **Adopt all of this.**
- **Idle-unload watcher** with recording-state gating. Defer to v0.7.x.
- **Panic isolation** via `catch_unwind` so a panicking model unloads itself. Swift equivalent: structured Task cancellation + actor isolation.
- **Avoid Handy's tagged-enum dispatch** (8 engines deep, unmaintainable). VoiceInk's protocol+registry is cleaner.

### From hyprnote/anarlog (fastrepl/anarlog, 8.3k stars, Granola alternative)

- **Two trait families:** `RealtimeSttAdapter` (live, streaming) and `BatchSttAdapter` (batch). **Do NOT lift this split.** MacParakeet has zero streaming today; FluidAudio + WhisperKit (and likely Qwen3-ASR) all support both modes when streaming arrives. Their split is justified by 11 cloud providers with genuinely different live (WebSocket) vs batch (HTTP) endpoints; our stack is structurally simpler.
- **Common types in `-interface` crate** — unified across local + cloud providers. **Adopt** (in `MacParakeetCore` directly).
- **Model registry as enum** with `file_name() / model_url() / model_size_bytes() / checksum() / display_name() / description()`. **Adopt.**
- **Avoid 15-provider `BatchProvider` enum** — vendor-soup. We ship one local provider per language need.

### From Granola (proprietary, via local teardown at `~/reference/granola/`)

- **No client-side STT.** Granola opens WebSockets to cloud providers (Deepgram/Speechmatics/AssemblyAI), provider chosen server-side per user via feature flag.
- **Architectural lesson by inverse:** This is exactly the model we don't follow. Local-first is our promise (ADR-002).

### From Argmax canonical patterns (`argmaxinc/argmax-oss-swift`, formerly WhisperKit)

- **Repo moved:** `argmaxinc/WhisperKit` → `argmaxinc/argmax-oss-swift` (meta-package with WhisperKit, SpeakerKit, TTSKit, ArgmaxCLI). Old import paths re-export.
- **Canonical init:** `try await WhisperKit(WhisperKitConfig(model: "large-v3-v20240930_turbo_632MB"))`. **Default to turbo** — better RTF, marginally worse WER.
- **`prewarm: true`** drives Apple's CoreML "specialization." 2x first-load time, but steady-state RAM stays low. **Adopt.**
- **Two-phase init** — explicit static `download` method + instance `loadModels()`. Adopt the shape.

### Multi-engine reference implementations

| Project | Pattern | Lesson |
|---|---|---|
| `getdictus/dictus-ios` | `SpeechModelProtocol` + per-engine impl | **Cleanest abstraction.** Steal protocol shape. ANE serialization comment is critical. |
| `mokbhai/VOX` | `#if canImport(WhisperKit)` + capability bits | **Compile-time gating** for optional deps. |
| `msllrs/relay` | `enum SpeechEngineType` + factory + `engineCache` dict | **Engine instance caching across switches.** |
| `kitlangton/Hex` | Single actor, `isParakeet(variant)` predicate | **Whisper supports forced lang, Parakeet TDT v3 is auto-only** — drives our `--language` validation rule. |

### Known WhisperKit pitfalls (from Argmax issue tracker)

| Issue # | Problem | Mitigation |
|---|---|---|
| #268, #304 | First-load slow due to CoreML ANE specialization | `prewarm: true` + persistent on-disk cache; document expected first-run latency |
| #442 | Data race in `AudioProcessor.audioEnergy/audioSamples` | Per-call AudioProcessor instance, don't share |
| #331 | Thread-sanitizer race on `WhisperKit.progress` | Read progress through an `actor ProgressState` |
| #414 | Force-unwraps in `TextDecoder.decodeText` crash repeated long sessions | Reset/unload between long sessions |
| #392 | `-1` in `supressTokens` crashes on iOS 26 | Sanitize input ranges |
| #300 | `loadModels()` duplicates `.bundle` files in memory each call | Reuse the WhisperKit instance; never re-init |
| #198 | Streaming throughput degrades over time | v0.8+ concern only |
| #352, #261, #410, #128 | AVAudioEngine `installTap` crashes/hangs especially with AirPods | Per-session AVAudioEngine, full teardown between sessions (irrelevant to file transcription path) |

---

## Pre-Phase-1: Types and contracts (PR 1)

Resolve before any code lands. PR 1 deliberately introduces no new abstractions in `MacParakeetCore` — all new types live in `Sources/CLI/Engines/` and remain CLI-internal until PR 2.

### `CLITranscribeEngine` enum + `BCP47Language`

```swift
// Sources/CLI/Engines/CLITranscribeEngine.swift
import Foundation

public enum CLITranscribeEngine: String, Sendable, CaseIterable, Codable {
    case parakeet
    case whisper
}

public typealias BCP47Language = String   // e.g. "en", "ja", "zh-Hant", "ko-KR"
```

Public so unit tests can construct values; not exported from `MacParakeetCore`. `CaseIterable` drives `engines list` without hardcoding strings. Language-string validation happens at the ArgumentParser layer; downstream just passes the value through.

### `WhisperEngine` shape

```swift
// Sources/CLI/Engines/WhisperEngine.swift
import Foundation
import MacParakeetCore     // for STTResult — do not invent a new result type
#if canImport(WhisperKit)
import WhisperKit

actor WhisperEngine {
    private let kit: WhisperKit

    static func make(model: String) async throws -> WhisperEngine {
        let kit = try await WhisperKit(WhisperKitConfig(model: model, prewarm: true))
        return WhisperEngine(kit: kit)
    }

    func transcribe(
        audioURL: URL,
        language: BCP47Language?,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult {
        // 1. Audio normalization to 16 kHz mono Float32 (FFmpeg path already exists)
        // 2. kit.transcribe(audioPath: ..., decodeOptions: DecodingOptions(language: language))
        // 3. Map WhisperKit's TranscriptionResult → MacParakeetCore.STTResult
    }
}
#endif
```

Returns existing `STTResult` from `MacParakeetCore` — do not invent a new result type. Progress signature `(Int, Int)` matches existing `STTClient.transcribe` so the watchdog can subscribe to the same callback shape across both engines.

### Watchdog (CLI-local)

```swift
// Sources/CLI/Engines/TranscribeWatchdog.swift
actor TranscribeWatchdog {
    init(noProgressTimeout: TimeInterval = 60, hardTimeout: TimeInterval? = nil) { /* ... */ }
    func observe(progress: (Int, Int)) { /* reset stall timer */ }
    func start() async { /* fires exit-code-6 structured error on stall */ }
}
```

Hard `--timeout <seconds>` defaults to 0 (disabled); the no-progress timer (default 60s) is always on.

### WhisperKit Sendable status (half-day spike at start of PR 1)

Open `argmaxinc/argmax-oss-swift` (current `main`) and audit `WhisperKit`, `WhisperKitConfig`, `DecodingOptions`, `TranscriptionResult` for Swift 6 strict-concurrency `Sendable` conformance.

If gaps remain:
- Wrap inside `actor WhisperEngine` (already planned)
- Use `@unchecked Sendable` only as last resort with a comment explaining why
- If `WhisperKit` itself is `@MainActor`-bound, surface immediately — schedule risk

This spike happens before the engine implementation lands. If `argmax-oss-swift` has not yet adopted Swift 6 strict mode, expect surprises.

### "Parakeet TDT v3 + `--language`" — settle once FluidAudio 0.14.1 lands

The behavior is soft-accept regardless (the exit-7 rule was retired). The remaining question is whether the language hint is **passed through** or **silently ignored** when `--engine parakeet --language X` is used. Once FluidAudio 0.14.1 is on `main` (PR pending):

1. Open `AsrManager.swift` in the resolved FluidAudio package — typically at `.build/checkouts/FluidAudio/Sources/FluidAudio/Asr/AsrManager.swift`.
2. Check `transcribe()` signature: does it accept a `language:` parameter or `decodingOptions` containing one?
3. **If yes:** plumb the hint through to FluidAudio.
4. **If no:** ignore the hint silently. When `--include-metadata` is set, surface `"language_hint_ignored": true` so callers can audit.

In neither case does the CLI exit non-zero on this combination.

### CLI bypasses `STTScheduler` (ADR-016)

ADR-016's `STTScheduler` is process-internal: reserved dictation slot + shared meeting/batch slot, both inside the GUI's `STTRuntime`. The CLI is a **separate process** invoked per transcribe call — it does not (and cannot) compose with the GUI's scheduler. Each CLI invocation owns one provider for the lifetime of that process; on exit, ANE state is evicted by the OS.

A coding agent should **not** wire `WhisperEngine` (or anything else in PR 1) through `STTScheduler` — that abstraction is for in-process slot arbitration in the GUI and doesn't apply to CLI subprocess invocation.

### WhisperKit valid model identifiers

The `--model <variant>` flag accepts any model published in `argmaxinc/whisperkit-coreml` on HuggingFace. As of 2026-04-26, common variants:

- `tiny`, `tiny.en`
- `base`, `base.en`
- `small`, `small.en`
- `large-v3`, `large-v3-v20240930_626MB`, `large-v3-v20240930_turbo_632MB`
- `distil-whisper_distil-large-v3`

WhisperKit resolves these as glob patterns; document in CLI help that the canonical reference is the `argmaxinc/whisperkit-coreml` HuggingFace repo. Default: `large-v3-v20240930_turbo_632MB`.

### SHA256 source for `models verify`

Use **WhisperKit's HubAPI** to fetch the model manifest, which carries HuggingFace LFS file hashes. Adopt as the source of truth — do not bundle a static manifest in the CLI binary (would go stale across releases).

### Canonical structured-error envelope (all exit codes 2–7)

Every non-zero exit emits this shape on stdout when `--json` is set:

```json
{
  "error": {
    "code": "model_missing" | "audio_invalid" | "cancelled" | "verification_failed" | "engine_hang" | "argument_invalid",
    "message": "<human-readable summary>",
    "details": { /* code-specific fields, may be empty {} */ }
  }
}
```

Per-code `details` payloads:

| Code | Exit | `details` fields |
|---|---|---|
| `model_missing` | 2 | `{ "model": "<variant>", "engine": "parakeet" \| "whisper", "hint": "Run `macparakeet-cli models download <variant>`" }` |
| `audio_invalid` | 3 | `{ "path": "<input>", "reason": "<format/codec/empty>" }` |
| `cancelled` | 4 | `{ "signal": "SIGINT" \| "SIGTERM" }` |
| `verification_failed` | 5 | `{ "model": "<variant>", "expected_sha256": "...", "actual_sha256": "..." }` |
| `engine_hang` | 6 | `{ "engine": "...", "stalled_for_seconds": 60, "last_progress_pct": 0.42 }` |
| `argument_invalid` | 7 | `{ "argument": "<flag-name>", "value": "<value>", "reason": "..." }` — for genuinely malformed input (unknown engine name, non-numeric `--timeout`, etc). **Not** raised for `--language` + `--engine parakeet`, which is soft-accepted. |

The shape is a **public contract** under semver — never remove or rename fields; only add. Schema-lock test in Phase 3 covers this.

---

## PR 1 implementation phases (v0.7)

### Phase 0 — Pre-work (informational)

- [ ] Run Parakeet CJK quality test (§ "Pre-work" above) — Japanese + Mandarin only
- [ ] Capture results in `docs/audits/parakeet-cjk-coverage-2026-XX.md`
- [ ] Use results to write the language coverage table in user docs

### Phase 1 — WhisperKit wrapper

- [ ] **Spike** — half-day audit of `argmaxinc/argmax-oss-swift` for Swift 6 `Sendable` gaps (§ Pre-Phase-1)
- [ ] Add `argmaxinc/argmax-oss-swift` Swift Package dep, gated `#if canImport(WhisperKit)` per VOX
- [ ] Implement `Sources/CLI/Engines/WhisperEngine.swift`
- [ ] Implement `Sources/CLI/Engines/WhisperModelStore.swift` — Handy-style download discipline (resumable Range, SHA256 background verify, `.partial` suffix, RAII cleanup, atomic extract-then-rename, throttled progress)
- [ ] Implement `Sources/CLI/Engines/TranscribeWatchdog.swift`
- [ ] Storage path: `~/Library/Application Support/MacParakeet/models/stt/whisper/<variant>/` (note: `models/stt/whisper/` for symmetry with existing `models/stt/` Parakeet bundle — see Open decisions)
- [ ] Tests: download resume, SHA256 verify, mock for unit tests, real WhisperKit behind an `INTEGRATION=1` env flag

**`STTRuntime`, `STTClient`, `STTClientProtocol` are not modified in this phase.**

### Phase 2 — CLI surface

- [ ] Add `Sources/CLI/Engines/CLITranscribeEngine.swift` — engine enum + `BCP47Language` typealias
- [ ] CLI flags per § "CLI flag set"
- [ ] `--engine` dispatch in `TranscribeCommand` — switch on enum, two parallel paths
- [ ] `--language` soft-accept: pass through to Whisper; pass through (or silently ignore + flag in metadata) for Parakeet per Pre-Phase-1 verification. Never exit non-zero on `--language` + `--engine parakeet`.
- [ ] `--include-metadata` opt-in for JSON metadata wrapper
- [ ] `--timeout` hard-timeout flag (default 0, disabled); always-on no-progress watchdog (60s default) emits exit code 6
- [ ] `engines list` subcommand
- [ ] `models download/list/verify/delete <variant>` extended for `whisper-*` identifiers (`ModelsCommand.swift` modified)
- [ ] JSON envelope: byte-identical v1.2 by default; metadata wrapper only with `--include-metadata`
- [ ] Schema-lock tests — six golden files, one per scenario:
  - clean WAV success (exit 0)
  - missing model (exit 2, `model_missing`)
  - corrupt audio (exit 3, `audio_invalid`)
  - SIGINT mid-transcribe (exit 4, `cancelled`)
  - watchdog stall (exit 6, `engine_hang`)
  - genuinely invalid argument, e.g. unknown engine name (exit 7, `argument_invalid`)
- [ ] Exit codes 0/2/3/4/6/7 fully wired with structured error envelopes (5 wired only when SHA256 verify subcommand actually runs)

### Phase 3 — Documentation + integration

- [ ] Update `integrations/README.md` with engine-selection section + language coverage table from Phase 0
- [ ] **New section in `integrations/README.md`:** "Running CLI alongside the desktop app" — document the cross-process ANE risk; what to do if `cli_warmup_failed` events appear in telemetry
- [ ] Update `Sources/CLI/CHANGELOG.md` for 1.3.0
- [ ] Update `AGENTS.md` if needed
- [ ] Add multilingual examples to `integrations/openclaw/README.md` and `integrations/hermes/README.md`
- [ ] Update `/agents` page on macparakeet.com
- [ ] Add `THIRD_PARTY_LICENSES.md` (or `NOTICE`) at repo root with WhisperKit + model attributions

### Phase 4 — Validation

- [ ] "Walk the docs as a fresh agent" CI test — every example in `integrations/README.md` exercised in CI
- [ ] Manual end-to-end: brew install, follow integration docs cold, verify each documented command works
- [ ] Ship to small set of agent operators before ClawHub / awesome-hermes-agent registry promotion
- [ ] Watch telemetry for `cli_warmup_failed` events with ANE error signature; if any → trigger PR 1.5 cross-process lock fast-follow

---

## Out of scope for PR 1 (deferred to PR 2 or later)

The following are explicitly NOT in this plan; they need their own plan when scheduled.

### PR 2 — STT abstraction unification (target v0.7.x or v0.8)

Drafted as `plans/active/stt-provider-unification.md` (TBD, written after PR 1 ships when WhisperKit operational reality is known). Will:

- Define `STTProvider` protocol in `MacParakeetCore` (informed by PR 1, not speculation)
- Refactor `STTRuntime` to consume providers (GUI hot path now in scope)
- Refactor `STTClient` to consume providers (existing Parakeet usage continues to work via `ParakeetProvider`)
- Move `WhisperEngine` into a shared `WhisperKitProvider` in `MacParakeetCore`
- Add `STTProviderRegistry` actor with in-process init serialization for the cases where one process needs both engines (likely never in practice, but the abstraction is correct)
- Two-sided cross-process ANE lock (GUI's `STTRuntime.warmUp()` also takes the `flock`)
- Tests for GUI hot paths (dictation, meeting recording)
- No CLI-visible behavior change

### PR 1.5 — cross-process ANE lock (only if needed)

Triggered if telemetry or P0 reports show ANE specialization crashes when CLI runs with GUI active. Adds CLI-side `flock` only (one-sided). ~50 LOC. Lands within days of trigger.

---

## Other things explicitly out of scope (beyond PR 2)

- **Auto-routing / language detection** — `--engine auto`, multi-point sampling, VAD-aware sampling, drift detection, confidence-weighted majority. Add when there's real agent-operator demand signal. v0.8+.
- **Streaming WhisperKit** — `--stream`, partial result emission. v0.8+.
- **WhisperKit translation mode** — `--task translate`. Code path can exist; flag not promoted.
- **Idle-unload watcher** — auto-unload after N seconds. v0.7.x patch.
- **Multilingual via mlx-qwen3-asr** — see reversal triggers; v0.8+.
- **Cloud STT providers** — Deepgram, AssemblyAI, OpenAI Whisper API. ADR-002 says no. Maybe v1.0 if signal.
- **Diarization for WhisperKit** — Argmax has SpeakerKit; we have FluidAudio diarization on Parakeet. Don't unify yet.
- **GUI multilingual UX** — even after PR 2 makes the GUI multi-engine-capable, the surfacing of language choice in the GUI (engine picker, language picker, etc.) is a separate plan/PR. v0.8+.
- **Model auto-update** — no Sparkle-equivalent for STT models. User pulls explicitly.
- **`--language ja,ko,en` (multiple)** — anarlog pattern. Defer until single-language is solid.

---

## Reversal triggers (when to reconsider Qwen3-ASR or other)

The decision to ship WhisperKit, not `mlx-qwen3-asr`, reverses if **any** of these *quantitative* conditions hold:

1. **Argmax ships Qwen3-ASR (or equivalent multilingual model) in WhisperKit.** Verifiable by scanning their releases.

2. **`mlx-qwen3-asr` reaches agent-grade quality** — operationalized as ALL of:
   - At least one tagged release with green CI on macOS 14, 15, and 26
   - Zero open P0 issues for ≥ 30 days
   - ≥ 50 real-world transcribe operations completed by external users without crash or memory pressure event
   - Memory ceiling stays under 4 GB during Q5/int8 quantized inference
   - Mature Swift wrapper exists with tagged releases

3. **Field signal:** ≥ 3 distinct agent operators file P0 issues stating "WhisperKit Chinese (or other CJK) output is unusable for my use case."

4. **Quality benchmark** — Qwen3-ASR achieves ≥ 10% relative CER improvement over WhisperKit on a defined Mandarin/Japanese/Korean test corpus we own (Common Voice or similar; not vendor-marketing benchmarks).

5. **Apple ships native multilingual ASR** with WER ≤ 10% relative penalty vs Whisper-large-v3 on FLEURS-30. Wildcard.

When any trigger fires, integrate as a **third** engine (don't replace WhisperKit). The protocol makes this cheap.

---

## License inventory (verified 2026-04-26)

| Component | License | GPL-3.0 (MacParakeet) compatibility |
|---|---|---|
| `argmaxinc/argmax-oss-swift` (WhisperKit) | **MIT** | ✅ Permissive |
| `FluidInference/FluidAudio` (existing dep) | **Apache 2.0** | ✅ One-way GPL-3.0 compatible |
| OpenAI Whisper model weights (large-v3, turbo) | **MIT** | ✅ Permissive |
| NVIDIA Parakeet TDT v3 weights | **CC-BY-4.0** | ✅ Data file, attribution-only |
| `moona3k/mlx-qwen3-asr` (future v0.8) | **Apache 2.0** | ✅ |

**Deliverable:** add `THIRD_PARTY_LICENSES.md` (or `NOTICE`) file at repo root in Phase 4. Five-line entry in `--version --verbose` mentions "Speech recognition powered by NVIDIA Parakeet (CC-BY-4.0) and OpenAI Whisper via WhisperKit (MIT)" to satisfy CC-BY's attribution requirement.

**Architectural research is not a license issue** — patterns aren't copyrightable. We're not copying source code. Granola insights are by-inverse, sourced from a personal-data-extraction reverse-engineering teardown at `~/reference/granola/`.

---

## Open decisions

- [ ] **Default Whisper variant** — `large-v3-v20240930_626MB` (accuracy) or `large-v3-v20240930_turbo_632MB` (speed). Lean turbo. Revisit after Phase 0 results.
- [ ] **Agent operator beta** — ship to a small group before ClawHub/awesome-hermes-agent registry promotion? Recommend yes; need to pick the group.
- [ ] **Model bundle path** — `models/whisper/` or `models/stt/whisper/`? Current Parakeet at `models/stt/`. Lean toward `models/stt/whisper/` for symmetry.
- [ ] **Cross-process ANE lock policy** — ship PR 1 without it (current plan) or include it day-one as one-sided CLI `flock`? Current call: ship without; instrument; fast-follow if needed. Reverse if pre-ship testing shows reliable repro of E5 crash with GUI active.

---

## Risks

| Risk | Probability | Impact | Mitigation |
|---|---|---|---|
| In-process simultaneous Parakeet + WhisperKit specialization (Dictus' E5 bundle crash) | N/A in PR 1 | N/A | PR 1 is one-engine-per-process by construction; risk only re-emerges in PR 2 (mitigated there by `STTProviderRegistry` init serialization + `unload()`) |
| **Cross-process ANE specialization collision** (CLI prewarming WhisperKit while GUI is specializing Parakeet) | Unknown — plausible but not yet observed | High (E5 crash) | PR 1 ships without lock; document risk in `integrations/README.md`; watch telemetry for `cli_warmup_failed` ANE events; PR 1.5 fast-follow with CLI-side `flock` if observed; PR 2 promotes to two-sided lock |
| Model download size + first-run UX | Medium | Medium | Two-phase explicit download command; documented expectation |
| WhisperKit thread-safety bugs in production | Low (mature codebase but tracked) | Medium | Actor pattern around progress, instance reuse, periodic reset |
| WhisperKit becomes deprecated / acquired-and-killed | Very low | High | Provider abstraction makes swap cheap; mlx-qwen3-asr is fallback |
| Adding a second engine bloats CLI binary | Low | Medium | Measure pre/post; if bad, gate WhisperKit at a separate brew formula |
| Watchdog kills legitimate long transcriptions | Low | Medium | Hard `--timeout` defaults to 0 (disabled); always-on no-progress watchdog (60s) catches hangs without ceiling-killing valid long jobs |

---

## Sequencing relative to other work

- **v0.6.0** ships first (meeting recording stable). No multilingual work touches v0.6.
- **v0.6.x soak time** — run Parakeet CJK quality test; capture results for docs.
- **v0.7** — **PR 1 only** (CLI multilingual via new CLI-local `WhisperEngine`). GUI's `STTRuntime` untouched. CLI 1.3.0.
- **v0.7.x** — PR 1.5 if cross-process ANE crashes appear. Idle-unload watcher.
- **v0.7.x or v0.8** — **PR 2** (STT abstraction unification). Separate plan, no user-visible behavior change. GUI becomes multi-engine-capable as a side effect, but no GUI multilingual UX in this PR.
- **v0.8+** — reversal trigger evaluation. Possibly add Qwen3-ASR. Possibly add `--engine auto` if there's demand. Possibly add GUI multilingual UX (separate plan).

---

## Success signals (4–8 weeks post v0.7 ship)

- WhisperKit `--engine whisper` invocation rate ≥ 5% of total CLI transcribe calls (telemetry, opt-in)
- ≤ 1 P0 issue from agent operators on the WhisperKit path in the first month
- ClawHub / awesome-hermes-agent submissions accepted with multilingual mentioned
- At least one external agent operator publishes a "macparakeet-cli + Hermes for non-English transcription" guide
- Argmax issue tracker: zero new MacParakeet-specific bug reports in their repo

---

## References

### Internal
- ADR-016 (centralized STT runtime + scheduler)
- ADR-002 (local-first processing, amended)
- `plans/active/cli-as-canonical-parakeet-surface.md`
- `Sources/CLI/CHANGELOG.md` (semver contract)
- `integrations/README.md` (downstream agent vocabulary)

### External (researched 2026-04-26)
- `Beingpax/VoiceInk` — `Transcription/Engine/{TranscriptionService,TranscriptionServiceRegistry}.swift`, `Models/TranscriptionModel.swift`
- `cjpais/Handy` — `src-tauri/src/managers/{transcription.rs,model.rs}`, `cli.rs`, `lib.rs:483-492`
- `fastrepl/anarlog` (formerly hyprnote) — `crates/owhisper-client/src/{live.rs,batch.rs,providers.rs}`, `crates/listener2-core/src/batch/mod.rs`, `crates/whisper-local-model/src/lib.rs`, `crates/model-downloader/src/manager.rs`
- `argmaxinc/argmax-oss-swift` (formerly WhisperKit) — `Sources/WhisperKit/Core/{WhisperKit,Configurations,TranscribeTask}.swift`, `Sources/ArgmaxCLI/{TranscribeCLI,TranscribeCLIArguments}.swift`
- `getdictus/dictus-ios` — `DictusApp/Audio/{TranscriptionService,ParakeetEngine,WhisperKitEngine}.swift`
- `mokbhai/VOX` — `VoxNative/Speech/SpeechEngineRegistry.swift`
- `msllrs/relay` — `Relay/Voice/VoiceManager.swift:193-198`
- `kitlangton/Hex` — `Hex/Clients/TranscriptionClient.swift`
- Argmax issue tracker: #268, #300, #304, #331, #392, #410, #414, #442

### Granola teardown (local)
- `~/reference/granola/{01-static.md, 02-architecture.md, 04-dynamic.md, findings/raw/endpoints.md}` (255 MB, gitignored)

### MacParakeet's own
- `moona3k/mlx-qwen3-asr` — held as v0.8+ reversal-trigger candidate, not v0.7 path
