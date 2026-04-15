# MacParakeet Optimization Plan

Generated: 2026-04-14

## TL;DR

- **Live cleanup is on the wrong side of the pause.** `scheduleLiveCleanup` debounces 250 ms but doesn't gate on speech *level* — silent pauses still race the LLM. Plus the debounce duration (250 ms) is less than the EOU partial cadence at 160 ms chunks; identical-text dedup is real but rate-limited only to "next partial after 250 ms". A 500 ms pause-after-silence trigger plus a min-delta heuristic would cut Ollama load by 3–5×. (See `DictationFlowCoordinator.swift:229`)
- **Streaming pipeline has 5 actor hops + 1 NotificationCenter post per partial.** Path: real-time tap → `OSAllocatedUnfairLock.yield` (synchronous) → `AudioRecorder` actor → `AudioProcessor` actor → `DictationService` actor → `streamingPartialHandler` closure → `NotificationCenter.post` (queue: .main) → `Task @MainActor` → `composeDisplayText` → `@Observable` write → SwiftUI re-render. The NotificationCenter hop is gratuitous; a direct `AsyncStream<String>` exposed by `DictationService` and consumed by the coordinator removes 2 of those hops and a Foundation cross-thread bounce.
- **`composeDisplayText` does `String.split + count` on every partial.** Once the recording is at 500 words, that's 500-element arrays allocated and counted ~6–15× per second. Memoize the split-baseline (it only changes when `stableCleanedText`/`rawAtStableCleanup` change), not the input.
- **Mac Air RAM math: gemma4:e2b at 7 GB resident is half of usable memory.** With Parakeet TDT (~6 GB on disk, ~1.5–2 GB working) + EOU 120M (~250–400 MB) + Ollama gemma4:e2b (~7 GB), peak dictation crosses 10 GB before the app's own footprint. Recommend gemma3:1b (~1.3 GB) for live-bubble cleanup and gemma3:4b (~4 GB) only for paste-polish, gated on the toggle.
- **Model keep-alive runs every 120 s for all three models even when nothing happened.** On the Air this prevents ANE eviction (good) but also keeps gemma4:e2b paged in (bad — that's 7 GB held against background apps). Differentiate: ANE keep-alive is cheap (microseconds of compute, ~hundred MB resident), Ollama keep-alive holds gigabytes. Make Ollama keep-alive opt-in or activity-driven (only after recent dictation).

## Methodology

**Tools to use:**

- **Instruments** → Time Profiler template, attach to MacParakeet, run a 30-second dictation. Look at the heaviest stack trees in `_dispatch_main_queue_callback_4CF` and the `MainActor` symbols. Anything in `composeDisplayText`, `String.split`, or SwiftUI's `_redrawTask` that exceeds 1% deserves attention.
- **Instruments → Allocations** with the "Mark Generation" feature. Mark before dictation start, mark again after a 1-minute dictation. Persistent allocations attributable to `[Float]` (waveform), `String` (cumulative partials), or `AVAudioPCMBuffer` are leak candidates.
- **Instruments → SwiftUI** template (Xcode 15+). Look at "View Body" and "View Properties" rows. Anything redrawing more than ~20 Hz during recording is a candidate for `Equatable` or scope-narrowing.
- **`powermetrics --samplers ane,gpu_power,cpu_power -i 1000 -n 30`** while dictating. ANE column should show non-zero `ANE Power` during recording (≥ 100 mW typical). If 0, Parakeet is on CPU/GPU and you've lost the whole point of FluidAudio CoreML.
- **Activity Monitor → Memory tab**, check `MacParakeet.app` resident size before / during / after dictation. Note `ollama runner` separately.
- **`xcrun xctrace` for headless profiling** if you want CI-style perf gates.

**What to expect (baseline guess for 16 GB Air, M2/M3):**

- Dictation start latency: 80–200 ms (mic warmup + tap install)
- Streaming partial cadence: ~6 Hz with 160 ms chunks (model output is ~160 ms shifted)
- End-of-dictation paste: 200 ms (intentional sleep) + 50–150 ms (clipboard race) + LLM polish if enabled (1–3 s for gemma3:1b, 5–10 s for gemma4:e2b)

## Findings by Area

### 1. Streaming pipeline actor hops

**Files:** `Audio/AudioRecorder.swift:303-433`, `Audio/AudioProcessor.swift:14`, `STT/StreamingEouDictationTranscriber.swift:62-72`, `Services/DictationService.swift:431-497`, `App/DictationFlowCoordinator.swift:161-179`

**Hop count for one buffer end-to-end:**

| Step | Where | Cost |
|---|---|---|
| 1. AVAudio tap callback fires | real-time audio thread | non-actor |
| 2. RMS + level update | OSAllocatedUnfairLock | ~50 ns |
| 3. Convert + write WAV | `AVAudioConverter` (sync in tap) | ~10–50 µs |
| 4. `broadcastContinuation.yield(buffer)` | OSAllocatedUnfairLock + AsyncStream enqueue | ~100 ns |
| 5. AsyncStream consumer in `DictationService.startStreamingSessionIfEnabled` | hops to actor | ~µs |
| 6. `transcriber.appendAudio(buffer)` | hop to `StreamingEouDictationTranscriber` actor | ~µs |
| 7. `manager.appendAudio` then `processBufferedAudio` | hops to FluidAudio `StreamingEouAsrManager` actor | ~µs+ EOU encoder cost |
| 8. EOU emits partial via `setPartialTranscriptCallback` → `AsyncStream<String>` continuation | actor-bound callback | ~ns |
| 9. `for await partial in partialStream` (inside the streaming task on `DictationService`) → `await self?.reportStreamingPartial` → `streamingPartialHandler(partial)` closure | hop back to actor | ~µs |
| 10. `NotificationCenter.default.post(name: .macParakeetStreamingPartial)` from inside the actor | non-actor work, then NC delivery to main runloop | µs+ |
| 11. NC observer block (registered with `queue: .main`) `Task { @MainActor in ... }` | extra hop because the closure is not @MainActor-isolated | ~ms scheduling |
| 12. `composeDisplayText` + `vm.streamingPartialText = ...` | @MainActor write | ns |
| 13. `@Observable` triggers SwiftUI tree refresh | dependent on view tree size | varies |

**Redundant hops:**

1. **NotificationCenter as a post-hop is gratuitous** — `DictationService` calls a `streamingPartialHandler` closure passed in from `AppEnvironment.swift:147-153`. That closure synchronously calls `NotificationCenter.default.post`. The coordinator then registers an observer on `.main` queue that *also* hops with `Task { @MainActor }`. So we go: actor → closure → NC → main runloop → NC observer block → Task hop → finally @MainActor body. **Replace** with: `DictationService` exposes `var streamingPartials: AsyncStream<String>` (or a callback registered as `@MainActor`); the coordinator awaits it directly. Saves at least one Foundation runloop bounce per partial (~0.5–2 ms each). At 6 partials/sec that's measurable.
2. **The `Task { @MainActor [weak self] in ... }` inside the NC observer is double-hopping.** The observer was registered with `queue: .main` so the block already runs on the main thread. The hop exists only to satisfy Swift 6 strict concurrency. If you collapse to a direct `AsyncStream` consumed in a `Task` owned by the coordinator, the @MainActor isolation becomes natural and the hop disappears.

**Impact:** Medium. Per-partial latency probably 1–3 ms today, achievable 0.2–0.5 ms.

**Recommendation:** Replace `streamingPartialHandler` + NotificationCenter with a `@MainActor`-isolated callback registered into `DictationService`, OR expose an `AsyncStream<String>` directly from `DictationService`. Drop `.macParakeetStreamingPartial` from `AppNotifications.swift:29`.

**Effort:** 1 hour. Trivial diff, but touches a Notification name used in tests.

---

### 2. `composeDisplayText` hot path

**File:** `App/DictationFlowCoordinator.swift:191-215`

```swift
let rawWords = rawTrimmed.split(whereSeparator: \.isWhitespace)
let baselineWords = baselineTrimmed.split(whereSeparator: \.isWhitespace)
guard rawWords.count > baselineWords.count else { ... }
let newTail = rawWords.suffix(rawWords.count - baselineWords.count).joined(separator: " ")
```

**Cost analysis:**

- `String.trimmingCharacters` on the raw partial: O(n), allocates a copy.
- `String.split(whereSeparator:)`: O(n), allocates `[Substring]`.
- Hot path runs on every partial (6–12 Hz at 160 ms chunks).
- For a 500-word partial that's ~3000 chars × 2 trims + 2 splits = ~6 string scans + 2 array allocations *every emission*. Not O(n²) but it is O(n) where n grows linearly with dictation length.

**For a 500-word dictation:** ~30 KB of `Substring` arrays churning per second + char-by-char scans of the full 3 KB string. Negligible CPU but real allocator pressure (allocations show up in Instruments as small but persistent).

**Memoization opportunity (high-value):** The `baselineTrimmed` and `baselineWords.count` are derived from `rawAtStableCleanup` — which only changes when `runLiveCleanup` lands a new `stableCleanedText`. Cache those derivations alongside `rawAtStableCleanup`.

**Impact:** Low → Medium. Won't show up in profiler unless you do 5-minute dictations, but cleanup is essentially free.

**Recommendation:** Cache `baselineTrimmed` and `baselineWordCount` alongside `rawAtStableCleanup`. Move the trim/split out of the hot path.

**Effort:** 15 minutes.

---

### 3. Live cleanup debounce / dedup

**File:** `App/DictationFlowCoordinator.swift:229-245`

Current logic:
- 250 ms debounce.
- Identical-text dedup: if `trimmed == pendingCleanupSnapshot && liveCleanupDebounceTask != nil`, skip rescheduling.

**Issue 1 — debounce window too short.** 250 ms is shorter than gaps between word emissions during continuous speech. EOU emits cumulative text every 160 ms. So during continuous speech the timer never fires anyway. During a pause it fires after 250 ms — fine. But the LLM call itself takes 1–5 seconds, and a new partial during that window will reschedule on its tail (covered by the post-LLM `pendingCleanupSnapshot == snapshot` guard, but not before launching the call).

**Issue 2 — no minimum delta.** Currently any text change >0 chars triggers cleanup. After one cleanup lands at "100 words", the next partial adds "and then" → reschedules and re-runs cleanup on 102 words. For a model that responded to the 100-word version, 95% of its work is wasted. Add a minimum-delta gate: only re-trigger if `(trimmed.count - lastCleanedRawCount) > 30` characters or `> 5` new words.

**Issue 3 — identical-truncated stream is real.** EOU sometimes emits the same cumulative text 2–3× as it processes overlapping chunks. The dedup check (`trimmed == pendingCleanupSnapshot`) handles this when the *previous* schedule is still pending. But if cleanup already ran and landed, then a duplicate partial arrives, the dedup check no longer sees it as identical (`pendingCleanupSnapshot` was set to the previous value, and `liveCleanupDebounceTask` is `nil` post-completion). So dedup would re-schedule cleanup for the same text. Add: `if trimmed == lastCleanedSnapshot { return }`.

**Impact:** High for Ollama load on the Air. Currently a 30-second dictation can fire 6–10 cleanup calls; with delta gating + extended debounce it'd fire 2–3.

**Recommendation:**

1. Bump debounce to 400–500 ms (matches the docstring claim of "~450 ms" that the actual code doesn't honor).
2. Add `lastCleanedRawSnapshot: String` and `lastCleanedRawWordCount: Int`. Skip `runLiveCleanup` if delta < 25 chars or < 4 new words.
3. Track `lastCleanedSnapshot` and short-circuit identical-to-already-cleaned.

**Effort:** 30 minutes.

---

### 4. SwiftUI redraws

**Files:** `Views/Dictation/WaveformView.swift`, `Views/Dictation/DictationOverlayView.swift`, `Views/Dictation/DictationOverlayController.swift:183-302` (`DictationOverlayViewModel`)

**Issue 1 — `DictationOverlayViewModel` is a single `@Observable`. Any property write invalidates *all* views observing it.** The model has: `state`, `audioLevel`, `recordingElapsedSeconds`, `isHovered`, `hoverTooltip`, `streamingPartialText`, `micDeviceName`, `cancelTimeRemaining`, plus closures. Every `audioLevel` write (typically 40 Hz from the level loop) re-evaluates body of any View that touches *any* of those properties. SwiftUI's `@Observable` is field-granular *only when SwiftUI can statically detect which fields a body reads*. In practice, the `streamingBubble`'s body reads `viewModel.streamingPartialText`. The waveform's body is wrapped to depend on `viewModel.audioLevel`. The pill-shape body reads many properties.

**Issue 2 — `runRecordingLevelLoop` updates `overlayViewModel.audioLevel` every 25 ms (40 Hz)** (`DictationFlowCoordinator.swift:838-867`). That's higher than necessary — the waveform animates with `easeOut(duration: 0.04)` so the visual update can run at 30 Hz with no perceptual loss. Consider 33 ms (30 Hz).

**Issue 3 — `WaveformView.shiftHistory` builds a new `[Float]` of size 14 every audio sample.** O(n) array reallocation 40 times per second. With `@State private var history: [Float]`, SwiftUI also diffs this array on every change — invalidating the entire `ForEach`.

**Issue 4 — `.animation(value:)` on Each Bar.** `.animation(.easeOut(duration: 0.04), value: history[safe: index] ?? 0)` is set on each of 14 bars. Each bar gets its own implicit animation, so 14 transactions per audio update.

**Issue 5 — `pillContent`'s `.animation(.easeInOut(duration: 0.25), value: viewModel.pillStateKey)` on the outer ZStack** (line 453) and a duplicate one on `overlayContent` (line 404). Two animation transactions for one state change. Also, `pillStateKey` is derived from many `state` cases — recompute happens on every body re-eval.

**Issue 6 — `streamingBubble` recomputes `(NSScreen.main?.visibleFrame.width ?? 1440) * 0.25` on every body call.** `NSScreen.main` access goes to AppKit. Cache once on overlay creation in the controller and pass into the view.

**Impact:** Medium. The waveform path is the main offender — 40 Hz × 14 bars × full subtree re-eval. Likely 1–2% CPU during dictation that can become 0.2–0.4%.

**Recommendations:**

1. Split `DictationOverlayViewModel` into two `@Observable`s: a stable "shape" model (state, sessionKind, recordingMode, hoverTooltip) and a high-frequency "metrics" model (audioLevel, recordingElapsedSeconds, streamingPartialText). Pass the metrics model only to the views that need it. Cuts re-eval scope by ~70%.
2. Drop `WaveformView.audioLevel` from a Float to a fixed-size ring buffer object; mark `WaveformView: Equatable` so SwiftUI can skip re-eval when only `audioLevel` changes but the visible array hasn't.
3. Throttle `runRecordingLevelLoop` from 25 ms → 33 ms. (One-line change.)
4. Cache the screen width once when the overlay is shown.
5. Remove the duplicate `.animation(value: pillStateKey)` (keep one).

**Effort:** 1–2 hours for proper split, 5 minutes for throttle + cache.

---

### 5. Ollama model choice

**Files:** `App/AppEnvironment.swift:215-234` (keep-alive ping), `Services/LLMClient.swift:309-340` (Ollama request, hardcoded `num_ctx: 8192`)

**Current behavior:** A single Ollama provider config (model name + base URL) is used for both live-bubble cleanup and end-of-dictation paste polish. There is no auto-select per surface.

**Per-surface analysis:**

| Surface | Goal | Latency budget | Quality budget |
|---|---|---|---|
| Live-bubble cleanup | "Looks right while typing" | 0.5–1.5 s | Modest — if it lands wrong, the next cleanup fixes it |
| End-of-dictation paste polish | Final text the user accepts | 1–3 s | High — this is what gets pasted |

**Model recommendations on Mac Air 16 GB:**

| Model | RAM | Speed (M2 16 GB est.) | Quality | Best for |
|---|---|---|---|---|
| gemma3:1b | ~1.3 GB | ~80 t/s | Decent for cleanup, often misses subtle homophone fixes | live-bubble |
| gemma3:4b | ~3.5 GB | ~30 t/s | Good, comparable to gemma2:9b on punctuation/grammar | paste-polish |
| gemma4:e2b (current) | ~7 GB | ~45 t/s (E2B is fast for its quality) | Hybrid-thinking, potentially leaks `<channel\|>` artifacts (there's a stripper for this) | overkill for cleanup |

**On Mac Studio (build server + Ollama host):** memory is plenty; the question is whether Tailscale latency is worth offloading. Round-trip Tailscale local network: typically 2–10 ms RTT. Add Ollama TTFT 200–500 ms + token streaming 30–80 t/s. Net: gemma3:4b on the Studio over Tailscale is probably faster *and* higher quality than gemma3:1b on the Air locally for any text > 50 words.

**Smart auto-select policy:**

```
if surface == .liveBubble:
    if input.wordCount < 50:
        use local gemma3:1b   # fast, quality is fine for short
    elif network.tailscaleReachable:
        use studio gemma3:4b  # better quality, paid latency is fine here
    else:
        use local gemma3:1b
elif surface == .pastePolish:
    if network.tailscaleReachable:
        use studio gemma3:4b  # quality matters more
    else:
        use local gemma3:4b   # accept Air RAM cost; it's a one-shot at end
```

**Implementation hook:** `DictationService.cleanupTextLive` (`Services/DictationService.swift:631-658`) and `DictationService.formatTranscriptIfNeeded` (`Services/DictationService.swift:660-718`) both call `llmService.formatTranscript(...)`. The `LLMService` could accept a `surface: Surface` parameter and route to one of two pre-resolved configs.

**Impact:** High on Mac Air RAM (drop from 7 GB resident → 1.3 GB live + 3.5 GB momentarily during paste). High on UX for long dictations (faster live bubble).

**Recommendation:** Add a "Cleanup Model" + "Polish Model" split in LLM settings. Default both to gemma3:1b on Air, both to gemma3:4b on Studio. Document the rationale.

**Effort:** 2–4 hours (LLM config schema + UI).

---

### 6. MLX vs llama.cpp

**Research:** Apple's MLX framework runs Gemma natively on Apple Silicon with metal+ANE. As of late 2025/early 2026:

- **`mlx-lm` Python package** + **`mlx-server`**: serves OpenAI-compatible HTTP. Reports ~1.3–1.8× faster than llama.cpp on M-series for Gemma 2/3 in 8-bit.
- **`mlx-omni-server`**: another OpenAI-shim wrapper. Less mature.
- **`MLXSwift`**: native Swift framework — could embed directly in MacParakeet without a server. Not currently mature for Gemma 3 specifically (Gemma 2 / Llama / Phi well-supported).

**For MacParakeet's workload (Gemma 3:1b/4b cleanup):** MLX would shave ~30–50% off TTFT vs llama.cpp (because Metal kernels are tuned for the exact GPU). But:

1. Ollama auto-handles model downloads, model card metadata, and concurrent request queueing — re-implementing that for MLX is real work.
2. MLX serving doesn't have keep-alive semantics out of the box — you'd lose the 5-minute residency model.
3. The 16 GB Air constraint matters more than the 1.3–1.8× speedup. Smaller model on llama.cpp > larger on MLX.

**Drop-in candidates:**

- `pip install mlx-lm` then `mlx_lm.server --model mlx-community/gemma-3-4b-it-4bit --port 11434`. Almost a drop-in for the existing Ollama HTTP path because both serve OpenAI-compatible JSON. The differences: no `keep_alive` field, different model loading semantics, no `think:false` toggle (MLX doesn't have hybrid thinking yet).

**Verdict:** Not worth switching today. **Reassess** when MLXSwift gets mature Gemma 3 support — at that point an embedded MLX path *eliminates* Ollama process overhead entirely (~150 MB resident for `ollama runner` + much of the process setup), which might matter on the Air.

**Effort if you switched:** 4–8 hours for parallel provider option, 1–2 days for embedded MLXSwift.

---

### 7. Parakeet EOU chunk size

**Files:** `STT/StreamingEouDictationTranscriber.swift:17`, FluidAudio's `StreamingEouAsrManager.swift` and `ParakeetModelVariant.swift`

Current setting: `.parakeetEou160ms` (lowest latency, ~160 ms output cadence). FluidAudio also exposes `.parakeetEou320ms` and `.parakeetEou1280ms`.

**Per FluidAudio internal docs (`StreamingEouAsrManager.swift:16-87`):**

- 160 ms: 17 mel frames, 2 valid encoder outputs/chunk, ~8–9% WER on LibriSpeech test-clean
- 320 ms: 64 mel frames, 4 valid outputs/chunk, ~5.73% WER, 14× RTFx — *better accuracy and higher throughput*
- 1280 ms: 129 mel frames, 16 valid outputs/chunk — too laggy for live bubble

**The 320 ms option is genuinely interesting.** 320 ms latency is still imperceptible for a dictation overlay (humans tolerate up to 500 ms display lag without noticing in this UX). And **5.73% WER vs 8–9% WER is a meaningful quality jump** — fewer wrong words means the live cleanup has less to do, which means the bubble looks more correct sooner *and* fewer cleanup calls fire.

**Tunability:** Per `StreamingModelVariant.createManager`, the variant is locked at construction time — *not* tunable per-session. Switching means destroying and re-loading the manager (and re-downloading the encoder if you'd never used 320 ms before). For dictation purposes, set once at app launch.

**Impact:** Medium — accuracy jump improves the perceived quality of the bubble.

**Recommendation:**

1. Try `.parakeetEou320ms` as the new default. Expose as a hidden runtime preference for A/B testing. Keep 160 ms as fallback if 320 ms feels "laggy" subjectively.
2. Document chunk-size tradeoff in `docs/research/streaming-dictation-spike.md`.

**Effort:** 5 minutes to switch the default constant; 30 minutes to expose a preference.

---

### 8. ANE utilization

**Verification commands** (user homework; can't be run in agent):

```bash
# Sample ANE / GPU / CPU power for 30 seconds
sudo powermetrics --samplers ane,gpu_power,cpu_power -i 1000 -n 30 \
  | grep -E "ANE Power|GPU Power|CPU Power"

# Or, more focused on ANE:
sudo powermetrics --samplers ane -i 500 -n 60 | grep "ANE Power"
```

**Expected output during dictation:**

```
ANE Power: 350 mW    (range 100-800 mW typical for Parakeet TDT inference)
GPU Power: 50 mW     (idle baseline, no shaders running)
CPU Power: 1200 mW   (audio tap + UI + Ollama if local)
```

**Failure modes to look for:**

- **`ANE Power: 0 mW` while transcribing:** Parakeet didn't get scheduled on ANE. Check `MLModelConfiguration.computeUnits` in FluidAudio (default is `.cpuAndNeuralEngine`). If a model's CoreML compilation failed silently, it would fall back to CPU and CPU Power would spike to 4–6W.
- **`GPU Power: 1500–3000 mW` while transcribing:** Parakeet on GPU instead of ANE (slower + higher power). This happens when the CoreML model's compilation flags don't match what ANE expects, or on older macOS versions. Re-download the model via Settings → Speech Model → Repair to recompile.

**Quick CLI check** (no sudo) using FluidAudio's own benchmark:

```bash
swift run macparakeet-cli health
# or
swift run fluidaudiocli asr-benchmark --subset test-clean --max-files 5
```

Watch RTFx — Parakeet TDT 0.6B on M2 ANE should report ~150–180× RTFx. If it's <50×, ANE didn't engage.

**EOU streaming:** Same model family but smaller (120M). Should also use ANE. Verify via `powermetrics` during a streaming dictation specifically.

**Document this in a runbook.** Add `docs/runbooks/verify-ane.md`.

**Effort:** 15 minutes to write the runbook.

---

### 9. Audio pipeline

**Files:** `Audio/AudioRecorder.swift:179-473`

**Format conversion path:**

1. Mic delivers buffers in *whatever format the input bus produces* (`installTap(bufferSize: 4096, format: nil)` — line 303). This is correct — avoids the aggregate-device exception.
2. `AVAudioConverter` cached in `TapConverterCache`, rebuilt only on format drift (line 344). Good.
3. Each buffer: convert to 16 kHz mono Float32 → write to file → broadcast to streaming subscriber.

**This is well-engineered.** Specific observations:

**Issue 1 — RMS computation is a manual loop, not vDSP.** Lines 314–323:

```swift
var rms: Float = 0
for i in 0..<frameCount {
    rms += data[i] * data[i]
}
rms = sqrtf(rms / Float(frameCount))
```

Replace with vDSP for ~3–5× speedup at this hot frequency:

```swift
var rmsValue: Float = 0
vDSP_rmsqv(data, 1, &rmsValue, vDSP_Length(frameCount))
```

Saves ~1–3 µs per buffer × ~25 Hz buffers × continuous recording. Tiny but absolutely free.

**Issue 2 — WAV writing is synchronous on the audio thread.** `try file.write(from: convertedBuffer)` (line 395) blocks the real-time tap on file I/O. macOS file system writes for small chunks normally complete in microseconds, but if the temp directory is on a network drive or under memory pressure, this could glitch the audio thread (and by extension, mute the streaming pipeline for that buffer).

Apple's recommendation for real-time audio: do disk I/O on a separate thread fed by a lock-free FIFO. For dictation it's probably OK because the file is on local SSD in `$TMPDIR`, but worth flagging as a risk.

**Recommendation if it shows up in profiles:** Maintain a `DispatchQueue(label: "wav-writer", qos: .userInitiated)` and async-dispatch buffer writes to it. Buffers are already copied (the tap returns a buffer that AVFoundation may reuse, but `file.write(from:)` reads it synchronously, so you'd need to deep-copy first). Currently the cost of "guaranteed" write-on-tap is acceptable, but it's a known fragility.

**Issue 3 — broadcast yield happens after WAV write.** Line 399. So if WAV write is slow, streaming pipeline is delayed too. Move broadcast yield *before* the file write — the streaming model getting buffers a few microseconds earlier matters more than file integrity (which is governed by `.wav` finalization on `stop()`, not buffer ordering).

**Impact:** Low (typical case), Medium (worst case under disk pressure).

**Recommendations:**

1. Use `vDSP_rmsqv` for level meter. (5 minutes.)
2. Move `broadcastContinuation.withLock { $0?.yield(convertedBuffer) }` before `file.write`. (1 minute.)
3. Document the audio-thread-blocks-on-disk risk; consider async writer if profiling shows pauses.

**Effort:** 10 minutes for items 1+2; 1–2 hours for the async writer.

---

### 10. AppDelegate startup time

**Files:** `MacParakeet/AppDelegate.swift:227-241`, `App/AppStartupBootstrapper.swift`, `App/AppEnvironment.swift:38-209`

**Current startup flow:**

1. `applicationDidFinishLaunching` runs `startEnvironmentSetup()` → spawns a Task that calls `bootstrapEnvironment()`.
2. `bootstrapEnvironment` runs `Task.detached(.userInitiated)` to: ensure dirs, open SQLite, run cleanup queries.
3. Back on main, constructs `AppEnvironment` synchronously. This:
   - Instantiates 7 repositories (cheap, just GRDB queue references)
   - Creates `STTRuntime`, `STTScheduler` (lazy — model not loaded yet)
   - Creates `AudioProcessor`, `ClipboardService`, etc. (all cheap)
   - Reads keychain for licensing config (one keychain hit)
   - Reads multiple Bundle.main.object(forInfoDictionaryKey:) (cheap)
   - Constructs `LLMClient` and `LLMService` (URLSession.shared — eager creation, but no network calls)
   - Constructs `StreamingEouDictationTranscriber` — *does not load models* until first dictation
   - Spawns `modelKeepAliveTask` — runs immediately but first action is `Task.sleep(120s)`
   - `TelemetryService` constructor + `Telemetry.send(.appLaunched)` — fires HTTP. Cheap to enqueue.

**Mic-ready latency:** The mic is "ready" when `AudioRecorder.start()` returns successfully — that's the first tap `installTap` call. Until then, nothing capturing.

**Estimate:** ~50–150 ms from launch to mic-ready, dominated by SQLite open + AppKit menu bar setup. **Hard to improve without measurement.**

**Issues:**

1. **`STTRuntime` lazily inits on first dictation, NOT at launch.** First dictation incurs:
   - Model file scan
   - CoreML compilation (`AsrModels.downloadAndLoad`)
   - Two `AsrManager.loadModels` calls (interactive + background slots)
   - Total: 5–30 s cold start, 1–3 s warm cache

   This is by design — `STTRuntime.backgroundWarmUp()` is *available* but **not called automatically at launch.** Search confirms it's only invoked from the onboarding flow. **This is a real UX issue** — first dictation after app restart is surprising.

   **Recommendation:** After `setupEnvironment(env)` in `AppDelegate.swift:243`, call `Task.detached { await env.sttScheduler.backgroundWarmUp() }`. The user typically launches the app and starts dictating within 30–60 s — if warming starts in the background immediately, the first dictation is instant.

2. **`StreamingEouDictationTranscriber` also lazy-loads.** Same fix: warm it after launch if `streamingOverlayEnabled`.

3. **Telemetry HTTP fires synchronously-enqueued at launch.** Already async in URLSession; not a real issue.

4. **`modelKeepAliveTask` first ping is 120 s after launch.** Fine.

5. **Sparkle's `SPUStandardUpdaterController(startingUpdater: true)` initializer can spend tens of ms on first launch checking appcast.** Already wrapped per-config (`#if DEBUG` doesn't auto-start). Negligible.

**Impact:** High for first-dictation feel (5–30 s → <1 s with warmup).

**Recommendation:** Add a `startupWarmup` sequence after `setupEnvironment` returns:

```swift
Task.detached(priority: .utility) {
    await env.sttScheduler.backgroundWarmUp()
    if env.runtimePreferences.streamingOverlayEnabled {
        try? await env.streamingDictationTranscriber.loadModels()
    }
}
```

**Effort:** 10 minutes.

---

### 11. Model keep-alive efficiency

**File:** `App/AppEnvironment.swift:161-186`

**Current schedule:** Every 120 s, if not actively dictating:

1. `sttScheduler.keepAlive()` — runs `manager.transcribe([Float](repeating:0, count: 16000), source: .microphone)`. Full encoder+decoder pass on 1 second of silence on the **interactive** slot. (`STTRuntime.swift:213-221`)
2. If streaming enabled: `streamingDictationTranscriber.keepAlive()` — appends 1 s of silence to the EOU manager, then `processBufferedAudio()`, then `reset()`. (`StreamingEouDictationTranscriber.swift:101-122`)
3. If Ollama provider configured: `Self.pingOllamaKeepAlive(config:)` — POSTs `messages: ["hi"], num_predict: 1, keep_alive: "5m"`. (`AppEnvironment.swift:215-234`)

**Cost per ping:**

| Component | CPU/ANE time | Wall time | Memory held |
|---|---|---|---|
| Parakeet TDT silence | ~50–100 ms ANE | ~150 ms | ~1.5–2 GB (already resident if loaded) |
| EOU silence | ~10–30 ms ANE | ~50 ms | ~250–400 MB (already resident) |
| Ollama 1-token chat | ~100–300 ms inference | ~300–500 ms | gemma4:e2b at 7 GB stays resident |

**Math vs cold start:**

- Parakeet cold start: 5–30 s (CoreML compile from cache: ~3–5 s; first inference: ~500 ms–2 s)
- Parakeet warm-recovery (ANE evicted, cache valid): ~500 ms
- EOU cold start: 1–3 s
- Ollama gemma4:e2b cold load: 5–15 s
- Ollama gemma3:1b cold load: 1–3 s

**Conclusion per model:**

- **Parakeet TDT keep-alive: keep it.** ANE eviction happens in 30–90 s of idleness on macOS. Pinging every 120 s guarantees recovery latency ≤ ~120 ms (warm-recovery cost). Without keep-alive, every dictation after a 5-min lull pays ~500 ms.
- **EOU keep-alive: keep it** — same logic, plus EOU's encoder cache is sensitive to cold starts (it holds streaming state).
- **Ollama keep-alive: SUSPECT.** On the Air, gemma4:e2b held at 7 GB resident *all the time* is a tax other apps pay. The user only invokes the formatter when AI-formatter is enabled AND a dictation completes. If they go 4 hours without dictating (say overnight), the model has been pinned in RAM for nothing — and Ollama's normal 5-min idle eviction would have done the right thing.

**Recommendation for Ollama keep-alive:** Pin only after recent dictation activity (last 10 minutes):

```swift
// In AppEnvironment, track last dictation timestamp:
private var lastDictationCompletedAt: Date?

// Keep-alive task only pings Ollama if recent activity:
if runtimePreferences.aiFormatterEnabled,
   let last = lastDictationCompletedAt,
   Date().timeIntervalSince(last) < 600,  // active in last 10 minutes
   ...
```

This keeps Ollama warm during a writing session (when you're using dictation), and lets it idle-evict overnight.

**Also:** keep-alive for Parakeet currently runs the **interactive** slot only. The background slot can evict; meeting/file transcription would re-pay the cold start. For a dictation-focused user this is fine, but document it.

**Impact:** Medium-High on Mac Air (free up 7 GB during idle periods).

**Recommendation:** Make Ollama keep-alive activity-driven (last 10 min of dictation). Keep Parakeet/EOU keep-alives unconditional.

**Effort:** 30 minutes.

---

### 12. Memory pressure on 16 GB Mac

**Estimated peak during dictation with all features enabled:**

| Component | Resident | Notes |
|---|---|---|
| MacParakeet.app (idle) | ~200 MB | Swift runtime + AppKit + SwiftUI |
| Parakeet TDT (interactive slot) | ~1.5–2 GB | CoreML model + ANE working set |
| Parakeet TDT (background slot) | ~1.5–2 GB | Second `AsrManager` (ADR-016) |
| EOU 120M streaming | ~250–400 MB | Smaller model, encoder cache |
| Ollama runner (gemma4:e2b) | ~7 GB | Largest single component |
| Ollama runtime overhead | ~150–300 MB | The `ollama serve` + `ollama runner` processes |
| FluidAudio buffers + AVAudioFile | ~5–20 MB | Per-recording, bounded |
| GRDB SQLite cache | ~5–50 MB | Grows with history |
| **Total peak** | **~10.6–12.0 GB** | |

**On 16 GB:** wired memory + system processes typically eat 3–4 GB. Other apps (browser, IDE, Slack) add 2–5 GB. **Net: with default settings + Ollama gemma4:e2b, the user is in swap territory.** That's why dictation feels sluggish for some users.

**Unload opportunities when idle:**

- **STT background slot:** Used only for meeting + file transcription. If the user's primary mode is dictation, the background slot is dead weight (~1.5–2 GB). Add a runtime preference "Disable concurrent meeting recording" that skips background-slot init. (Currently `STTRuntime` always inits both slots.)
- **EOU streaming model:** Unload after 30 min of no streaming dictation. The keep-alive only keeps it warm when used recently anyway — go further and `shutdown()` on prolonged idle.
- **Ollama:** As covered in §11, let Ollama's natural eviction work.

**Memory unload trigger:** macOS posts `NSApplication.didReceiveMemoryWarningNotification` on memory pressure (also `dispatch_source_create(DISPATCH_SOURCE_TYPE_MEMORYPRESSURE)` for richer signals). Listen and proactively `await streamingDictationTranscriber.shutdown()` + cancel Ollama keep-alive.

**Impact:** High on Mac Air UX.

**Recommendations:**

1. Switch default Ollama model to gemma3:1b (saves ~5.7 GB).
2. Make the background STT slot conditional (saves ~1.5–2 GB if user doesn't use meeting recording).
3. Add memory pressure observer that unloads the streaming EOU model under pressure.

**Effort:** 30 min for #1, 1–2 hours for #2–3.

---

### 13. Dependency version freshness

Per the parallel dependency audit: all 4 packages at or near latest, 0 CVEs active against pinned versions. Only actionable item: Sparkle 2.9.0 → 2.9.1 (race-condition crash fix in `clearDownloadedUpdate`, appcast-generator robustness, no new CVEs). See the dependency audit for full per-package reports.

Highest-value upgrade candidate long term: FluidAudio. Each release tends to land:

- ANE warmup speed improvements
- Encoder cache fixes (relevant to streaming EOU stability)
- New `StreamingChunkSize` options

**Risk of FluidAudio upgrade:** API evolution. The streaming protocols are still maturing; check release notes for breaking changes to `StreamingAsrManager`, `StreamingModelVariant`, and `AsrModels.downloadAndLoad`.

---

### 14. Repeated work avoidance

**File:** `TextProcessing/AIFormatter.swift`

**`AIFormatter.normalizedPromptTemplate(_:)`** runs on every cleanup call. It does:

- `trimmingCharacters` (O(n))
- 3× equality checks against legacy templates (each O(n))

Worst case: ~4× O(template_length). Templates are ~1–2 KB. Total: ~5–10 µs per call. Called ~5–15× per dictation. **Negligible** but trivially cacheable.

The runtime preference layer already calls `AIFormatter.normalizedPromptTemplate(prompt)` in the `aiFormatterPrompt` getter (`AppRuntimePreferences.swift:84`). But that getter runs on every read — and `DictationService.cleanupTextLive` reads it on every call.

**Recommendation:** Memoize `aiFormatterPrompt` at the runtime preference layer with invalidation on `defaults.didChange` notifications, OR cache normalized result in `DictationService` per-session.

**`AIFormatter.stripThinkingDelimiters`** (`AIFormatter.swift:158-194`):

- 5 patterns × `range(of:options:.backwards)` + `countOccurrences` (which itself is a forward scan loop).
- For an output of 1–2 KB, 5 forward-scan loops + 5 backward searches = ~10 string scans per call.
- Called once per LLM response — so per cleanup call.

**Optimization:** Compile patterns to `NSRegularExpression` once. Or short-circuit on first non-zero count.

**Impact:** Low.

**Recommendation:** Lazy-cache compiled regex patterns. Skip if no `<` character in output (most outputs from non-thinking models).

**Effort:** 30 min.

---

### 15. Text refinement pipeline cache

**File:** `TextProcessing/TextRefinementService.swift` + call site at `Services/DictationService.swift:540-564`

Every dictation end:

```swift
do { words = try customWordRepo?.fetchEnabled() ?? [] }
do { snippets = try snippetRepo?.fetchEnabled() ?? [] }
```

These are GRDB queries: `CustomWord.filter(Column("isEnabled") == true).order(...).fetchAll(db)`.

**Cost:** With ~100 custom words + 50 snippets, this is sub-millisecond on local SQLite. With 1000 entries, maybe 5–10 ms. **Real cost is the 2× actor hop** (the repos hop into GRDB's queue twice).

**Cache opportunity:**

- Custom words and snippets change rarely (when user edits Vocabulary panel).
- Cache in-memory in a service that observes `dictationRepo`-style changes. Invalidate on save/delete.

**Implementation hint:** GRDB has `ValueObservation` for reactive caching:

```swift
let observation = ValueObservation.tracking { db in
    try CustomWord.filter(Column("isEnabled") == true).fetchAll(db)
}
let cancellable = observation.start(in: dbQueue, ...) { words in
    cachedWords = words
}
```

**Voice Return synthetic snippet** (line 552–558) creates a `TextSnippet` on every call — also negligible but unnecessary; pre-build it once when `voiceReturnTrigger` changes.

**Impact:** Low (sub-ms savings).

**Recommendation:** Cache only if profiler shows the GRDB hops registering. Otherwise leave it.

**Effort:** 1 hour if implemented.

---

## Prioritized Backlog

### Quick wins (<1 hour, high impact)

1. **Switch default Ollama model from gemma4:e2b → gemma3:1b for live cleanup** (§5, §12). Single config change; saves ~5.7 GB resident on the Air.
2. **Add `Task.detached { await env.sttScheduler.backgroundWarmUp() }` after `setupEnvironment`** (§10). 5-line change. First-dictation latency drops from 5–30 s to <1 s.
3. **Use `vDSP_rmsqv` for level meter in `AudioRecorder`** (§9). 5 lines. Trivially correct; reduces audio-thread cost.
4. **Bump live-cleanup debounce from 250 → 500 ms; add minimum-delta gate** (§3). 10 lines. Cuts Ollama load 3–5×.
5. **Cache baseline trim/split in `composeDisplayText`** (§2). 10 lines.
6. **Move `broadcastContinuation.yield` before `file.write` in audio tap** (§9). 1-line move. Streaming pipeline gets buffers ~50–100 µs sooner.
7. **Drop the duplicate `.animation(value: pillStateKey)`** (§4, line 404 OR 453).
8. **Throttle `runRecordingLevelLoop` from 25 → 33 ms** (§4). One-line change.

### Medium wins (1–4 hours)

9. **Replace NotificationCenter streaming-partial path with a direct AsyncStream/callback** (§1). Removes 2 hops + 1 Foundation runloop bounce per partial.
10. **Split `DictationOverlayViewModel` into shape + metrics models** (§4). Cuts SwiftUI re-eval scope ~70%.
11. **Activity-driven Ollama keep-alive (only ping if dictation in last 10 min)** (§11). Lets Ollama idle-evict overnight; reclaims 7 GB.
12. **Switch default to `.parakeetEou320ms`** (§7). Better accuracy, modest latency increase, fewer wasted cleanup calls.
13. **Cache compiled regex for `stripThinkingDelimiters`; short-circuit on no `<`** (§14).
14. **Two-config LLM split (`Cleanup Model` vs `Polish Model`)** (§5). Settings UI work + plumbing through `LLMService`.
15. **Bump Sparkle 2.9.0 → 2.9.1** (§13). Patch release; run full Sparkle smoke flow from `docs/distribution.md`.

### Long-term (4+ hours, needs planning)

16. **Memory-pressure observer that unloads streaming EOU + STT background slot under pressure** (§12).
17. **Make STT background slot opt-in (skip init if user disables meeting recording)** (§12).
18. **Async file writer for AVAudioFile so audio thread never blocks on I/O** (§9). Worth doing if profiling shows tap-thread variance.
19. **Cache `customWords` + `snippets` via GRDB `ValueObservation`** (§15). Only if profiling justifies.
20. **Evaluate MLXSwift embedded inference for cleanup** (§6). Eliminates Ollama process; saves ~150 MB. Wait for MLXSwift Gemma 3 maturity.

### Informational (measure first, don't act yet)

21. **ANE utilization verification** (§8). Run `powermetrics --samplers ane` during dictation. If `ANE Power > 0`, no action needed. If 0, redownload model via Settings.
22. **Profile actual streaming-partial latency end-to-end with Instruments** (§1). Confirm hop count predictions before refactoring.
23. **Profile SwiftUI re-eval frequency on the overlay during a 30 s dictation** (§4). Confirm the `audioLevel` 40-Hz path is the culprit before splitting view models.
24. **Profile `composeDisplayText` cost on a 5-minute dictation** (§2). The memoization is right but might never appear in profiles.

---

## Next Session Kickoff Checklist

When picking this back up:

1. **Baseline measurement first.** Run a 30-second dictation while:
   - `sudo powermetrics --samplers ane,gpu_power,cpu_power -i 1000 -n 30 > /tmp/baseline-power.txt`
   - Activity Monitor open, screenshot RAM before/during/after
   - Instruments Time Profiler running on `MacParakeet.app`
   - Note actual streaming-partial cadence (count log lines for `streaming_partial`)
2. **Pick #1 (default Ollama model)** as the warmup change. Single config edit, immediate Air-RAM benefit. Test by doing a dictation, checking `ollama ps` (model name + RAM).
3. **Pick #2 (background warmup at startup)** next. Restart the app, wait 30 s, do a dictation — should be instant.
4. **Pick #4 (debounce + min-delta)**. Test with a long dictation. Count `live_cleanup_scheduled` log lines before vs after — should drop ~3–5×.
5. **Don't refactor the NotificationCenter path until you've measured it in Instruments.** It's likely the right call but should be data-driven.
6. **Don't split `DictationOverlayViewModel` until SwiftUI Inspector confirms re-eval volume.** Cheap to keep as-is if profiles say it's fine.
7. **Save profiling artifacts** to `docs/research/perf-baseline-2026-04-14/` so the next session can A/B compare.

When in doubt: optimize the Air's RAM first (it's the binding constraint), latency second.

---

**Key file references:**

- `Sources/MacParakeetCore/Audio/AudioRecorder.swift` (audio tap, RMS, format conversion)
- `Sources/MacParakeetCore/Audio/AudioProcessor.swift` (actor wrapper)
- `Sources/MacParakeetCore/STT/StreamingEouDictationTranscriber.swift` (EOU streaming actor)
- `Sources/MacParakeetCore/STT/STTRuntime.swift` (model lifecycle, keep-alive)
- `Sources/MacParakeetCore/Services/DictationService.swift` (orchestration, partial fan-out)
- `Sources/MacParakeet/App/DictationFlowCoordinator.swift` (NC observer, composeDisplayText, scheduleLiveCleanup)
- `Sources/MacParakeet/App/AppEnvironment.swift` (DI, keep-alive task)
- `Sources/MacParakeet/App/AppStartupBootstrapper.swift` (startup)
- `Sources/MacParakeet/AppDelegate.swift` (lifecycle)
- `Sources/MacParakeet/Views/Dictation/DictationOverlayView.swift` (SwiftUI tree)
- `Sources/MacParakeet/Views/Dictation/WaveformView.swift` (40-Hz redraw)
- `Sources/MacParakeet/Views/Dictation/DictationOverlayController.swift` (ViewModel, panel)
- `Sources/MacParakeetCore/TextProcessing/AIFormatter.swift` (normalizedPromptTemplate, stripThinkingDelimiters)
- `Sources/MacParakeetCore/TextProcessing/TextRefinementService.swift` (refine pipeline)
- `Sources/MacParakeetCore/Services/LLMClient.swift` (Ollama path, num_ctx)
- `Sources/MacParakeetCore/Services/ClipboardService.swift` (paste path, 200ms intentional sleep)
- `Package.resolved` (deps to consider bumping)
