# Plan: macparakeet-cli multilingual STT via WhisperKit

> Status: **ACTIVE**
> Author: Daniel + agent (Claude)
> Date: 2026-04-27 (collapsed back to single PR after 6-reviewer convergence pass)
> Targets: CLI 1.3.0, MacParakeet v0.7.x
> Related: `plans/active/cli-as-canonical-parakeet-surface.md`, ADR-016 (centralized STT runtime + scheduler)

---

## TL;DR

**Decision (locked):** Add WhisperKit as a second STT engine in `macparakeet-cli`. **Parakeet remains the default.** Users explicitly opt in to WhisperKit when they have languages outside Parakeet's coverage.

```
macparakeet-cli transcribe file.wav                                  # → Parakeet (default, fast)
macparakeet-cli transcribe file.wav --engine whisper                 # → WhisperKit (slower, 99 languages)
macparakeet-cli transcribe file.wav --engine whisper --language ko   # → WhisperKit forced to Korean
```

**No auto-routing, no runtime language detection, no confidence thresholds, no drift handling.** User chooses the engine; CLI obeys.

### Single-PR scope (locked 2026-04-27)

Earlier drafts split this into PR 1 (CLI multilingual, MacParakeetCore untouched) + PR 2 (STT abstraction unification). Multi-LLM review (3 Gemini + 3 Codex) surfaced the split as artificial:

- `ModelsCommand` already consumes `STTClientProtocol`; Whisper status either duplicates code in CLI-local form or drags `STTClientProtocol` into the diff anyway
- The cross-process ANE lock has to be **two-sided** to actually protect GUI dictation — meaning `STTRuntime.warmUp()` takes the lock — meaning GUI hot path is in the diff regardless
- `STTError` needs Whisper-specific cases (a `MacParakeetCore` edit by definition)
- `WhisperEngine` placement in `Sources/CLI/Engines/` would force a delete-and-recreate when later moved to `MacParakeetCore`

So the collapse: ship the `STTProvider` abstraction in `MacParakeetCore` from day one, both engines as providers, two-sided ANE lock, one PR, one review pass. The GUI hot path is in the diff but has no observable behavior change — `STTRuntime` still drives dictation/meeting through Parakeet via `ParakeetProvider`.

**Why WhisperKit, not `mlx-qwen3-asr`:** Reliability beats novelty for an agent-facing surface. WhisperKit has 2+ years of production deployment; our MLX port is 2 months old. `mlx-qwen3-asr` stays as a tracked v0.8+ reversal-trigger candidate.

**v0.7 scope is file transcription only.** Dictation and meeting recording stay Parakeet-only forever (or until Parakeet-Multilingual ships). GUI surfacing of engine choice is a separate plan, post-ship.

**Why no auto-routing:** detecting language at runtime is real product complexity (multi-point sampling, VAD-aware sampling, drift handling). All of it is speculative without agent-operator demand signal. Defer to v0.8+ as `--engine auto`.

**Demand evidence is honest:** OpenClaw/Hermes integration docs are boilerplate; we have no field-reported CJK transcription needs. Success metrics below are targets with no baseline. Pre-ship deliverable: identify ≥1 external agent operator with stated CJK need before promoting to ClawHub/awesome-hermes-agent registries.

---

## Language coverage (user-facing doc copy)

Parakeet TDT v3 is the high-quality default for languages it supports. Whisper is the escape hatch for everything else. **We do not benchmark Parakeet's CJK quality before ship** — users decide whether Parakeet's output is adequate for their audio and switch to Whisper if not.

**Important runtime nuance — verified against FluidAudio 0.14.1 source by Codex 3:** The `Language` enum in `TokenLanguageFilter.swift` has **no CJK entries** (only Latin/Cyrillic, 21 cases). The `tdtJa` decode path bypasses token language filtering entirely. So `--language` is effectively a **no-op for any non-Latin/Cyrillic target** when paired with `--engine parakeet`. We pass the hint where the underlying `Language` enum supports it; for unsupported language hints, we surface `"language_hint_ignored": true` in `--include-metadata`.

User-facing table (verbatim into `integrations/README.md` and CLI help text):

| If your audio is… | Use | Notes |
|---|---|---|
| English or one of the 25 European languages Parakeet supports | **Parakeet (default)** | Fastest, highest quality on Apple Silicon. Just `transcribe file.wav`. |
| Japanese or Mandarin | **Parakeet** first; switch to Whisper if quality isn't adequate | Parakeet's `tdtJa`/`tdtZh` decode paths handle these per FluidAudio README. `--language ja` is silently ignored by Parakeet at the runtime layer (auto-detect from acoustics). |
| Korean, or any other language | **Whisper** | Pass `--engine whisper` (and optionally `--language <bcp47>`). Whisper supports 99 languages. |

No quantitative WER claims. User picks.

---

## Architecture

