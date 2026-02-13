# FluidAudio CoreML Migration: STT Backend Evaluation

> Status: **ACTIVE** — Research findings, February 12, 2026

## Problem Statement

MacParakeet runs Parakeet TDT 0.6B via a **Python daemon** (`parakeet-mlx`) using JSON-RPC over stdin/stdout. This works, but it's not the best architecture for the product we're building.

### The Core Problem: Wasted Silicon

Every Apple Silicon Mac has **three distinct compute units** on the same die:

```
Apple Silicon (M1/M2/M3/M4)
├── CPU — General purpose (app logic, UI, I/O)
├── GPU — Parallel compute, graphics (Metal)
└── ANE — Neural Engine (dedicated ML inference accelerator)
```

These are **physically separate silicon** with their own processing pipelines. They can run simultaneously without contending for resources.

Today, MacParakeet uses **two of three chips**:

```
CPU: [App logic, UI, hotkeys, clipboard]
GPU: [Parakeet STT] + [Qwen3-4B LLM]   ← two ML workloads sharing one chip
ANE: [idle]                               ← dedicated ML chip sitting unused
```

Both Parakeet (STT) and Qwen3-4B (LLM) run on the GPU via Metal/MLX. They share the GPU memory pool. On 8GB Macs (base M1/M2/M3/M4), this creates real memory pressure — the Qwen3-4B model alone occupies ~2.5-4GB.

**The ANE exists specifically for neural network inference, and we're not using it.**

### Secondary Issues

- **Unnecessary complexity**: JSON-RPC over stdin/stdout, subprocess management, daemon health checks, cross-process error propagation — all to bridge Swift and Python. Native Swift would be a single async/await call.
- **Extra runtime**: Python + uv + venv + FFmpeg are dependencies that exist solely because of the STT backend. Every one is a potential failure point (macOS updates can break venvs, every `.so`/`.dylib` needs codesigning).
- **App Store incompatible**: Sandboxing prohibits spawning arbitrary subprocesses. This permanently closes a distribution channel.

## Discovery: FluidAudio

