---
title: Meeting Recording Dual-Stream Transcription Pipeline
status: ACTIVE
date: 2026-04-12
authors: Codex/GPT, Daniel Moon
---

# Meeting Recording Dual-Stream Transcription Pipeline

> Status: **ACTIVE** - current implementation and design notes
> Related spec: `spec/05-audio-pipeline.md`, `spec/06-stt-engine.md`
> Related ADRs: `spec/adr/014-meeting-recording.md`, `spec/adr/015-concurrent-dictation-meeting.md`, `spec/adr/016-centralized-stt-runtime-scheduler.md`

## TL;DR

MacParakeet meeting recording is a **dual-stream capture pipeline**:

- **microphone** audio is captured separately
- **system** audio is captured separately
- both streams feed the **live transcript**
- both streams are written to disk as separate files
- after stop, the two source files are mixed into `meeting.m4a`
- the final post-stop STT pass transcribes `meeting.m4a`

The part that is easy to misunderstand:

- `meeting.m4a` is usually **stereo** (`L=mic`, `R=system`)
- but the current final STT pipeline converts it to **16 kHz mono WAV** before Parakeet sees it
- so the saved stereo artifact is **not** currently used as stereo by Parakeet / FluidAudio

The live transcript still matters after stop because it can contribute **speaker/source structure** through `preparedTranscript`, even though the final text comes from a fresh batch STT pass.

That is the **current** implementation, not the recommended long-term design. The recommended redesign is documented below.

## Why this doc exists

There are several similar-but-not-identical concepts in the meeting pipeline:

- raw capture streams
- live chunk transcription
- persisted source files
- mixed playback artifact
- final post-stop transcription
- prepared transcript metadata
- diarization fallback

These are easy to collapse mentally into "the app records one file and transcribes it," which is not what the current implementation does.

This note documents the current architecture as shipped after the VPIO rollback work and the follow-up investigation into Parakeet / FluidAudio channel handling.

## End-to-end flow

```text
Meeting starts
    │
    ├── MicrophoneCapture
    │     └── raw mic buffers
    │
    ├── SystemAudioTap
    │     └── system audio buffers
    │
    └── MeetingAudioCaptureService
          └── AsyncStream<MeetingAudioCaptureEvent>
                    │
                    ▼
             MeetingRecordingService
                    │
                    ├── write source files
                    │     ├── microphone.m4a
                    │     └── system.m4a
                    │
                    ├── resample + join + chunk
                    │     └── CaptureOrchestrator
                    │
                    ├── mic cleanup
                    │     ├── SoftwareAECConditioner (default)
                    │     └── live mic suppression when system dominates
                    │
                    └── LiveChunkTranscriber
                          └── MeetingTranscriptAssembler
                                └── live transcript UI

Meeting stops
    │
    ├── finalize source files
    ├── mix microphone.m4a + system.m4a -> meeting.m4a
    ├── finalize live transcript -> preparedTranscript? (optional)
    └── TranscriptionService.transcribeMeeting(recording:)
          ├── convert meeting.m4a -> 16 kHz mono WAV
          ├── batch STT on mono WAV
          ├── if preparedTranscript exists:
          │     merge fresh STT words with prepared speaker/source segments
          └── else:
                use diarization fallback if enabled
```

## Capture model

Meeting recording captures **two logical sources**:

1. `AudioSource.microphone`
2. `AudioSource.system`

Relevant code:

- `MeetingAudioCaptureService`
- `MicrophoneCapture`
- `SystemAudioTap`
- `MeetingRecordingService.handleCaptureEvent(...)`

The streams are not merged at capture time. They stay distinct long enough to support:

- separate recording artifacts
- source-aware live transcription
- microphone conditioning against the system reference

## Stored artifacts

Each meeting session produces a folder containing:

```text
meeting-recordings/<uuid>/
├── microphone.m4a
├── system.m4a
└── meeting.m4a
```

Semantics:

