# Speaker Diarization Implementation Plan

> Status: **ACTIVE**

## Overview

Add speaker diarization to file transcription and YouTube transcription using FluidAudio's offline diarization pipeline (pyannote community-1 + WeSpeaker v2 + VBx clustering). See ADR-010 for the full decision record.

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Pipeline | FluidAudio offline (OfflineDiarizerManager) | Best accuracy (~15% DER), unlimited speakers, already in our dependency |
| Scope | File + YouTube transcription only | Dictation is single-speaker |
| Speaker data storage | `speakerId` on `WordTimestamp`, `speakerCount`/`speakers` on `Transcription` | Minimal schema change, JSON-encoded, backward compatible |
| Always-on | Yes for file transcription | Users transcribing files almost always want speaker attribution |
| Cross-file identity | Not supported | Per-transcription speaker IDs only |
| ASR + diarization ordering | Sequential (ASR first, then diarization) | Simpler, correctness over speed. Optimize to parallel later if needed. |

## Implementation Steps

### Phase 1: Core Pipeline

#### 1.1 Add `speakerId` to `WordTimestamp`

**File:** `Sources/MacParakeetCore/Models/Transcription.swift`

Add `speakerId: String?` to `WordTimestamp`. Nullable for backward compatibility — existing transcriptions without diarization remain valid.

```swift
public struct WordTimestamp: Codable, Sendable {
    public var word: String
    public var startMs: Int
    public var endMs: Int
    public var confidence: Double
    public var speakerId: String?  // v0.4 diarization
}
```

No database migration needed — `wordTimestamps` is a JSON text column. The new field is nullable and Codable handles it automatically (missing key = nil).

#### 1.2 Create DiarizationService

**File:** `Sources/MacParakeetCore/Services/DiarizationService.swift`

New service that wraps FluidAudio's `OfflineDiarizerManager`:

```swift
protocol DiarizationServiceProtocol: Sendable {
    func diarize(audioURL: URL) async throws -> DiarizationResult
    func prepareModels(onProgress: (@Sendable (String) -> Void)?) async throws
    func isReady() async -> Bool
}
```