[FluidAudio](https://github.com/FluidInference/FluidAudio) is a Swift SDK by FluidInference that runs Parakeet TDT on Apple's **Neural Engine (ANE) via CoreML** — no Python, no GPU, no subprocess.

- **1,455 GitHub stars**, Apache 2.0 license
- **v0.12.1** released February 12, 2026 (extremely active development)
- **20+ production apps** ship with it, including VoiceInk (direct competitor)
- Built by FluidInference — small independent team, not affiliated with NVIDIA or Apple
- Business model: open source SDK, paid custom model training/optimization for enterprises

### What It Includes

| Capability | Model | Details |
|-----------|-------|---------|
| ASR (batch) | Parakeet TDT v2 (English) | 2.1% WER, ~155x RTF on M4 Pro |
| ASR (batch) | Parakeet TDT v3 (multilingual) | 2.5% WER, ~155x RTF, 25 European languages |
| ASR (streaming) | Parakeet EOU 120M | Real-time with end-of-utterance detection, 1.3s min latency |
| Diarization | Pyannote + WeSpeaker (offline), Sortformer (real-time) | 15% DER |
| VAD | Silero | 96% accuracy, 1220x RTF |
| TTS | PocketTTS | Apache 2.0 (GPL-free) |
| Custom vocabulary | CTC/TDT keyword boosting | 99.3% recall |

### API Surface

Transcription in 5 lines of native Swift:

```swift
import FluidAudio

let models = try await AsrModels.downloadAndLoad(version: .v2)
let manager = AsrManager(config: .default)
try await manager.initialize(models: models)

let result = try await manager.transcribe(samples, source: .system)
print(result.text)
```

Async/await native. No FFmpeg (uses AVAudioConverter). No subprocess. No JSON-RPC.

## Target Architecture: Three Workloads, Three Chips

With FluidAudio CoreML, each ML workload runs on the chip it was designed for:

```
CPU: [App logic, UI, hotkeys, clipboard]
GPU: [Qwen3-4B LLM]                      ← full GPU dedicated to text refinement
ANE: [Parakeet STT]                       ← dedicated ML chip, finally used
```

The dictation-to-refinement pipeline becomes:

```
Audio → [Parakeet on ANE] → raw text → [Qwen3-4B on GPU] → refined text
```

**What this means in practice:**

- **Zero compute contention** — ANE and GPU are separate silicon running simultaneously. STT never competes with the LLM for processing cycles.
- **~1-1.5GB memory savings** — Parakeet uses ~800MB on ANE via CoreML vs ~2GB+ on GPU via MLX. On 8GB Macs, that's significant (see memory analysis below).
- **Lower power** — The ANE is purpose-built for inference and is significantly more power-efficient than running the same workload on the GPU.
- **Scales with features** — As we add command mode, more AI refinement modes, and heavier Qwen3-4B usage, the GPU isn't also carrying STT. This separation becomes more valuable over time, not less.

### Unified Memory: The Shared Bottleneck

Apple Silicon's three compute units are separate processors, but they **share the same unified memory pool**. There's no dedicated VRAM — everything draws from one budget:

```
Apple Silicon (e.g., 8GB Mac)
├── CPU  ──┐
├── GPU  ──┼── All share 8GB unified memory
└── ANE  ──┘
```

This means moving STT to the ANE doesn't magically create new memory — but it does use **less** of the shared pool:

| Component | Current (Python/MLX) | With FluidAudio CoreML |
|-----------|---------------------|----------------------|
| Parakeet STT | ~2GB+ (GPU/MLX) | ~800MB (ANE/CoreML) |
| Qwen3-4B LLM (4-bit) | ~2.5-4GB (GPU) | ~2.5-4GB (GPU) |
| App + macOS overhead | ~2-3GB | ~2-3GB |
| **Total** | **~6.5-9GB** | **~5.3-8GB** |
| **Headroom on 8GB Mac** | **-0.5 to 1.5GB** | **0 to 2.7GB** |

That ~1-1.5GB savings from the more efficient CoreML/ANE path is the difference between "barely fits" and "runs comfortably" on base model Macs. Every gigabyte matters when you're running two ML models on an 8GB machine — that's the majority of Apple Silicon MacBooks in the wild.

On 16GB+ Macs the memory pressure is gone either way, but supporting the 8GB base well is important for reach.

## Technical Comparison

| Dimension | Current (Python/MLX) | FluidAudio (CoreML/ANE) |
|-----------|---------------------|------------------------|
| **Language** | Python subprocess | Native Swift |
| **Runs on** | GPU (Metal) | ANE (Neural Engine) |
| **RTF** | ~300x | ~155x |
| **1 min dictation** | ~0.2s | ~0.4s |
| **1 hour file** | ~12s | ~23s |
| **WER** | 2.1% (same model) | 2.1% (same model) |
| **Peak memory** | Higher (GPU pool) | ~800MB |
| **GPU contention with Qwen3** | Yes | No |
| **First-run setup** | Minutes (venv + deps) | Seconds (CoreML compile) |
| **Dependencies** | Python + uv + venv + FFmpeg | SwiftPM only |
| **Signing** | Dozens of .so/.dylib files | One Swift framework |
| **App Store** | Blocked | Compatible |
| **Crash isolation** | Good (separate process) | Worse (in-process) |
| **Diarization** | Not included | Built-in |
| **VAD** | Not included | Built-in |
| **Streaming ASR** | Not available | Available (EOU model) |
| **Custom vocabulary** | Not included | Built-in (v0.11.0+) |

### Speed Difference in Practice

The 300x vs 155x sounds like "twice as fast" but in absolute terms:

| Audio length | MLX/GPU | CoreML/ANE | Perceptible? |
|-------------|---------|-----------|-------------|
| 5 seconds | 0.02s | 0.03s | No |
| 30 seconds | 0.1s | 0.2s | No |
| 1 minute | 0.2s | 0.4s | No |
| 5 minutes | 1.0s | 1.9s | Barely |
| 1 hour | 12s | 23s | Yes, but both very fast |

For dictation (the primary use case), the difference is imperceptible. For long file transcription, CoreML/ANE is still remarkably fast — 23 seconds for an hour of audio.

## Licensing

All components we'd use are permissive:

| Component | License |
|-----------|---------|
| FluidAudio SDK | Apache 2.0 |
| Parakeet TDT v2/v3 CoreML models | CC-BY-4.0 |
| Parakeet EOU 120M | nvidia-open-model-license |
| Silero VAD | MIT |
| Diarization models | MIT / Apache 2.0 |

**GPL trap to avoid:** FluidAudio ships two SwiftPM products. `FluidAudio` (core) is all Apache/MIT. `FluidAudioTTS` adds Kokoro TTS which pulls in ESpeakNG (GPL-3.0). We only need the core product — no GPL contamination.

## Risk Assessment

### Risks of adopting FluidAudio

| Risk | Severity | Mitigation |
|------|----------|------------|
| FluidInference goes away | Medium | SDK is Apache 2.0 (forkable), CoreML models are on HuggingFace independently |
| Breaking API changes | Low | Pin to specific version, SDK has semver from v0.7.9+ |
| CoreML crash takes down app | Low | CoreML is mature; can wrap in crash handler. Trade-off vs subprocess complexity. |
| CoreML first-run compilation | Low | 3-15 seconds one-time, can show progress indicator during onboarding |
| Model download on first run | Medium | Pre-bundle in app, or download during onboarding (2.67 GB) |
| Streaming ASR quality worse than batch | Low | Use batch mode for dictation (process after recording stops), streaming only for real-time feedback if added later |

### Risks of staying on Python/MLX

| Risk | Severity | Mitigation |
|------|----------|------------|
| GPU contention with Qwen3 | High | Sequential processing works, but wastes silicon — ANE sits idle while two workloads share GPU |
| App Store blocked | High | No mitigation possible with Python subprocess |
| macOS update breaks venv | Medium | Defensive checks, auto-rebuild, but adds complexity |
| Distribution/signing complexity | Medium | Automation scripts, but ongoing maintenance burden |
| First-run venv setup | Low | One-time cost, acceptable |

## Recommendation

**Migrate from parakeet-mlx (Python) to FluidAudio CoreML (Swift).**

The CoreML/ANE path is the better architecture — three workloads on three chips instead of two workloads fighting over one, native Swift throughout, fewer moving parts. Use the silicon Apple put in the machine.

### Why v0.4, not now

- v0.2 (AI text refinement) and v0.3 (command mode) are in progress on the current stack
- The Python daemon works — 360 tests passing, proven architecture
- Rewriting STT infrastructure mid-feature is unnecessary risk
- v0.4 is the natural point to clean up the foundation before adding more features on top

### Migration scope

1. **Add FluidAudio as SwiftPM dependency** (`FluidAudio` product only, not `FluidAudioTTS`)
2. **Replace `STTClient` implementation** — swap JSON-RPC Python calls for FluidAudio's async Swift API
3. **Remove Python daemon** — delete `python/macparakeet_stt/`, remove uv bootstrap, remove JSON-RPC protocol
4. **Remove FFmpeg dependency** — FluidAudio uses AVAudioConverter internally
5. **Update `STTClient` protocol tests** — new implementation, same interface contract
6. **Decide on model distribution** — bundle in app (larger download, instant first-run) vs. download on first use (smaller app, onboarding delay)
7. **Evaluate bonus features** — diarization (v0.4 roadmap item), VAD, custom vocabulary boosting

### What doesn't change

- `STTClient` protocol interface — consumers don't know or care about the backend
- Qwen3-4B via MLX-Swift — the LLM path stays the same
- All existing tests against the STT protocol — same contract, new implementation
- Deterministic text processing pipeline — unchanged
- UI, hotkeys, history, export — all unchanged

### Additional opportunity: Qwen3-4B-Instruct-2507

While migrating the STT backend, also upgrade the LLM from `Qwen3-4B` to `Qwen3-4B-Instruct-2507`. The July 2025 update ranked #1 among all small language models for instruction following — directly relevant for our text refinement and command mode use cases. This is a model ID change, not an architecture change.

## Related Documents

- [Open Source Models Landscape (Feb 2026)](./open-source-models-landscape-2026.md) — full STT/LLM/MLX ecosystem research
- [ADR-001: Parakeet TDT as Primary STT](../spec/adr/001-parakeet-stt.md) — original STT decision (model choice unchanged, runtime changes)
- [Distribution & Signing](./distribution.md) — current distribution approach (will simplify after migration)

## Sources

- [FluidAudio GitHub](https://github.com/FluidInference/FluidAudio)
- [FluidAudio API Documentation](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/API.md)
- [FluidAudio Benchmarks](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md)
- [Parakeet TDT v2 CoreML (HuggingFace)](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml)
- [Parakeet TDT v3 CoreML (HuggingFace)](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml)
- [VoiceInk GitHub](https://github.com/Beingpax/VoiceInk) — production app using FluidAudio
- [mlx-swift-lm GitHub](https://github.com/ml-explore/mlx-swift-lm) — Qwen3 LLM runtime (unchanged)
- [Qwen3-4B-Instruct-2507 (HuggingFace)](https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507) — recommended LLM upgrade