- `microphone.m4a`: mic-only source recording
- `system.m4a`: system-only source recording
- `meeting.m4a`: final mixed playback/transcription artifact

`MeetingRecordingOutput` carries all three URLs plus optional `preparedTranscript`.

Relevant code:

- `Sources/MacParakeetCore/Services/MeetingRecordingOutput.swift`
- `Sources/MacParakeetCore/Services/MeetingRecordingService.swift`

## What `meeting.m4a` actually is

For the normal two-source meeting case, `meeting.m4a` is **stereo**:

- left channel = microphone
- right channel = system audio

Relevant code:

- `AudioFileConverter.mixToM4A(...)`
- `AudioFileConverter.ffmpegMixArguments(...)`

The FFmpeg graph explicitly pans mic to the left channel and system to the right channel before mixing them into a 2-channel AAC output.

For single-input fallback sessions, the output remains mono.

## Live transcription path

During recording, both streams feed the live transcript pipeline.

### Source handling

`MeetingRecordingService.handleCaptureEvent(...)`:

- writes the raw buffer to the per-source file
- extracts / resamples samples for orchestration
- routes mic and system to `CaptureOrchestrator`

`CaptureOrchestrator`:

- joins mic/system samples by host time
- applies the mic conditioner using system audio as reference
- chunks mic and system independently for live STT

Relevant code:

- `Sources/MacParakeetCore/Services/CaptureOrchestrator.swift`

### Microphone cleanup in the live path

The shipped default is:

- `SoftwareAECConditioner` for mic cleanup
- plus transcript-layer suppression when system audio strongly dominates recent processed mic energy

Relevant code:

- `MeetingRecordingService.configureMicConditioner(...)`
- `MeetingRecordingService.shouldSuppressMicrophoneChunkTranscription()`

Important nuance:

- suppressed mic chunks are skipped for **live transcription**
- the mic audio is still recorded to disk
- the mic audio is still included in the final mixed artifact

So this suppression is a transcript-quality safeguard, not destructive audio editing.

### Transcript assembly

`MeetingTranscriptAssembler` builds a source-aware live transcript:

- each live word gets `speakerId = source.rawValue`
- active speakers become `Me` / `Them`
- diarization-style segments are built from the ordered words

`MeetingRealtimeTranscript` contains:

- `rawTranscript`
- `words`
- `speakerCount`
- `speakers`
- `diarizationSegments`
- `durationMs`

Relevant code:

- `Sources/MacParakeetCore/Services/MeetingTranscriptAssembler.swift`

## What `preparedTranscript` is

When recording stops, `MeetingRecordingService.stopRecording()` may attach a finalized live transcript to `MeetingRecordingOutput.preparedTranscript`.

It becomes `nil` if:

- live chunk transcription failed
- or pending live chunk work could not be drained cleanly before stop

Relevant code:

- `MeetingRecordingService.stopRecording()`
- `MeetingRecordingService.handleLiveChunkTranscriberEvent(...)`

`preparedTranscript` is therefore:

- **optional**
- built from the live dual-stream pipeline
- not assumed to be authoritative text

## Post-stop final transcription path

After stop, `TranscriptionService.transcribeMeeting(recording:)` performs a fresh STT pass on `meeting.m4a`.

This pass is the authoritative source for the final raw text.

Relevant code:

- `TranscriptionService.transcribeMeeting(recording:)`
- `TranscriptionService.transcribeAudio(...)`

## The most important constraint: Parakeet / FluidAudio are mono here

Current MacParakeet final STT does **not** preserve stereo into Parakeet.

### App-level conversion

Before STT, MacParakeet converts the input file to:

- WAV
- `16 kHz`
- `mono`
- `Float32 PCM`

Relevant code:

- `AudioFileConverter.convert(fileURL:)`
- `AudioFileConverter.ffmpegArguments(...)`

This includes:

- `-ar 16000`
- `-ac 1`
- `-f wav`
- `-acodec pcm_f32le`

So even if `meeting.m4a` is stereo on disk, the final STT input becomes mono.