**DiarizationResult** (our domain type, not FluidAudio's):

```swift
struct SpeakerSegment: Sendable {
    let speakerId: String       // "Speaker 1", "Speaker 2", etc.
    let startMs: Int
    let endMs: Int
}

struct DiarizationResult: Sendable {
    let segments: [SpeakerSegment]
    let speakerCount: Int
    let speakerIds: [String]    // Ordered list: ["Speaker 1", "Speaker 2"]
}
```

Implementation:
- Lazy-init `OfflineDiarizerManager` on first call
- Map FluidAudio's `TimedSpeakerSegment` → our `SpeakerSegment` with human-readable labels
- Convert FluidAudio's offline pipeline IDs (`"S1"`, `"S2"`, ...) to display labels (`"Speaker 1"`, `"Speaker 2"`, ...)
- Convert `startTimeSeconds`/`endTimeSeconds` (Float, seconds) to `startMs`/`endMs` (Int, milliseconds) to match `WordTimestamp` format

#### 1.3 Create timestamp merger

**File:** `Sources/MacParakeetCore/Services/SpeakerMerger.swift`

Pure function that merges ASR word timestamps with diarization speaker segments:

```swift
func mergeWordTimestampsWithSpeakers(
    words: [WordTimestamp],
    segments: [SpeakerSegment]
) -> [WordTimestamp]
```

Algorithm:
- For each word, find the diarization segment with the most time overlap
- Assign that segment's `speakerId` to the word
- Words with no overlapping segment get `speakerId = nil`

This is a pure function — easy to test with fixture data.

#### 1.4 Integrate into TranscriptionService

**File:** `Sources/MacParakeetCore/Services/TranscriptionService.swift`

After ASR completes, run diarization and merge:

```swift
// Existing: ASR
let sttResult = try await sttClient.transcribe(audioPath: path)

// New: Diarization
let diarizationResult = try await diarizationService.diarize(audioURL: url)

// New: Merge
let mergedWords = SpeakerMerger.mergeWordTimestampsWithSpeakers(
    words: sttResult.words,
    segments: diarizationResult.segments
)

// Update transcription record
transcription.wordTimestamps = mergedWords
transcription.speakerCount = diarizationResult.speakerCount
transcription.speakers = diarizationResult.speakerIds
```

### Phase 2: Onboarding

#### 2.1 Download diarization models during onboarding

**File:** `Sources/MacParakeetViewModels/OnboardingViewModel.swift`

Add diarization model download step after ASR model download:

```
Step 1: Permissions (mic, accessibility)
Step 2: Download ASR models (~6 GB)      ← existing
Step 3: Download diarization models (~100 MB)  ← new
Step 4: Verify / warm-up
```

Use `OfflineDiarizerManager.prepareModels()` which handles download + CoreML compilation.

### Phase 3: UI

#### 3.1 Speaker labels in transcript view

**File:** `Sources/MacParakeet/Views/Transcription/TranscriptTextView.swift` (or equivalent)

Display speaker labels as colored headers before each speaker turn:

```
Speaker 1 (Sarah)
The advancement in cloud native technology has been remarkable...

Speaker 2 (Interviewer)
Can you tell us more about the scheduling changes?
```

- Group consecutive words by `speakerId` into speaker turns
- Assign colors from a fixed palette (DesignSystem tokens)
- Show speaker label at each turn change

#### 3.2 Speaker rename

Allow clicking a speaker label to rename (e.g., "Speaker 1" → "Sarah"):

- Update `speakers` array on the `Transcription` record
- Update all `WordTimestamp.speakerId` values that match the old name
- Persist via `TranscriptionRepository.update()`

#### 3.3 Speaker summary panel

Show per-speaker analytics at the top of the transcript:

- Speaking time (seconds/percentage)
- Word count
- Color swatch

Computed from `wordTimestamps` — group by `speakerId`, sum durations and word counts.

### Phase 4: Export

#### 4.1 Update all export formats

**File:** `Sources/MacParakeetCore/Services/ExportService.swift`

When `speakerCount > 0`, include speaker labels:

| Format | Speaker format |
|--------|---------------|
| TXT | `Speaker 1:\n` before each turn |
| Markdown | `**Speaker 1:**\n` before each turn |
| SRT | `Speaker 1: subtitle text` on each cue |
| VTT | `<v Speaker 1>subtitle text</v>` per WebVTT spec |
| DOCX | Bold speaker name before each turn |
| PDF | Bold speaker name before each turn |
| JSON | `speakerId` field on each word in `wordTimestamps` |

### Phase 5: Tests

#### 5.1 Unit tests

- `SpeakerMergerTests`: Test merge algorithm with various scenarios (exact overlap, partial overlap, no overlap, single speaker, many speakers, empty inputs)
- `DiarizationServiceTests`: Test protocol contract with mock (similar to STT tests)
- `ExportServiceTests`: Test speaker labels in each export format

#### 5.2 Integration tests

- `TranscriptionServiceTests`: Test full pipeline (ASR + diarization + merge) with mock services
- Verify `WordTimestamp` JSON encoding/decoding with and without `speakerId`

## Files Changed (Expected)

| Action | File | Notes |
|--------|------|-------|
| Edit | `Sources/MacParakeetCore/Models/Transcription.swift` | Add `speakerId` to `WordTimestamp` |
| Add | `Sources/MacParakeetCore/Services/DiarizationService.swift` | New service wrapping FluidAudio |
| Add | `Sources/MacParakeetCore/Services/SpeakerMerger.swift` | Pure merge function |
| Edit | `Sources/MacParakeetCore/Services/TranscriptionService.swift` | Integrate diarization after ASR |
| Edit | `Sources/MacParakeetCore/Services/ExportService.swift` | Speaker labels in all formats |
| Edit | `Sources/MacParakeetViewModels/OnboardingViewModel.swift` | Diarization model download step |
| Edit | `Sources/MacParakeetViewModels/TranscriptionViewModel.swift` | Speaker rename, analytics |
| Edit | `Sources/MacParakeet/Views/Transcription/` | Speaker UI (labels, colors, rename) |
| Add | `Tests/MacParakeetTests/Services/SpeakerMergerTests.swift` | Merge algorithm tests |
| Add | `Tests/MacParakeetTests/Services/DiarizationServiceTests.swift` | Service protocol tests |
| Edit | `Tests/MacParakeetTests/Services/ExportServiceTests.swift` | Speaker export tests |
| Edit | `Tests/MacParakeetTests/Models/TranscriptionModelTests.swift` | speakerId encoding tests |

## Dependencies

- FluidAudio 0.12.1 (already in Package.swift) — no changes needed
- `OfflineDiarizerManager`, `OfflineDiarizerConfig`, `OfflineDiarizerModels` — all in `FluidAudio` product

## Risks

| Risk | Mitigation |
|------|------------|
| Diarization accuracy on short clips (<30s) | Test with various lengths; document minimum recommended |
| Model download failure during onboarding | Retry logic + clear error message (same pattern as ASR models) |
| Large files (2+ hours) memory pressure | Use `manager.process(url)` (file-based, memory-mapped) not in-memory arrays |
| Speaker count mismatch expectations | Show "1 speaker detected" gracefully for single-speaker files |