A single `STTProvider` protocol in `MacParakeetCore` with two implementations: `ParakeetProvider` (wraps existing `AsrManager` plumbing) and `WhisperKitProvider` (wraps `argmaxinc/argmax-oss-swift`'s `WhisperKit`). One registry actor for in-process provider lifecycle. Cross-process ANE lock for GUI/CLI co-existence. The CLI invokes providers directly; the GUI's `STTRuntime` consumes providers internally for dictation/meeting (no observable behavior change).

### `STTProvider` protocol (in MacParakeetCore from day one)

```swift
public protocol STTProvider: Sendable {
    var identifier: STTProviderID { get }
    var supportedLanguages: Set<BCP47Language> { get }   // metadata, not used at runtime
    var isReady: Bool { get }

    func prepare(modelIdentifier: String) async throws
    func unload() async   // ANE eviction before another provider prepares

    func transcribe(
        audioURL: URL,
        options: TranscribeOptions,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTTranscription
}

public enum STTProviderID: String, Sendable, Codable {
    case parakeet
    case whisper
}

public typealias BCP47Language = String

public struct TranscribeOptions: Sendable {
    public var language: BCP47Language?
    public var includeWordTimestamps: Bool
    public init(language: BCP47Language? = nil, includeWordTimestamps: Bool = false)
}
```

### `STTTranscription` — extends existing `STTResult`

Codex 3 surfaced that existing `STTResult` (just `text: String` + `words: [TimestampedWord]`) lacks fields WhisperKit emits and the `--include-metadata` contract requires. New thin wrapper:

```swift
public struct STTTranscription: Sendable {
    public let result: STTResult                 // existing type, kept verbatim
    public let detectedLanguage: BCP47Language?  // engine-reported (Whisper) or nil
    public let segments: [STTSegment]?           // Whisper-style segment timing (nil for Parakeet)
    public let languageHintIgnored: Bool         // true when --language was dropped (Parakeet+CJK)
}

public struct STTSegment: Sendable {
    public let text: String
    public let startMs: Int
    public let endMs: Int
    public let noSpeechProbability: Double?      // Whisper-only signal
}
```

`ParakeetProvider` returns `STTTranscription(result:, detectedLanguage: nil, segments: nil, languageHintIgnored: <true if non-Latin --language was passed>)`. `WhisperKitProvider` populates all fields. `TranscribeCommand` unwraps `.result` for the default JSON envelope; the additional fields surface only when `--include-metadata` is set.

### Provider registry (in-process serialization)

```swift
public actor STTProviderRegistry {
    private var providers: [STTProviderID: any STTProvider] = [:]
    private var activeProvider: STTProviderID?
    private var inflightInit: Task<Void, Error>?  // Task-chain serialization

    public func provider(
        for id: STTProviderID,
        modelIdentifier: String? = nil
    ) async throws -> any STTProvider {
        // 1. await any in-flight init
        // 2. unload current provider if switching
        // 3. get-or-create with writeback
        // 4. prepare if !isReady (takes cross-process ANE lock during specialization)
        // 5. set activeProvider; return
    }
}
```

Pseudocode bugs from earlier drafts caught and fixed:
- `modelIdentifier` parameter accepted (so `--model` flag isn't a no-op)
- Provider written back to `providers[id]` after creation (so subsequent `unload()` finds it)
- Init serialization via Task-chain (each `prepare()` awaits prior in-flight Task) — no separate semaphore type needed; avoids holding a lock past the ANE-critical section under thread-pool saturation

### Cross-process ANE lock — two-sided, day-one

The Apple Neural Engine's CoreML specialization step (model graph → ANE bytecode via `anecompilerservice` daemon) can crash under concurrent in-process specialization (Dictus' E5 bundle observation) and may also crash cross-process. Reviewers Gemini 1 + Gemini 2 both rated the deferred mitigation HIGH risk: the CLI invoking WhisperKit while GUI specializes Parakeet on launch (or app-update specialization) can crash the CLI, and a worst case lets the ANE error propagate into the GUI and drop a meeting.

**Mitigation: advisory `flock` at `~/Library/Application Support/MacParakeet/.ane.lock`**, taken by:

- `STTRuntime.warmUp()` (GUI side, Parakeet specialization)
- `WhisperKitProvider.prepare()` (CLI side, Whisper specialization)
- Held only during the CoreML specialization call; released as soon as specialization completes (typically seconds)

Implementation: Foundation's `FileHandle` doesn't expose `flock(2)`. Use `fcntl(F_SETLK)` via Darwin or open the lock file with `O_EXLOCK`. New file: `Sources/MacParakeetCore/Concurrency/ANESpecializationLock.swift`.

Behavior under contention: the second process blocks on the lock, then specializes after the first releases. No crash. Slight first-run latency.

### Engine selection

User chooses; CLI obeys.

| Caller intent | Command | Behavior |
|---|---|---|
| Default (English / European audio) | `transcribe file.wav` | Parakeet, fast |
| Non-Parakeet language | `transcribe file.wav --engine whisper` | WhisperKit, slower, 99 languages |
| Force language to Whisper | `transcribe file.wav --engine whisper --language ko` | WhisperKit forced to Korean |
| Force language to Parakeet | `transcribe file.wav --engine parakeet --language ja` | **Soft-accept.** FluidAudio 0.14.1's `Language` enum has no CJK entries, so the hint is silently dropped at the filter layer. With `--include-metadata`, surface `"language_hint_ignored": true`. **Never exit non-zero on this combination.** |

When auto-routing eventually ships, it slots in as `--engine auto` without changing existing flag behavior.

### Audio normalization (resolved per Codex 3)

WhisperKit hard-requires 16 kHz mono Float32. The CLI's existing `AudioFileConverter.swift` (FFmpeg path) already produces this format (`-ar 16000 -ac 1 -acodec pcm_f32le`). Both providers receive the **converted file URL**, never the raw input. FFmpeg runs once per transcribe. Parakeet's `AsrManager` resamples internally if needed; Whisper consumes the converted WAV directly.

### Watchdog / hang detection

WhisperKit issues #352, #410, #198 are real production hang reports. Two-stage watchdog:

- **`--timeout <seconds>` flag.** Default `0` (disabled, opt-in only). Hard SIGTERM at expiry; exit code 6. Opt-in because legitimate transcribes can run for hours (multi-hour batch jobs, unattended overnight runs).
- **No-progress watchdog (always-on).** **Starts only after the first progress event from the engine** (Gemini 3 finding — WhisperKit prewarm can take >60s on M1/M2; the watchdog must not tick during specialization, or first-run will be killed mid-init). Once running, fires exit code 6 if no progress for 60s. The `STTProvider.transcribe(... onProgress:)` callback is the trigger.

JSON envelope on hang exit (additive to v1.2 flat shape — see "JSON envelope additivity" below):

```json
{
  "ok": false,
  "error": "engine hang",
  "errorType": "engine_hang",
  "details": { "engine": "whisper", "stalled_for_seconds": 60, "last_progress_pct": 0.42 }
}
```

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 2 | Model missing / not downloaded (carries `details.size_bytes` and `details.hint`) |
| 3 | Audio file invalid / unreadable |
| 4 | Cancelled (SIGINT/SIGTERM from caller) |
| 5 | Model verification failed (SHA256 mismatch) |
| 6 | Engine hang / timeout |
| 7 | Invalid argument combination — genuinely malformed input only (unknown engine name, non-numeric `--timeout`). **Not** raised for `--language` + `--engine parakeet`, which is soft-accepted. |

### JSON envelope additivity (preserves existing v1.2 contract)

**Critical correction from earlier draft (Gemini 3):** the existing v1.2 contract in `Sources/CLI/CHANGELOG.md` is a flat error envelope:

```json
{ "ok": false, "error": "<message>", "errorType": "<short>" }
```

The plan **must not** replace this with a nested `{ "error": { ... } }` shape — that breaks every agent currently parsing `errorType`. New behavior is strictly additive.

**Default `--json` (no metadata flag):** byte-identical v1.2. The only addition is a `details` sub-object, present only on errors:

```json
{ "ok": false, "error": "...", "errorType": "...", "details": { /* code-specific */ } }
```

Per-code `details` payloads:

| `errorType` | Exit | `details` fields |
|---|---|---|
| `model_missing` | 2 | `{ "model": "<variant>", "engine": "parakeet"\|"whisper", "size_bytes": N, "hint": "Run macparakeet-cli models download <variant>" }` |
| `audio_invalid` | 3 | `{ "path": "<input>", "reason": "<format/codec/empty>" }` |
| `cancelled` | 4 | `{ "signal": "SIGINT"\|"SIGTERM" }` |
| `verification_failed` | 5 | `{ "model": "<variant>", "expected_sha256": "...", "actual_sha256": "..." }` |
| `engine_hang` | 6 | `{ "engine": "...", "stalled_for_seconds": 60, "last_progress_pct": 0.42 }` |
| `argument_invalid` | 7 | `{ "argument": "<flag-name>", "value": "<value>", "reason": "..." }` (genuinely malformed input only — never raised for soft-accept cases) |

`details` is strictly additive. Strict parsers using top-level `additionalProperties: false` will need to update their schema; load-bearing fields (`ok`, `error`, `errorType`) keep working unchanged.

**Opt-in `--json --include-metadata`:** adds a `metadata` wrapper to successful responses:

```jsonc
{
  "text": "...",
  "words": [...],
  "duration_seconds": 123.45,
  // ... existing v1.2 success fields verbatim ...
  "metadata": {                          // ← only with --include-metadata
    "engine": "parakeet",
    "model": "parakeet-tdt-0.6b-v3",
    "language_requested": "ja",          // what user passed via --language
    "language_detected": "en",           // engine-reported (Whisper only)
    "language_hint_ignored": true,       // when present, hint was dropped (Parakeet + CJK)
    "schema_version": "1.3"
  }
}
```

CLI bumps to **1.3.0** — additive minor.

### CLI flag set

```
macparakeet-cli transcribe <input> [options]

  --engine [parakeet|whisper]     Default: parakeet
  --model <variant>                Override default model for chosen engine
  --language <bcp47>               Force decode language. Honored where engine supports; soft-accepted (or ignored) elsewhere — never errors.
  --word-timestamps                Word-level timing in output
  --timeout <seconds>              Hard timeout. Default 0 (disabled). No-progress watchdog (60s) is always on after first progress event.
  --include-metadata               Add metadata wrapper to --json output
  --json                           Machine-readable output (required for agents)

macparakeet-cli engines list [--json]
  --json schema (locked):
  [
    {
      "id": "parakeet" | "whisper",
      "default_model": "<variant string>",
      "supported_languages": ["en", "ja", "zh", ...],   // BCP-47 codes
      "language_hint_supported": true | false,           // false for Parakeet (Latin/Cyrillic-only enum)
      "ane_specialization_required": true,
      "model_directory": "/Users/.../models/stt/<engine>/"
    }
  ]

macparakeet-cli models <subcommand>
  download <variant>               Explicit, exits when done. Resumable + retried.
  list [--json]                    All variants — both downloaded and available-for-download.
                                   --json schema:
                                   [
                                     {
                                       "engine": "parakeet"|"whisper",
                                       "variant": "<id>",
                                       "status": "downloaded"|"missing"|"partial"|"corrupt",
                                       "size_bytes": N,
                                       "path": "/Users/.../models/stt/<engine>/<variant>/" | null
                                     }
                                   ]
  verify [--sha256]                Post-download integrity check.
  delete <variant>                 Free disk space (locked against in-flight warmup).
```

**Concurrency handled internally**, not exposed: auto-scale based on `ProcessInfo.processInfo.activeProcessorCount`. Concurrent CLI invocations from the same operator are not throttled — operators manage their own concurrency. Documented explicitly in `integrations/README.md` (override of the prior ADR-016-flavored framing).

**Deferred flags** (add when they have real behavior):

- `--task translate` — Whisper-only translation
- `--clip-timestamps` — partial-file decode
- `--prompt` — Whisper decoding prompt
- `--chunking-strategy [none|vad]` — VAD integration
- `--report` — SRT writer + sidecar JSON spec
- `--output-dir` — sidecar file convention
- `--language ja,ko,en` (multiple) — anarlog pattern
- `--engine auto` — runtime detection + routing

### Telemetry plan (cross-repo coordination — pre-ship blocker)

**Critical (Codex 1 + Codex 2):** The Worker at `macparakeet-website/functions/api/telemetry.ts` rejects entire batches if any event name is unknown to its `ALLOWED_EVENTS` list. Adding new events without first updating the allowlist silently drops all co-batched valid events.

**Pre-ship deliverables (block CLI 1.3.0 merge):**

1. Extend existing `cliOperation` event in `Sources/MacParakeetCore/Telemetry/TelemetryEvent.swift`:
   - Add `engine: String?` (`"parakeet"` | `"whisper"`)
   - Add `modelVariant: String?`
   - Add `failureStage: String?` (`"prewarm"` | `"transcribe"` | `"download"` | `"verify"`)

2. Add new event names to `TelemetryEventName` enum:
   - `cliWarmupStarted` — fires before CoreML specialization
   - `cliWarmupSucceeded` — fires after specialization completes
   - `cliWarmupFailed` — fires on prewarm error (carries error signature)

3. Land allowlist PR to `macparakeet-website` adding all three new event names to `ALLOWED_EVENTS` in `functions/api/telemetry.ts`. **Must merge AND deploy before CLI 1.3.0.** Verify via curl that the deployed Worker accepts a sample event and writes to D1.

4. All new telemetry must initialize through `CLITelemetry.configureIfNeeded()` so `MACPARAKEET_TELEMETRY=0` env opt-out and `AppPreferences.isTelemetryEnabled` GUI toggle are honored automatically.

**Why bracketing matters for the cross-process ANE strategy:** A `cliWarmupStarted` with no matching `cliWarmupSucceeded`/`cliWarmupFailed` is the signal that the CLI process crashed during specialization (the failure mode we're worried about). Without bracketing, we can't distinguish process crashes from clean exits in D1.

### Two-phase model lifecycle (Argmax canonical pattern)

Argmax separates `WhisperKit.download(variant:progressCallback:) -> URL` (static) from `loadModels()` (instance, fast once cached). Adopt the same shape:

```bash
macparakeet-cli models download whisper-large-v3-turbo  # explicit, exits when done
macparakeet-cli models list --json                       # what's installed/available
macparakeet-cli models verify --sha256                   # post-download integrity
macparakeet-cli transcribe file.m4a --engine whisper     # never blocks on download
```

A transcribe call against a missing model emits a structured `model_missing` error pointing to the download command — never auto-downloads silently in the agent path. **This applies to Parakeet too** (Gemini 2 finding): `--engine parakeet` with no cached model returns `model_missing` (exit 2) instead of silently triggering a 6 GB download in a headless agent session.

### Download discipline (Handy + reviewer additions)

| Property | Status | Source |
|---|---|---|
| Resume from `.partial` via Range header + 206/200 fallback | Required | Handy |
| Bounded retries with backoff/jitter (3 attempts: 1s/2s/4s + jitter) | **Required (Codex 1+2)** | New |
| Honor `Retry-After` header on 429/503 | **Required (Codex 1+2)** | New |
| Per-host concurrency gate (one HF download per process) | **Required (Codex 1+2)** | New |
| SHA256 verification post-download (background thread) | Required | Handy |
| Disk preflight: free bytes ≥ compressed + expanded + 10% margin | **Required (Codex 1+2)** | New |
| Per-variant `.lock` file (download/verify/delete/warmup all honor it) | **Required (Codex 1+2)** | New |
| Stale-lock detection (older than max expected download time → reap) | **Required (Codex 1+2)** | New |
| Temp extraction path = `<variant-dir>.tmp-<pid>` on **same volume** | **Required (Gemini 2)** | New (EXDEV avoidance) |
| Atomic rename of staged variant dir on success | Required | Handy |
| RAII cleanup on every error path | Required | Handy |
| Stale-file reaper for orphaned `.staging`/`.partial` (runs on `models list`) | **Required (Gemini 2)** | New |
| Throttled progress events (≤10/sec) | Required | Handy |
| Cancellation token per model | Required | Handy |
| Idle-unload watcher with recording-state gating | Defer to v0.7.x | Handy |

**Storage:** `~/Library/Application Support/MacParakeet/models/stt/whisper/<variant>/` (mirrors existing `models/stt/` Parakeet location). Don't let WhisperKit default to its HF cache (`~/Library/Caches/argmaxinc/whisperkit/`) — keeps "delete MacParakeet → all data gone" expectation intact.

### SHA256 source for `models verify` — pending Phase 0 spike

**Codex 1 + Codex 2 finding:** Hugging Face LFS exposes SHA256 for the **LFS object**, not necessarily the bytes-on-disk after redirects, decompression, or asset transformation. Phase 0 spike must verify before `WhisperModelStore` lands:

1. Download a Whisper variant via WhisperKit's `HubAPI`
2. Compare bytes-on-disk SHA256 to `HubAPI`-reported value
3. **If they match:** `HubAPI` is source of truth; document the exact call sequence
4. **If they don't:** pin a checked-in manifest at `Sources/CLI/Engines/whisper-model-digests.json` per release with `{variant, file, size, sha256}` for each supported model. Update on each Argmax release.

Without this resolved, `models verify` is meaningless and exit code 5 is unfireable.

---

## Lessons from comparable projects (research synthesis)

Three subagents researched Handy/VoiceInk, hyprnote (now `fastrepl/anarlog`)/Granola, and WhisperKit official + multi-engine reference impls.

### From VoiceInk (Beingpax/VoiceInk) — the structural model

- **`TranscriptionService` protocol + registry** with provider-enum dispatch. Single-method protocol, lazy-instantiated concrete services per provider. Adding a backend = one new file. **Adopt** (as `STTProvider` + `STTProviderRegistry`).
- **`TranscriptionModel` protocol** as unified model descriptor. Concrete structs per backend. **Adopt** as part of `models list --json` schema.

### From Handy (cjpais/Handy) — the operational discipline

- **Production-grade downloads:** resumable Range headers + 206/200 fallback, SHA256 on background thread, `.partial` suffix, RAII cleanup, throttled progress (10/sec), atomic extract-then-rename. **Adopt all.**
- **Idle-unload watcher** with recording-state gating. Defer to v0.7.x.
- **Panic isolation** via `catch_unwind`. Swift equivalent: structured Task cancellation + actor isolation.
- **Avoid Handy's tagged-enum dispatch** (8 engines deep, unmaintainable). VoiceInk's protocol+registry is cleaner.

### From hyprnote/anarlog (fastrepl/anarlog, 8.3k stars, Granola alternative)

- **Two trait families:** `RealtimeSttAdapter` (live, streaming) and `BatchSttAdapter` (batch). **Do NOT lift this split.** MacParakeet has zero streaming today; FluidAudio + WhisperKit support both modes when streaming arrives. Their split is justified by 11 cloud providers with genuinely different live (WebSocket) vs batch (HTTP) endpoints; our stack is structurally simpler.
- **Common types in `-interface` crate** — unified across local + cloud providers. **Adopt** (in `MacParakeetCore` directly).
- **Model registry as enum** with `file_name() / model_url() / model_size_bytes() / checksum() / display_name() / description()`. **Adopt.**
- **Avoid 15-provider `BatchProvider` enum** — vendor-soup. We ship one local provider per language need.

### From Granola (proprietary, via local teardown at `~/reference/granola/`)

- **No client-side STT.** Granola opens WebSockets to cloud providers. Architectural lesson by inverse: this is exactly the model we don't follow. Local-first is ADR-002.

### From Argmax canonical patterns (`argmaxinc/argmax-oss-swift`, formerly WhisperKit)

- **Repo moved:** `argmaxinc/WhisperKit` → `argmaxinc/argmax-oss-swift` (meta-package with WhisperKit, SpeakerKit, TTSKit, ArgmaxCLI). Old import paths re-export — **but verify in Phase 0 spike** for the version we pin.
- **Canonical init:** `try await WhisperKit(WhisperKitConfig(model: "large-v3-v20240930_turbo_632MB"))`. Default to turbo.
- **`prewarm: true`** drives Apple's CoreML "specialization." 2x first-load time, but steady-state RAM stays low. **Adopt.**
- **Two-phase init** — explicit static `download` + instance `loadModels()`. Adopt the shape.

### Multi-engine reference implementations

| Project | Pattern | Lesson |
|---|---|---|
| `getdictus/dictus-ios` | `SpeechModelProtocol` + per-engine impl | Cleanest abstraction. Steal protocol shape. ANE serialization comment is critical. |
| `mokbhai/VOX` | `#if canImport(WhisperKit)` + capability bits | Compile-time gating for optional deps. |
| `msllrs/relay` | `enum SpeechEngineType` + factory + `engineCache` dict | Engine instance caching across switches. |
| `kitlangton/Hex` | Single actor, `isParakeet(variant)` predicate | Whisper supports forced lang, Parakeet auto-only — drives our soft-accept rule. |

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
| #352, #261, #410, #128 | `AVAudioEngine installTap` crashes/hangs especially with AirPods | Per-session AVAudioEngine, full teardown between sessions |

---

## Pre-Phase-1: Types and contracts

### File layout (single PR — all in MacParakeetCore)

- `Sources/MacParakeetCore/STT/STTProvider.swift` — protocol + `STTProviderID` + `TranscribeOptions` + `STTTranscription` + `STTSegment`
- `Sources/MacParakeetCore/STT/STTProviderRegistry.swift` — registry actor with Task-chain init serialization
- `Sources/MacParakeetCore/STT/ParakeetProvider.swift` — wraps `AsrManager` plumbing; conforms to `STTProvider`. Returns `STTTranscription(result:, detectedLanguage: nil, segments: nil, languageHintIgnored: <flag>)`.
- `Sources/MacParakeetCore/STT/WhisperKitProvider.swift` — wraps `WhisperKit`. Conditionally compiled `#if canImport(WhisperKit)`. Populates all `STTTranscription` fields.
- `Sources/MacParakeetCore/Concurrency/ANESpecializationLock.swift` — cross-process advisory `flock` actor
- `Sources/CLI/Engines/WhisperModelStore.swift` — Handy-style download discipline (CLI-side; not in Core because it's CLI workflow only)
- `Sources/CLI/Engines/TranscribeWatchdog.swift` — no-progress + optional hard-timeout

**Refactored (existing files, behavior-preserving):**
- `Sources/MacParakeetCore/STT/STTRuntime.swift` — internally consumes `ParakeetProvider`. No external behavior change for dictation/meeting paths. `STTRuntime.warmUp()` takes `ANESpecializationLock` during specialization. Regression tests required.
- `Sources/MacParakeetCore/STT/STTClient.swift` — keep as thin compat shim for existing call sites in `OnboardingViewModel`/`SettingsViewModel`/CLI helper paths. Its `transcribe(audioPath:job:)` becomes a wrapper around `STTProviderRegistry.provider(for: .parakeet).transcribe(...)`. No new functionality; existing behavior preserved.

### `STTError` extensions

```swift
public enum STTError: Error {
    // ... existing cases preserved verbatim ...
    case engineError(provider: STTProviderID, message: String)
    case specializationFailed(provider: STTProviderID, underlying: Error?)
}
```

(`languageHintIgnored` is a soft signal in `STTTranscription`, not an error.)

### WhisperKit Sendable + @MainActor spike (HIGH priority — Gemini 2 finding)

WhisperKit 1.x has known `@MainActor`-bound progress callbacks. CLI runs without an `NSApplication` run loop — any `await` that hops to `MainActor` deadlocks permanently. **Half-day spike at the start of Phase 0** to:

1. Audit `WhisperKit`, `WhisperKitConfig`, `DecodingOptions`, `TranscriptionResult`, progress callbacks for `Sendable` conformance and `@MainActor` annotations
2. Construct a minimal headless test: `WhisperKit(WhisperKitConfig(prewarm: true))` from a non-`@main`-annotated CLI process; verify it returns
3. **If `@MainActor` deadlock confirmed:** design isolation strategy. Options: (a) wrap `WhisperKit` calls in `Task { @MainActor in ... }` blocks, (b) call `dispatchMain()` to give the CLI a main run loop, (c) `RunLoop.main.run()` trampoline. Prefer (a).
4. **If `Sendable` gaps remain:** wrap inside `actor WhisperKitProvider` (already planned). Use `@unchecked Sendable` only as last resort with a `// WHY:` comment.

**This spike must complete before `WhisperKitProvider` implementation lands.** If `@MainActor` deadlock can't be resolved cleanly, the whole plan is at risk and we revisit engine choice.

### `argmax-oss-swift` SPM integration spike (Codex 3 finding)

`argmax-oss-swift` is a **meta-package** with multiple products: `WhisperKit`, `SpeakerKit`, `TTSKit`, `ArgmaxCLI`. Adding it as a SwiftPM dependency without specifying a product imports all of them.

**Phase 0 actions:**

1. Pin to a specific version in `Package.swift` (latest stable at implementation time; record the version)
2. Reference only the `WhisperKit` product explicitly:
   ```swift
   .product(name: "WhisperKit", package: "argmax-oss-swift")
   ```
3. Verify no transitive conflict with FluidAudio (FluidAudio has its own diarization; SpeakerKit may overlap). If a conflict surfaces, document the choice.
4. Verify the "old `import WhisperKit` paths re-export" claim is actually true at the pinned version (some meta-package transitions break this).

### AVAudioEngine contention with active meeting (Gemini 2 finding)

WhisperKit's `AudioProcessor` instantiates `AVAudioEngine` on init even on the file-transcription path, to query hardware capabilities. If the GUI is mid-meeting (Core Audio Tap holding system audio), this can trigger audio session reconfiguration and interrupt capture.

**Action:**
1. `WhisperKitProvider.prepare()` checks whether GUI is recording (via a process-shared state mechanism — e.g., a meeting-state file at `~/Library/Application Support/MacParakeet/.meeting.state`)
2. If recording: emit `engine_busy` structured error (exit code 7 with `details.reason = "gui_meeting_active"`) rather than silently breaking the meeting. Agent retries when the meeting ends.

### Headless Parakeet download surprise (Gemini 2 finding)

`--engine parakeet` invoked before onboarding completes will silently trigger the 6 GB Parakeet download. Agent operators on Mac minis won't realize they've started a 6 GB download.

**Action:**
1. `ParakeetProvider.prepare()` checks `AsrModels.isModelCached()` first
2. If not cached: throw `model_missing` (exit 2) with `details.size_bytes: 6_000_000_000` and `details.hint: "Run macparakeet-cli models download parakeet"`
3. Extend `ModelsCommand` to support explicit `models download parakeet` for headless-first installs (parallel to `models download whisper-...`)

### CLI bypasses `STTScheduler` (ADR-016)

`STTScheduler` is process-internal: reserved dictation slot + shared meeting/batch slot inside GUI's `STTRuntime`. The CLI is a separate process; each invocation owns one provider for the lifetime of that process. A coding agent should not wire `WhisperKitProvider` through `STTScheduler` for the CLI path — it's GUI-only.

`STTRuntime` and the GUI's scheduler-driven transcribe paths internally use `ParakeetProvider` for the GUI; this is invisible to the scheduler, which still operates on `AsrManager`-level work (through `ParakeetProvider`).

**Documentation update required:** `integrations/README.md` currently implies concurrent CLI calls share scheduler resources (Gemini 3 finding). Update to make explicit that CLI invocations are not throttled across the cohort; operators manage their own concurrency.

### WhisperKit valid model identifiers

The `--model <variant>` flag accepts any model published in `argmaxinc/whisperkit-coreml` on HuggingFace. Common variants:

- `tiny`, `tiny.en`
- `base`, `base.en`
- `small`, `small.en`
- `large-v3`, `large-v3-v20240930_626MB`, `large-v3-v20240930_turbo_632MB`
- `distil-whisper_distil-large-v3`

WhisperKit resolves these as glob patterns; the canonical reference is the `argmaxinc/whisperkit-coreml` HuggingFace repo. Default: `large-v3-v20240930_turbo_632MB`.

---

## Implementation phases (single PR)

### Phase 0 — Pre-implementation spikes (~1–2 days, blocking)

- [ ] **WhisperKit Sendable + @MainActor spike** — half-day; if deadlock unresolvable, plan needs revision
- [ ] **HF LFS SHA256 spike** — verify HubAPI exposes file-level digests, or pin a checked-in manifest
- [ ] **`argmax-oss-swift` integration spike** — pin version, verify product import, check for transitive conflicts with FluidAudio
- [ ] FluidAudio 0.14.1 `Language` enum verification (already done by Codex 3 review; document outcome — no CJK; soft-accept + log)
- [ ] Cross-process ANE collision repro attempt — try to trigger E5 by running CLI cold during GUI onboarding warmup; whether reproducible or not, the lock ships (cheap insurance)

### Phase 1 — Core abstraction (~3–4 days)

- [ ] Define `STTProvider`, `STTProviderID`, `TranscribeOptions`, `STTTranscription`, `STTSegment`, `STTError` extensions in `MacParakeetCore`
- [ ] Implement `STTProviderRegistry` with Task-chain init serialization + `unload()` between switches
- [ ] Implement `ANESpecializationLock` (`fcntl(F_SETLK)` or `O_EXLOCK`)
- [ ] Implement `ParakeetProvider` wrapping existing `AsrManager` plumbing
- [ ] Refactor `STTRuntime` to consume `ParakeetProvider` internally; `STTRuntime.warmUp()` takes `ANESpecializationLock` during specialization
- [ ] Refactor `STTClient` to delegate transcribe via `STTProviderRegistry`; preserve every existing call site
- [ ] Tests: protocol conformance, registry routing, ANE lock acquire/release, **regression tests for dictation/meeting paths** (this is the GUI hot path that the collapse-to-single-PR puts in the diff — must be airtight)

### Phase 2 — WhisperKit integration (~5 days)

- [ ] Add `argmax-oss-swift` to `Package.swift` — pinned version, explicit `.product(name: "WhisperKit", package: "argmax-oss-swift")`
- [ ] Implement `WhisperKitProvider` conforming to `STTProvider`, conditionally compiled `#if canImport(WhisperKit)`
- [ ] Audio normalization (16 kHz mono Float32) via existing `AudioFileConverter` — both providers receive the converted file URL
- [ ] `prewarm: true`, persistent cache, instance reuse (per Argmax #300)
- [ ] AVAudioEngine contention guard: skip `prepare()` if GUI mid-recording, return structured `engine_busy` error
- [ ] Map WhisperKit `TranscriptionResult` → `STTTranscription` (populate `detectedLanguage`, `segments`, `noSpeechProbability`)
- [ ] Tests: unit (mock provider), integration (real WhisperKit behind `INTEGRATION=1` env flag)

### Phase 3 — Model lifecycle (~3 days)

- [ ] Implement `WhisperModelStore.swift`:
  - Resumable downloads (Range, 206/200 fallback)
  - Bounded retries (3 attempts, 1s/2s/4s + jitter, honor `Retry-After`)
  - Per-host concurrency gate
  - Disk preflight via `FileManager.attributesOfFileSystem(forPath:)`
  - Per-variant `.lock` file (download/verify/delete/warmup honor it)
  - Stale-lock detection
  - Same-volume staging (avoid EXDEV)
  - Atomic rename, RAII cleanup on every error path
  - Stale-file reaper invoked on `models list`
- [ ] SHA256 verify path (per Phase 0 spike outcome)
- [ ] `models download/list/verify/delete <variant>` extended in `ModelsCommand` for both engines
- [ ] Storage: `~/Library/Application Support/MacParakeet/models/stt/whisper/<variant>/`
- [ ] Tests: download resume, retry-on-503, disk-full preflight, concurrent-delete-during-warmup, EXDEV repro, SHA256 mismatch, partial-file resume corruption

### Phase 4 — CLI surface (~2–3 days)

- [ ] CLI flags per § "CLI flag set"
- [ ] `--engine` dispatch in `TranscribeCommand` (constructs provider via `STTProviderRegistry`)
- [ ] `--language` soft-accept for Parakeet (FluidAudio `Language` enum has no CJK; surface `language_hint_ignored: true` in metadata when applicable)
- [ ] `--include-metadata` opt-in (additive `metadata` wrapper, doesn't disturb v1.2 success/error fields)
- [ ] `--timeout` (default 0); always-on no-progress watchdog (60s) **starts after first progress event**
- [ ] `engines list` subcommand with documented JSON schema
- [ ] JSON envelope: byte-identical v1.2 default; `details` additive on errors; `metadata` additive on success only with flag
- [ ] Schema-lock golden tests — six files: clean WAV success, model_missing (exit 2), audio_invalid (exit 3), SIGINT (exit 4), engine_hang (exit 6), unknown engine (exit 7)
- [ ] Headless Parakeet pre-check (`model_missing` exit 2 if not cached)
- [ ] Exit codes 0/2/3/4/5/6/7 fully wired

### Phase 5 — Telemetry coordination (must merge before CLI 1.3.0)

- [ ] Add `engine`, `modelVariant`, `failureStage` fields to `cliOperation` event in `TelemetryEvent.swift`
- [ ] Add `cliWarmupStarted/_succeeded/_failed` events to `TelemetryEventName` enum
- [ ] PR to `macparakeet-website` adding the three new event names to `ALLOWED_EVENTS` in `functions/api/telemetry.ts`
- [ ] **Block CLI 1.3.0 merge until allowlist PR is deployed** — verify with curl that a sample event lands in D1
- [ ] All new emissions go through `CLITelemetry.configureIfNeeded()` (respects `MACPARAKEET_TELEMETRY=0`)

### Phase 6 — Documentation + integration (~2 days)

- [ ] Update `integrations/README.md` with engine selection + language coverage table from this plan
- [ ] New section in `integrations/README.md`: "Running CLI alongside the desktop app" — document ANE lock behavior, what to do if a meeting is in progress, `MACPARAKEET_TELEMETRY` opt-out
- [ ] Note in `integrations/README.md` that CLI bypasses `STTScheduler`; concurrent CLI invocations are not throttled
- [ ] Update `Sources/CLI/CHANGELOG.md` for 1.3.0 — additive changes only, list every new field in the `details` payload
- [ ] Update `AGENTS.md`
- [ ] Add multilingual examples to `integrations/openclaw/README.md` and `integrations/hermes/README.md` (with the demand-evidence caveat in mind — see Risks)
- [ ] Update `/agents` page on macparakeet.com
- [ ] Add `THIRD_PARTY_LICENSES.md` at repo root with WhisperKit + model attributions

### Phase 7 — Validation (~2 days)

- [ ] "Walk the docs as a fresh agent" CI test
- [ ] Manual end-to-end: brew install, follow integration docs cold, every documented command works
- [ ] **Cross-process ANE soak test:** 100 iterations of CLI cold start while GUI is launching; expect zero crashes
- [ ] **Concurrent CLI test:** 4 parallel invocations against same variant; per-variant lock prevents corruption
- [ ] **Disk-full simulation:** cap free disk at 100 MB; preflight fails cleanly with structured error
- [ ] **Telemetry verification:** emit each new event once via test fixture; confirm Worker accepts (D1 row count increments)
- [ ] **Regression suite:** dictation, meeting recording, GUI file transcription all unaffected by the `STTRuntime` refactor
- [ ] Ship to small set of agent operators before ClawHub / awesome-hermes-agent registry promotion

---

## Out of scope

- **Auto-routing / language detection** — `--engine auto`, multi-point sampling, drift detection. v0.8+ pending demand signal.
- **Streaming WhisperKit** — `--stream`. v0.8+
- **WhisperKit translation mode** — `--task translate`. Code path can exist; flag not promoted.
- **Idle-unload watcher** — v0.7.x patch.
- **Multilingual via `mlx-qwen3-asr`** — see reversal triggers; v0.8+
- **Cloud STT providers** — Deepgram, AssemblyAI, OpenAI Whisper API. ADR-002 says no.
- **Diarization for WhisperKit** — Argmax has SpeakerKit; FluidAudio has Parakeet diarization. Don't unify.
- **GUI multilingual UX** — even though `STTRuntime` is now multi-engine-capable internally after this PR, surfacing engine choice in Settings (e.g., "Use Whisper for languages outside Parakeet's range" toggle, defaulted off, user-driven) is a separate plan/PR. Would let GUI file transcription handle Korean YouTube/uploads. v0.8+.
- **Model auto-update** — no Sparkle for STT models. User pulls explicitly.
- **`--language ja,ko,en` (multiple)** — anarlog pattern; defer until single-language ships solidly.

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

4. **Quality benchmark** — Qwen3-ASR achieves ≥ 10% relative CER improvement over WhisperKit on a defined Mandarin/Japanese/Korean test corpus we own.

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

**Deliverable:** `THIRD_PARTY_LICENSES.md` at repo root in Phase 6. Five-line entry in `--version --verbose`: "Speech recognition powered by NVIDIA Parakeet (CC-BY-4.0) and OpenAI Whisper via WhisperKit (MIT)" satisfies CC-BY's attribution requirement.

Architectural research is not a license issue — patterns aren't copyrightable.

---

## Open decisions

- [ ] **Default Whisper variant** — `large-v3-v20240930_turbo_632MB` (lean turbo). Locked unless Phase 0 surfaces a reason to revisit.
- [ ] **`argmax-oss-swift` version pin** — pending Phase 0 integration spike. Lock to specific tag.
- [ ] **HF LFS SHA256 source** — pending Phase 0 spike: HubAPI vs pinned manifest.
- [ ] **WhisperKit `@MainActor` strategy** — pending Phase 0 spike outcome (`Task @MainActor` wrapper vs run loop trampoline).
- [ ] **Agent operator beta** — identify ≥1 external operator with stated CJK transcription need before promoting to ClawHub/awesome-hermes-agent registries. Demand evidence is currently thin.

---

## Risks

| Risk | Probability | Impact | Mitigation |
|---|---|---|---|
| In-process simultaneous specialization E5 crash (Dictus) | Mitigated | High | Registry init serialization (Task-chain) + `unload()` between providers |
| **Cross-process ANE specialization collision (CLI + GUI)** | Plausible, unverified | High (E5 crash, possibly propagates to GUI mid-meeting) | Two-sided `flock` lock from day one; soak test in Phase 7 |
| **WhisperKit `@MainActor` deadlock in headless CLI** | Unknown — must spike | Critical (CLI hangs forever) | Phase 0 spike; `Task @MainActor` wrapper or run loop trampoline |
| **WhisperKit `AVAudioEngine` instantiation interrupts active meeting** | Plausible | Medium | Check GUI meeting state; defer prepare or fail with `engine_busy` error |
| **HF LFS SHA256 doesn't match bytes-on-disk** | Unknown — must spike | High (`models verify` is meaningless without it) | Phase 0 spike; fallback to checked-in manifest |
| **`argmax-oss-swift` meta-package transitive conflict with FluidAudio** | Plausible | Medium | Pin version + explicit `.product(name:)`; verify no SpeakerKit/TTSKit drag-in |
| **Telemetry allowlist drift between repos** | High if not managed | Medium (silent batch drops) | Phase 5 blocks ship; verify with curl post-deploy |
| **Demand evidence is thin** (ClawHub/Hermes integration docs are boilerplate) | Acknowledged | Medium | Identify ≥1 external operator with CJK need before registry promotion; success metric (≥5% Whisper invocation rate) is a target with no baseline |
| **JSON envelope changes break strict parsers** | Mitigated | Medium | Default `--json` byte-identical to v1.2 (only `details` additive on errors); metadata wrapper opt-in |
| **Watchdog kills legitimate long transcriptions** | Low | Medium | Hard `--timeout` defaults to 0; no-progress watchdog only ticks after first progress event |
| **`models delete` during warmup corrupts state** | Plausible | Medium | Per-variant `.lock` file honored by all model commands |
| **EXDEV cross-volume rename failure** (managed homes) | Plausible | Medium | Same-volume staging dir |
| **Orphaned extraction artifacts on SIGKILL** | Low | Low | Stale-file reaper on `models list` |
| **WhisperKit becomes deprecated / acquired-and-killed** | Very low | High | Provider abstraction makes swap cheap; `mlx-qwen3-asr` is fallback |
| **Headless Parakeet 6 GB silent download** | Mitigated | Medium | Pre-check + structured `model_missing` error |
| **Adding a second engine bloats CLI binary** | Low | Medium | Measure pre/post; if bad, gate WhisperKit at a separate brew formula |

---

## Sequencing relative to other work

- **v0.6.0** ships first (meeting recording stable). No multilingual work touches v0.6.
- **v0.7** — single PR per this plan. CLI 1.3.0 + telemetry allowlist deploy. GUI's `STTRuntime` consumes `ParakeetProvider` internally (no observable behavior change in dictation/meeting).
- **v0.7.x** — idle-unload watcher; Whisper UX iteration based on agent operator feedback.
- **v0.8+** — reversal trigger evaluation. Possibly add Qwen3-ASR. Possibly add `--engine auto`. Possibly add GUI Settings toggle for "Use Whisper for non-Parakeet languages."

---

## Success signals (4–8 weeks post-ship)

**Acknowledged:** demand evidence is thin. OpenClaw/Hermes integration docs are boilerplate; no field reports of CJK transcription needs. The metrics below are targets, not baselines.

**Good ship:**
- WhisperKit `--engine whisper` invocation rate ≥ 5% of total CLI transcribes (telemetry, opt-in)
- ≤ 1 P0 issue from agent operators on the WhisperKit path in first month
- Zero `cliWarmupFailed` ANE-signature events in telemetry — proves cross-process risk was mitigated
- ≥ 1 external "macparakeet-cli + Hermes/OpenClaw for non-English transcription" guide published
- ClawHub / awesome-hermes-agent submissions accepted with multilingual mentioned
- Argmax issue tracker: zero new MacParakeet-specific bug reports

**Bad ship:**
- WhisperKit usage < 1% — built it for nobody
- ≥ 3 ANE crash reports in 2 weeks — lock was wrong/insufficient
- P0: "WhisperKit Korean unusable in practice" — wrong engine choice; reversal triggers fire toward Qwen3-ASR
- GUI dictation/meeting regression caused by the `STTRuntime` refactor — single-PR risk realized

**Ambiguous:**
- High Whisper usage but mostly English — users defaulting to Whisper because they don't trust Parakeet's English quality (= docs failure, not engine failure)

---

## References

### Internal
- ADR-016 (centralized STT runtime + scheduler)
- ADR-002 (local-first processing, amended)
- `plans/active/cli-as-canonical-parakeet-surface.md`
- `Sources/CLI/CHANGELOG.md` (semver contract)
- `integrations/README.md` (downstream agent vocabulary)
- `docs/telemetry.md` + ADR-012 (telemetry system)

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

### Multi-LLM review pass (2026-04-27)
- 6 reviewers: Gemini 1 (architecture), Gemini 2 (risk), Gemini 3 (agent UX), Codex 1 (Swift feasibility), Codex 2 (operational), Codex 3 (contrarian)
- Convergence buckets: 2 CRITICAL (FluidAudio CJK enum, JSON envelope contract), 8 HIGH (lock day-one, SHA256 source, retry/backoff, disk preflight, telemetry allowlist, ModelsCommand abstraction needed, meta-package import, STTResult fields), 11 MEDIUM, 5 LOW
- Strategy unchallenged: zero reviewers questioned Parakeet-default + Whisper-opt-in or WhisperKit-over-Qwen3
