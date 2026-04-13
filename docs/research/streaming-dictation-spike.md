# Streaming Dictation Spike

> Status: **ACTIVE** — De-risk spike for streaming dictation with live floating overlay (fork only, not upstream-merged).

## Goal

Verify that FluidAudio 0.13.6's streaming ASR APIs can drive a live word-by-word dictation overlay before touching any MacParakeet code. Dictation is currently batch: record → stop → transcribe → paste. Target: record → live partial text in an overlay → paste final on stop.

Note: `spec/02-features.md` currently lists "Realtime streaming transcription" as an explicit non-feature. This spike is exploratory work on a personal fork (`jnzn/macparakeet`, branch `feature/streaming-overlay`). If the spike pans out end-to-end, we can raise the product-scope question with upstream.

## Spike Setup

- Standalone SwiftPM exec outside the MacParakeet tree: `~/dev/streaming-dictation-spike/`
- Pinned `FluidAudio 0.13.6` (matches MacParakeet's `Package.resolved`)
- Test input: 9.3s WAV generated via `say -v Samantha | afconvert -f WAVE -d LEI16@16000 -c 1` (16 kHz mono Int16, MacParakeet's native dictation format)
- Fed the file to the streaming manager in 1600-frame (100 ms) chunks with a wall-clock sleep between chunks to simulate realtime mic arrival

## API Shape (Confirmed)

```swift
let variant = StreamingModelVariant.parakeetEou160ms   // or .parakeetEou320ms / .parakeetEou1280ms
let manager = variant.createManager()                   // returns any StreamingAsrManager (actor)

try await manager.loadModels()                          // first run downloads ~28 files from HF

await manager.setPartialTranscriptCallback { partial in
    // fires on every decoder step — sub-word cadence, see "Partial Cadence" below
}

try await manager.appendAudio(buffer)                   // AVAudioPCMBuffer, any format (resampled internally)
try await manager.processBufferedAudio()                // process accumulated chunks
// ... repeat while recording ...

let finalText = try await manager.finish()              // flush + return final transcript
```

Key protocol: `StreamingAsrManager` in `FluidAudio/ASR/Parakeet/Streaming/StreamingAsrManager.swift`. The type is an `Actor`, so every call is implicitly `await` and all parameters crossing the boundary must be `Sendable` (hit this in the spike — `AVAudioPCMBuffer` must be freshly allocated per chunk to avoid `SendingRisksDataRace`).

## Observed Behavior

| Aspect | Result |
|--------|--------|
| Model load (cold) | ~70s, 28 files downloaded to `~/Library/Application Support/FluidAudio/Models/parakeet-eou-streaming/160ms/` |
| Model load (warm) | ~1.8s (just CoreML load) |
| Realtime factor | 9.32s audio transcribed in 9.32s wall time (lockstep with ingestion; streaming is synchronous w.r.t. audio arrival) |
| Partial callback cadence | 10-50 ms between partials, sub-word granularity |
| Final transcript WER on synthesized speech | ~5% (minor errors: "wood" → "would", dropped leading "The"). Expected better on real mic input. |
| EOU detection | Fires automatically; log shows `EOU candidate at chunk N, starting debounce timer` — usable as "user stopped talking" signal for hands-free auto-stop dictation mode |
| Memory | Not measured yet — worth profiling in Session 2 |

## Partial Cadence (important for UI)

Raw partial stream is **sub-word**. Representative sample:

```
[partial] quick
[partial] quick brown
[partial] quick brown fox
[partial] quick brown fox jum
[partial] quick brown fox jumps
[partial] quick brown fox jumps over
[partial] quick brown fox jumps over the
[partial] quick brown fox jumps over the laz
[partial] quick brown fox jumps over the lazy
[partial] quick brown fox jumps over the lazy dog
[partial] quick brown fox jumps over the lazy dog stream
[partial] quick brown fox jumps over the lazy dog streaming
[partial] quick brown fox jumps over the lazy dog streaming dict
...
```

The overlay should **not** render every callback directly — it'll jitter. Options:
1. Debounce by time (e.g., coalesce partials inside a 50 ms window, present latest).
2. Filter to word-boundary changes only (only render when the trailing token is whitespace-terminated).
3. Always render, but animate the tail characters subtly so in-progress words read as "still forming."

Option 2 is simplest and likely feels best — sub-word fragments are visual noise.

## Model Variant Choice

Three Parakeet EOU chunk sizes available:

| Variant | Latency | Use Case |
|---------|---------|----------|
| `.parakeetEou160ms` | lowest (~160ms output cadence) | Dictation (chosen) |
| `.parakeetEou320ms` | balanced | — |
| `.parakeetEou1280ms` | highest throughput, worse latency | Unsuitable for live overlay |

For dictation UX, 160ms is the right default. All three share the same 120M EOU model architecture; they're separately-exported CoreML encoders with different chunk configs.

## Risks & Open Questions for Session 2

1. **Two models loaded simultaneously?** Current MacParakeet loads Parakeet TDT 0.6B-v3 into an `AsrManager` slot. Streaming EOU is a separate 120M model in a separate actor. Memory impact: ~66 MB for TDT + unknown for EOU streaming manager — needs measurement. ADR-016's two-slot scheduler is sized for TDT only.

2. **Slot model violation?** ADR-016 defines a reserved dictation slot and a shared background slot, both holding `AsrManager` instances. A streaming EOU manager doesn't fit that abstraction — it's a different actor type conforming to `StreamingAsrManager`. Question: do we replace the dictation slot's manager when streaming mode is enabled, or add a third slot, or bypass the scheduler for streaming dictation entirely? Leaning toward "bypass" — the scheduler exists to arbitrate batch jobs, and streaming is a single long-running session owned by the dictation flow.

3. **Dictation history record** currently takes a final `STTResult` with word timings. `finish()` returns only `String`. Need to decide whether streaming dictation sacrifices per-word timestamps in history, or whether we run a batch TDT pass on the saved WAV post-stop to populate timings (two-stage: live EOU partials for overlay UX, TDT-on-final for accurate history).

4. **Accuracy vs TDT.** EOU 120M is smaller and streaming-optimized. TDT 0.6B is more accurate. Question: is EOU accurate enough for Jensen's actual dictation to be acceptable as the *pasted* text, or does the pasted text need to come from a post-stop TDT pass? Hybrid approach is safest: EOU for overlay, TDT for paste.

5. **Audio plumbing.** `AudioRecorder` currently writes to a temp WAV during recording. Streaming needs a parallel tap that emits `AVAudioPCMBuffer`s to the EOU manager. The existing `AudioProcessorProtocol` doesn't expose a stream. Session 2 should add a streaming variant method or a parallel protocol.

6. **Partial text debouncing logic** lives where? Core or ViewModel? Leaning toward Core (pure-function debouncer on the partial stream) so ViewModels stay thin and testable.

## Decision: Green Light on Approach

The API works, latency is acceptable, partials are usable once debounced. Session 2 can proceed to wiring this into MacParakeet with the hybrid approach (EOU for live overlay, TDT for final paste/history) as the leading hypothesis.

## Spike Artifacts

- `~/dev/streaming-dictation-spike/` — throwaway SwiftPM exec; retain until Session 2 is complete, then delete
- Test audio: `~/dev/streaming-dictation-spike/test.wav` (generated, gitignored)

## References

- [FluidAudio 0.13.6 `StreamingAsrManager` protocol](https://github.com/FluidInference/FluidAudio/blob/v0.13.6/Sources/FluidAudio/ASR/Parakeet/Streaming/StreamingAsrManager.swift)
- [Parakeet EOU 120M on HuggingFace](https://huggingface.co/FluidInference/parakeet-realtime-eou-120m-coreml)
- `spec/02-features.md:1676` (current non-feature entry — revisit when/if we propose upstream)
- `spec/adr/016-centralized-stt-runtime-scheduler.md` (slot model to reconcile with streaming manager)