### FluidAudio handling

The pinned `FluidAudio` dependency in this repo (`0.13.6`, revision `57551cd9`) is explicit:

- `AudioConverter` target format is `16 kHz, mono, Float32`
- stereo buffers are mixed to mono via `AVAudioConverter`
- `>2` channels are manually averaged to mono before resampling
- file, buffer, sample-buffer, and disk-backed paths all normalize to mono before ASR

Relevant local dependency source:

- `.build/checkouts/FluidAudio/Sources/FluidAudio/Shared/AudioConverter.swift`
- `.build/checkouts/FluidAudio/Sources/FluidAudio/ASR/Parakeet/AsrManager.swift`
- `.build/checkouts/FluidAudio/Sources/FluidAudio/Shared/AudioSourceFactory.swift`

### Parakeet model expectation

The NVIDIA model card for `nvidia/parakeet-tdt-0.6b-v3` defines the input as:

- `16 kHz`
- `1D (audio signal)`
- `Monochannel audio`

So this is not just a MacParakeet convenience choice. The current Parakeet TDT path is fundamentally single-channel.

## What `source: .microphone` / `.system` does not mean

In FluidAudio, `AudioSource` is a small enum:

- `.microphone`
- `.system`

In the Parakeet manager, that source selects **decoder state**, not channel extraction.

It does **not** mean:

- "transcribe left channel"
- "transcribe right channel"
- "preserve channel separation inside the model"

It means:

- "treat this as a separate logical transcription stream with separate decoder state"

That is useful for MacParakeet's live dual-stream architecture, but it is not a stereo-aware final batch-transcription API.

## Why `preparedTranscript` still has value after stop

It is fair to ask why the app uses live metadata at all if a fresh post-stop STT pass is expected to be more accurate.

The answer is:

- the final batch pass is trusted for **text**
- the live dual-stream pass can still be useful for **structure**

Specifically, `TranscriptionService` does this for meetings:

1. transcribe `meeting.m4a` again to get fresh words/timestamps
2. if `preparedTranscript` exists:
   - convert its `diarizationSegments` into speaker segments
   - merge the fresh batch words onto those speaker/source segments
3. otherwise:
   - fall back to diarization when enabled

Relevant code:

- `TranscriptionService.transcribeAudio(...)`
- `SpeakerMerger.mergeWordTimestampsWithSpeakers(...)`

So the intent is not:

- "trust the live transcript text over the final transcript"

It is:

- "use final STT text, but preserve source/speaker structure from the live dual-stream path when it is available and complete"

## Tradeoff in the current design

The current hybrid design exists because the final batch pass does **not** exploit the stereo artifact structurally.

That means:

- live transcript metadata can improve attribution
- but bad live metadata can also make attribution worse than a clean fallback

Current gating is coarse:

- if live chunk transcription failed or did not drain, `preparedTranscript` is discarded
- otherwise it is used

What is not currently done:

- deep quality scoring of `preparedTranscript`
- comparison of prepared metadata quality vs diarization quality
- channel-aware final STT directly from stereo `meeting.m4a`

## Recommended redesign

The strongest next architecture is:

1. keep the live transcript as **live transcript only**
2. do **not** feed live transcript metadata into finalization
3. after stop, run a fresh batch STT pass on:
   - `microphone.m4a`
   - `system.m4a`
4. merge those two fresh results by timestamp while preserving source identity
5. keep diarization optional and additive, not the primary replacement for source structure

Why this is cleaner:

- it removes `preparedTranscript` from the final correctness path
- it keeps final text fully batch-derived
- it preserves the value of dual-stream capture instead of collapsing it prematurely
- it avoids trusting lower-quality live metadata during finalization
- it uses the strongest artifacts the app already has: the per-source recordings

This is a better design than either of these alternatives:

### Worse alternative 1: keep `preparedTranscript`

This keeps a lower-trust live artifact in the finalization path. Even if the final text comes from the batch pass, the structural merge still depends on metadata gathered under live chunking, backpressure, suppression, and scheduler best-effort behavior.

