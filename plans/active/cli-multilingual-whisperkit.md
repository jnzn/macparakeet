# Plan: macparakeet-cli multilingual STT via WhisperKit

> Status: **ACTIVE**
> Author: Daniel + agent (Claude)
> Date: 2026-04-26 (last updated after 2 rounds of Codex + Gemini review + scope reset)
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

**Why this scope:** auto-routing is speculative product design. We don't yet know whether agent operators want it or prefer explicit choice. Shipping the simpler thing first preserves the option to add intelligence later as a non-breaking feature, and avoids speculative complexity (multi-point sampling, VAD-aware detection, confidence weighting, drift policies) without an agent-demand signal yet.

**Why WhisperKit, not `mlx-qwen3-asr`:** Reliability beats novelty for an agent-facing surface. WhisperKit has 2+ years of production deployment across many shipping apps; our MLX port is 2 months old, single-maintainer, untested in production. `mlx-qwen3-asr` stays as a tracked v0.8+ strategic move when reversal triggers fire.

**v0.7 scope is file transcription only.** Dictation and meeting recording stay Parakeet-only forever (or until Parakeet-Multilingual ships).

---

## Pre-work — Parakeet CJK quality test (informational, not blocking)

The FluidAudio 0.12.4 README states:

> "Parakeet TDT v3 (0.6b) and other TDT/CTC models for batch transcription supporting 25 European languages, Japanese, and Chinese"

Without auto-routing, the architecture doesn't depend on this claim. But we still need to know **what to tell users in the docs.** If Parakeet handles Japanese well, "use the default for Japanese audio" is reasonable advice. If it doesn't, docs say "Japanese requires `--engine whisper`."

### Test protocol

Multi-condition corpus per language (Japanese, Mandarin, Korean):

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

## Architecture

Synthesized from comparable open-source projects (research summary in §"Lessons from comparable projects" below) and refined through two rounds of Codex + Gemini critical review plus a scope reset to user-driven engine selection. Influences: VoiceInk's `TranscriptionService` pattern, Argmax's `WhisperKitConfig`, Dictus' explicit ANE-serialization safety guard, Handy's download discipline.

### `STTProvider` protocol — single protocol, batch only (v0.7)

```swift
public protocol STTProvider: Sendable {
    var identifier: STTProviderID { get }
    var supportedLanguages: Set<BCP47Language> { get }   // metadata; not used at routing time
    var isReady: Bool { get }

    func prepare(modelIdentifier: String) async throws
    func unload() async   // ANE eviction before next engine prepares
    func transcribe(
        _ audio: AudioSamples,
        options: TranscribeOptions
    ) async throws -> TranscribeResult
}

public enum STTProviderID: String, Sendable, Codable {
    case parakeet
    case whisper
    // case qwen3 — v0.8+ if reversal triggers fire
}
```