### Worse alternative 2: transcribe only `meeting.m4a` and rely on diarization

This throws away source separation before final STT and asks diarization to reconstruct structure from a weaker artifact. Diarization is useful, but it is not a replacement for having true per-source recordings.

## Is the separate post-stop merge tractable?

Yes. This is a straightforward engineering problem compared with diarization or channel-aware one-pass ASR.

The merge is conceptually:

1. transcribe `microphone.m4a`
2. transcribe `system.m4a`
3. normalize both transcripts to a shared time origin
4. merge-sort words or segments by time
5. preserve source identity on the merged output
6. optionally build diarization/source segments from contiguous same-source runs

This is not "free," but it is a solved class of problem.

The real implementation details to watch are:

- start-offset alignment between the two recorded files
- drift/skew over long meetings
- duplicate semantic content if mic bleed still survives conditioning
- choosing segment-level merge vs naive word-level interleave for readability

These are engineering details, not research unknowns.

## What is true today vs common assumptions

### True

- meeting capture is dual-stream
- both streams feed live STT
- source files are persisted separately
- `meeting.m4a` is stereo in the normal two-source case
- final post-stop STT is a fresh pass, not just "save the live transcript"
- `preparedTranscript` is optional metadata, not the final raw text
- Parakeet / FluidAudio are currently used as mono ASR in this app

### False

- "`meeting.m4a` stays stereo all the way into Parakeet"
- "`source: .system` means FluidAudio transcribes the system channel only"
- "the final transcript is just the live transcript written to disk"
- "MacParakeet currently has true channel-aware final transcription"

## Architectural implications

If the product goal is:

- best possible post-stop attribution from the dual-stream artifact

then the current mono-collapse finalization path is not the ideal end state.

The cleanest future options are:

1. **Transcribe mic and system source files separately post-stop**
   - probably the cleanest path with the current model/runtime

2. **Split `meeting.m4a` channels post-stop and transcribe each channel independently**
   - functionally similar, slightly less direct than using the original source files

3. **Adopt a truly channel-aware backend for final transcription**
   - only if the team wants one-pass multichannel ASR later

In all three cases, the live transcript could become:

- UI-first
- advisory
- or optional for finalization

instead of carrying structural responsibility because the final batch path collapsed the channels.

## Recommended interpretation for future work

For the current codebase, the right mental model is:

- **capture** is dual-stream
- **live transcription** is dual-stream and source-aware
- **storage** preserves both source files and a stereo mixed artifact
- **final Parakeet STT** is mono
- **preparedTranscript** is a transitional implementation detail, not the desired end state

Any future redesign should keep those layers distinct, avoid language that implies the final batch pass is already channel-aware, and prefer fresh post-stop per-source transcription over live-metadata reuse.

## Primary evidence used for this note

### MacParakeet

- `Sources/MacParakeetCore/Services/MeetingRecordingService.swift`
- `Sources/MacParakeetCore/Services/MeetingRecordingOutput.swift`
- `Sources/MacParakeetCore/Services/MeetingTranscriptAssembler.swift`
- `Sources/MacParakeetCore/Services/TranscriptionService.swift`
- `Sources/MacParakeetCore/Services/CaptureOrchestrator.swift`
- `Sources/MacParakeetCore/Audio/AudioFileConverter.swift`

### FluidAudio

- `.build/checkouts/FluidAudio/Sources/FluidAudio/Shared/AudioConverter.swift`
- `.build/checkouts/FluidAudio/Sources/FluidAudio/ASR/Parakeet/AsrManager.swift`
- `.build/checkouts/FluidAudio/Sources/FluidAudio/Shared/AudioSourceFactory.swift`
- `.build/checkouts/FluidAudio/Documentation/ASR/GettingStarted.md`
- `.build/checkouts/FluidAudio/Documentation/Guides/AudioConversion.md`

### NVIDIA / Parakeet

- `https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3`