`supportedLanguages` is metadata-only in v0.7. Used by `macparakeet-cli engines list --json` and by the validator that rejects `--engine parakeet --language ja` (Parakeet TDT v3 is auto-only — see Hex's settings UI). Not used at runtime for routing because we don't auto-route.

**Why this minimal shape:**

- **No streaming method.** MacParakeet has zero streaming transcription anywhere in the codebase today (verified via grep). Streaming is genuinely speculative for v0.8+; declaring `transcribeStream` later when actually needed is non-breaking.
- **No `Set<STTCapability>` flags.** With FluidAudio + WhisperKit (and likely future Qwen3-ASR), every plausible engine in our stack supports the same capability set. Capability flags would never fire.
- **Not split into two protocols.** Splitting solves heterogeneous-engine problems; we don't have heterogeneous engines.
- **`unload()` is required.** CoreML "specialization" can retain weights on ANE even after Swift dealloc. Switching engines without unload → swap-storm or E5 memory pressure on 8/16 GB Macs (Gemini finding).

When streaming arrives (if ever): add `transcribeStream` directly to this protocol when both engines actually implement it.

### Provider registry

```swift
public actor STTProviderRegistry {
    private var providers: [STTProviderID: any STTProvider] = [:]
    private var activeProvider: STTProviderID?
    private let initLock = AsyncSemaphore(value: 1)  // serialize CoreML/ANE loads

    public func provider(
        for id: STTProviderID,
        modelIdentifier: String? = nil   // honors --model flag; falls back to default
    ) async throws -> any STTProvider {
        await initLock.wait()
        do {
            // ANE eviction: unload the active engine before preparing a new one
            // (CoreML graphs specialized on ANE simultaneously cause E5 crashes).
            if let active = activeProvider, active != id {
                await providers[active]?.unload()
                activeProvider = nil
            }

            // Get-or-create with writeback so subsequent unload() finds the instance.
            let provider: any STTProvider
            if let cached = providers[id] {
                provider = cached
            } else {
                provider = makeProvider(id)
                providers[id] = provider   // writeback — Codex finding
            }

            if !provider.isReady {
                let model = modelIdentifier ?? defaultModel(for: id)
                try await provider.prepare(modelIdentifier: model)
            }

            activeProvider = id
            await initLock.signal()
            return provider
        } catch {
            await initLock.signal()  // explicit release on every error path — Codex finding
            throw error
        }
    }
}
```

Three pseudocode bugs caught by reviewers and fixed:

- `modelIdentifier` parameter accepted (so `--model` flag isn't a no-op)
- Provider written back to `providers[id]` after creation (so subsequent `unload()` finds it)
- Semaphore released via explicit `signal()` at every return path, not via deferred `Task` (avoids holding the lock past the ANE-critical section under thread-pool saturation)

**Compile-time gate:** `#if canImport(WhisperKit)` (per VOX) so the CLI builds when the dep is unavailable.

### Engine init serialization (CRITICAL — Dictus' learned-the-hard-way comment)

> "Never run Parakeet model load simultaneously with WhisperKit prewarm. Both use the Neural Engine for CoreML compilation. Simultaneous compilation causes ANE 'E5 bundle' crashes."
> — `getdictus/dictus-ios:ParakeetEngine.swift:14-17`

The registry's `prepare()` for any engine MUST go through one async semaphore. No exceptions.

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
| Force language to Parakeet | `transcribe file.wav --engine parakeet --language ja` | **REJECTED — exit code 7.** Parakeet is auto-only (per Hex's settings UI). `--language` is only valid with `--engine whisper`. Error message tells user how to fix. |

**Why no auto-routing:** detecting language at runtime is real product complexity (multi-point sampling vs first-30s, VAD-aware vs fixed offsets, confidence weighting, drift handling). All of it is speculative without agent-operator demand signal. Defer to v0.8+ when there's actual evidence users want auto-detection.

When auto-routing eventually ships (if it ever does), it slots in as `--engine auto` without changing existing behavior. `--engine parakeet` and `--engine whisper` keep doing exactly what they do today.

### Audio normalization

WhisperKit hard-requires **16 kHz mono Float32**. The CLI already does FFmpeg-based decoding for non-WAV input; ensure the post-decode pipeline produces this format before handing off to either engine.

### Watchdog / hang detection (Gemini finding — day-one requirement)

WhisperKit issues #352, #410, #198 are real production hang reports. Agents that subprocess this CLI **cannot tolerate hangs** — accumulated ghost processes will degrade Mac mini deployments running OpenClaw/Hermes.

**Implementation:**

- `--timeout <seconds>` flag (default 600 = 10 min). Hard SIGTERM at expiry; exit code 6.
- Internal progress watchdog: if no progress event from the engine for N seconds (default N=60), emit structured timeout error and exit. Exit code 6.
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
| 7 | Invalid argument combination (e.g., `--language` with `--engine parakeet`) |

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
  --language <bcp47>               (Whisper only) force decode language. Rejected with --engine parakeet.
  --word-timestamps                Word-level timing in output
  --timeout <seconds>              Watchdog (default: 600)
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

## Implementation phases

### Phase 0 — Pre-work (informational, ~1 hour)

- [ ] Run Parakeet CJK quality test (§ "Pre-work" above)
- [ ] Capture results in `docs/audits/parakeet-cjk-coverage-2026-XX.md`
- [ ] Use results to write the language coverage table in user docs

### Phase 1 — Provider abstraction (~3 days)

- [ ] Define `STTProvider` protocol in `MacParakeetCore`
- [ ] Define `STTProviderRegistry` actor with init serialization (semaphore around `prepare()`)
- [ ] Refactor existing Parakeet path to implement `STTProvider`
- [ ] Add `#if canImport(WhisperKit)` scaffolding (no impl yet, just the gate)
- [ ] Tests: protocol conformance, registry routing by ID, init serialization, ANE eviction (no double-load races)

### Phase 2 — WhisperKit integration (~5 days)

- [ ] Add `argmaxinc/argmax-oss-swift` as Swift Package dep, gated on `canImport`
- [ ] Implement `WhisperKitProvider` conforming to `STTProvider`
- [ ] Audio normalization layer (16 kHz mono Float32)
- [ ] Model lifecycle: `models download`, `models list`, `models verify` (Handy-style discipline)
- [ ] Storage path: `~/Library/Application Support/MacParakeet/models/whisper/<variant>/`
- [ ] `prewarm: true`, persistent cache, instance reuse
- [ ] Tests: download resume, SHA256 verify, mock provider for unit tests, real WhisperKit for integration tests behind a flag

### Phase 3 — CLI surface (~3 days)

- [ ] CLI flags per § "CLI flag set"
- [ ] `--engine` parsing + dispatch to registry
- [ ] `--language` validation: reject with exit code 7 when paired with `--engine parakeet`
- [ ] `--include-metadata` opt-in for JSON metadata wrapper
- [ ] `--timeout` watchdog with hang detection (exit code 6)
- [ ] `engines list` subcommand
- [ ] JSON envelope: byte-identical v1.2 by default; metadata wrapper only with `--include-metadata`
- [ ] Schema-lock tests: golden-file test that `--json` (no flag) output is byte-identical to v1.2 across every documented scenario
- [ ] Exit codes 0/2/3/4/5/6/7 fully wired with structured error envelopes

### Phase 4 — Documentation + integration (~2 days)

- [ ] Update `integrations/README.md` with engine-selection section + language coverage table from Phase 0
- [ ] Update `Sources/CLI/CHANGELOG.md` for 1.3.0
- [ ] Update `AGENTS.md` if needed
- [ ] Add multilingual examples to `integrations/openclaw/README.md` and `integrations/hermes/README.md`
- [ ] Update `/agents` page on macparakeet.com
- [ ] Add `THIRD_PARTY_LICENSES.md` (or `NOTICE`) at repo root with WhisperKit + model attributions

### Phase 5 — Validation (~2 days)

- [ ] "Walk the docs as a fresh agent" CI test — every example in integrations/README.md exercised in CI
- [ ] Manual end-to-end test: install via brew, follow integration docs cold, verify each documented command works
- [ ] Ship to small set of agent operators before full registry promotion

---

## Out of scope

The following are explicitly NOT in v0.7:

- **Auto-routing / language detection** — `--engine auto`, multi-point sampling, VAD-aware sampling, drift detection, confidence-weighted majority. Add when there's real agent-operator demand signal. v0.8+.
- **Streaming WhisperKit** — `--stream`, partial result emission. v0.8+.
- **WhisperKit translation mode** — `--task translate`. Code path can exist; flag not promoted.
- **Idle-unload watcher** — auto-unload after N seconds. v0.7.x patch.
- **Multilingual via mlx-qwen3-asr** — see reversal triggers; v0.8+.
- **Cloud STT providers** — Deepgram, AssemblyAI, OpenAI Whisper API. ADR-002 says no. Maybe v1.0 if signal.
- **Diarization for WhisperKit** — Argmax has SpeakerKit; we have FluidAudio diarization on Parakeet. Don't unify yet.
- **GUI multilingual** — CLI proves the abstraction first; GUI follows in a later release.
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

---

## Risks

| Risk | Probability | Impact | Mitigation |
|---|---|---|---|
| WhisperKit ANE specialization conflicts with Parakeet load (E5 bundle crash) | High if not mitigated | High | Init serialization semaphore + `unload()` between switches |
| Model download size + first-run UX | Medium | Medium | Two-phase explicit download command; documented expectation |
| WhisperKit thread-safety bugs in production | Low (mature codebase but tracked) | Medium | Actor pattern around progress, instance reuse, periodic reset |
| WhisperKit becomes deprecated / acquired-and-killed | Very low | High | Provider abstraction makes swap cheap; mlx-qwen3-asr is fallback |
| Adding a second engine bloats CLI binary | Low | Medium | Measure pre/post; if bad, gate WhisperKit at a separate brew formula |
| Watchdog kills legitimate long transcriptions | Low | Low | `--timeout` opt-in extension; default 10 min covers most cases |

---

## Sequencing relative to other work

- **v0.6.0** ships first (meeting recording stable). No multilingual work touches v0.6.
- **v0.6.x soak time** — run Parakeet CJK quality test; capture results for docs.
- **v0.7** — full plan above. CLI 1.3.0.
- **v0.7.x** — idle-unload watcher.
- **v0.8** — reversal trigger evaluation. Possibly add Qwen3-ASR. Possibly add `--engine auto` if there's demand.

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
