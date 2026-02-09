# MacParakeet: Architecture

> Status: **ACTIVE** - Authoritative, current
> The definitive technical stack and system design for MacParakeet.

---

## System Overview

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│                              MACPARAKEET                                          │
│                          macOS Native App                                         │
├──────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  ┌────────────────────────────────────────────────────────────────────────────┐  │
│  │                             UI LAYER                                       │  │
│  │                           (SwiftUI)                                        │  │
│  │  ┌───────────────┐  ┌───────────────┐  ┌───────────────┐  ┌───────────┐  │  │
│  │  │  Main Window  │  │   Menu Bar    │  │   Dictation   │  │ Settings  │  │  │
│  │  │  (Drop Zone + │  │   (Status +   │  │   Overlay     │  │   View    │  │  │
│  │  │  Transcripts) │  │    Quick      │  │  (Recording   │  │           │  │  │
│  │  │               │  │    Actions)   │  │   Indicator)  │  │           │  │  │
│  │  └───────┬───────┘  └───────┬───────┘  └───────┬───────┘  └─────┬─────┘  │  │
│  │          └──────────────────┴──────────────────┴─────────────────┘         │  │
│  └──────────────────────────────────────┬─────────────────────────────────────┘  │
│                                         │                                        │
│                                         ▼                                        │
│  ┌────────────────────────────────────────────────────────────────────────────┐  │
│  │                        MacParakeetCore                                     │  │
│  │                     (Library — No UI Deps)                                 │  │
│  │                                                                            │  │
│  │  ┌─────────────────┐  ┌──────────────────────┐  ┌──────────────────────┐  │  │
│  │  │ DictationService│  │ TranscriptionService │  │ CommandModeService  │  │  │
│  │  └────────┬────────┘  └──────────┬───────────┘  └──────────┬──────────┘  │  │
│  │           │                      │                         │              │  │
│  │  ┌────────▼────────────────────────────────────────────────▼───────────┐  │  │
│  │  │                        AudioProcessor                               │  │  │
│  │  │            (Format conversion, resampling, buffering)               │  │  │
│  │  └────────────────────────────┬────────────────────────────────────────┘  │  │
│  │                               │                                           │  │
│  │  ┌──────────────┐  ┌─────────▼─────────┐  ┌────────────────────────────┐ │  │
│  │  │  AIService   │  │    STTClient      │  │  TextProcessingPipeline   │ │  │
│  │  │  (MLX-Swift) │  │  (JSON-RPC IPC)   │  │  (Deterministic cleanup)  │ │  │
│  │  └──────┬───────┘  └─────────┬─────────┘  └────────────────────────────┘ │  │
│  │         │                    │                                             │  │
│  │  ┌──────▼───────┐  ┌────────▼──────────────────────────────────────────┐ │  │
│  │  │ExportService │  │               Data Layer                          │ │  │
│  │  │(TXT,SRT,VTT) │  │  Models: Dictation, Transcription,               │ │  │
│  │  └──────────────┘  │          CustomWord, TextSnippet                  │ │  │
│  │                     │  Repos:  DictationRepository,                     │ │  │
│  │                     │          TranscriptionRepository,                 │ │  │
│  │                     │          CustomWordRepository,                    │ │  │
│  │                     │          TextSnippetRepository                    │ │  │
│  │                     │  DB:     GRDB (SQLite, single file)              │ │  │
│  │                     └──────────────────────────────────────────────────┘ │  │
│  └────────────────────────────────────────────────────────────────────────────┘  │
│                                                                                  │
├──────────────────────────────────────────────────────────────────────────────────┤
│                          EXTERNAL PROCESSES                                      │
│                                                                                  │
│  ┌──────────────────────────────┐   ┌──────────────────────────────────────────┐ │
│  │   Parakeet STT Daemon        │   │   MLX-Swift LLM (In-Process)             │ │
│  │   (Python, JSON-RPC over     │   │   Qwen3-4B (4-bit quantized)             │ │
│  │    stdin/stdout)              │   │   ~2.5 GB RAM                            │ │
│  │   parakeet-mlx ~1.5 GB       │   │   Command mode + AI refinement           │ │
│  └──────────────────────────────┘   └──────────────────────────────────────────┘ │
│                                                                                  │
├──────────────────────────────────────────────────────────────────────────────────┤
│                          SYSTEM INTEGRATIONS                                     │
│                                                                                  │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌─────────────┐  ┌──────────────┐   │
│  │AVAudio   │  │Core Audio│  │ CGEvent  │  │NSPasteboard │  │Accessibility │   │
│  │Engine    │  │(System   │  │(Global   │  │(Clipboard   │  │(Permission   │   │
│  │(Mic)     │  │ Audio)   │  │ Hotkey)  │  │ Paste)      │  │ Control)     │   │
│  └──────────┘  └──────────┘  └──────────┘  └─────────────┘  └──────────────┘   │
│                                                                                  │
│  Total AI Memory: ~4 GB peak (Parakeet ~1.5 GB + LLM ~2.5 GB)                  │
│  Recommended: 16 GB RAM (Apple Silicon only)                                     │
└──────────────────────────────────────────────────────────────────────────────────┘
```

**All AI runs on-device.** No network, no API keys, no cloud costs. Privacy is the brand.

---

## Components Detail

### 1. MacParakeet App (GUI — SwiftUI)

The UI layer. Thin shell over MacParakeetCore. No business logic lives here.

#### Main Window

**Responsibility:** Primary interface for file transcription. Accepts drag-and-drop, displays transcripts, provides export controls.

**Key Types:**
- `MainWindowView` — Drop zone + transcript display + recent files list
- `TranscriptView` — Scrollable text with optional word-level timestamps
- `ProgressView` — Transcription progress indicator with cancel

**Dependencies:** `TranscriptionService`, `ExportService`

**Data Flow:**
```
File dropped → MainWindowView → TranscriptionService.transcribe(file:)
                                       │
                                       ▼
                              Transcript displayed
```

#### Menu Bar

**Responsibility:** Always-visible status indicator. Quick access to dictation, recent files, and settings.

**Key Types:**
- `MenuBarController` — NSStatusItem management
- `MenuBarView` — SwiftUI menu content

**Dependencies:** `DictationService`, app state

#### Dictation Overlay

**Responsibility:** Floating, non-activating panel that shows recording state. Appears near the cursor or in a fixed position. Does not steal focus from the active app.

**Key Types:**
- `DictationOverlayView` — Waveform visualization + status text
- `DictationOverlayController` — NSPanel (non-activating) lifecycle

**Dependencies:** `DictationService` (observes state)

**Design Notes:**
- Uses `NSPanel` with `.nonactivatingPanel` collection behavior so it never steals keyboard focus
- Subclass `NSPanel` as `KeylessPanel` with `canBecomeKey → false`
- Audio level visualization driven by `DictationService` publishing amplitude values

#### Settings View

**Responsibility:** User preferences. Dictation hotkey, processing mode, custom words, text snippets, general preferences.

**Key Types:**
- `SettingsView` — TabView container
- `GeneralSettingsView` — Launch at login, menu bar mode, default language
- `DictationSettingsView` — Hotkey config, stop mode, processing mode
- `CustomWordsManageView` — CRUD for vocabulary corrections
- `TextSnippetsManageView` — CRUD for trigger/expansion pairs

**Dependencies:** `UserDefaults`, `CustomWordRepository`, `TextSnippetRepository`

---

### 2. MacParakeetCore (Library — No UI Dependencies)

The shared core. All business logic, all data access, all service orchestration. Imported by the GUI app (and optionally by a future CLI).

#### 2.1 DictationService

**Responsibility:** Orchestrates the full dictation lifecycle: hotkey detection, audio capture, STT, text processing, and clipboard paste.

**Key Types/Protocols:**
```swift
protocol DictationServiceProtocol {
    var state: DictationState { get }           // .idle, .recording, .processing, .done, .error
    var audioLevel: Float { get }               // 0.0–1.0, published for overlay waveform
    func startRecording() async throws
    func stopRecording() async throws -> DictationResult
    func cancel()
}

enum DictationState {
    case idle
    case recording(duration: TimeInterval)
    case processing
    case done(DictationResult)
    case error(DictationError)
}

struct DictationResult {
    let rawTranscript: String
    let cleanTranscript: String?
    let duration: TimeInterval
    let audioPath: URL?
}
```

**Dependencies:** `AudioProcessor`, `STTClient`, `TextProcessingPipeline`, `DictationRepository`

**Data Flow:**
```
Hotkey pressed
    │
    ▼
DictationService.startRecording()
    │ ── AVAudioEngine installs tap on input node
    │ ── Audio buffer accumulates in memory
    │ ── Publishes audioLevel for overlay
    │
Hotkey released (or toggle stop)
    │
    ▼
DictationService.stopRecording()
    │ ── Writes buffer to temp WAV (16kHz mono)
    │ ── Sends to STTClient
    │ ── Receives raw transcript
    │ ── Runs TextProcessingPipeline (if mode == .clean)
    │ ── Saves to DictationRepository
    │ ── Pastes via NSPasteboard + CGEvent (Cmd+V)
    │
    ▼
DictationResult returned
```

#### 2.2 TranscriptionService

**Responsibility:** Orchestrates file-based transcription: audio preprocessing, STT, optional AI refinement, progress reporting.

**Key Types/Protocols:**
```swift
protocol TranscriptionServiceProtocol {
    func transcribe(file: URL, options: TranscriptionOptions) async throws -> TranscriptionResult
    func cancel()
    var progress: TranscriptionProgress { get }
}

struct TranscriptionOptions {
    let language: String?           // nil = auto-detect
    let includeTimestamps: Bool     // word-level timestamps
    let refinementLevel: RefinementLevel  // .none, .clean, .formal
}

struct TranscriptionResult {
    let transcript: String
    let words: [TimestampedWord]?
    let duration: TimeInterval
    let language: String
}

struct TranscriptionProgress {
    let stage: Stage                // .converting, .transcribing, .refining
    let fraction: Double            // 0.0–1.0
}
```

**Dependencies:** `AudioProcessor`, `STTClient`, `AIService` (optional), `TranscriptionRepository`

**Data Flow:**
```
File URL
    │
    ▼
AudioProcessor.convert(file:) → 16kHz mono WAV in temp dir
    │
    ▼
STTClient.transcribe(audioPath:) → raw transcript + word timestamps
    │
    ▼
AIService.refine(text:, level:) → refined transcript (if requested)
    │
    ▼
TranscriptionRepository.save() → persisted to database
    │
    ▼
TranscriptionResult returned to UI
```

#### 2.3 TextProcessingPipeline

**Responsibility:** Deterministic, rule-based text cleanup. Runs after STT, before display. No LLM involved — fast, predictable, repeatable.

**Key Types/Protocols:**
```swift
protocol TextProcessingPipelineProtocol {
    func process(_ text: String) -> String
}

// Pipeline stages (executed in order):
// 1. Custom word replacements (vocabulary anchors + corrections)
// 2. Text snippet expansion (trigger → expansion)
// 3. Capitalization normalization
// 4. Punctuation cleanup
// 5. Whitespace normalization
```

**Dependencies:** `CustomWordRepository`, `TextSnippetRepository`

**Design Notes:**
- All stages are pure functions over strings — trivially testable
- Custom words loaded once and cached; refreshed on repository change
- Pipeline is synchronous — no async overhead for a few hundred microseconds of work
- Separate from `AIService` refinement: pipeline is deterministic rules, AI is probabilistic

#### 2.4 CommandModeService

**Responsibility:** Select-and-replace workflow. User selects text, triggers hotkey, speaks a command (e.g., "make this more formal"), and the LLM transforms the selected text.

**Key Types/Protocols:**
```swift
protocol CommandModeServiceProtocol {
    func execute(selectedText: String, command: String) async throws -> String
}
```

**Dependencies:** `AIService`, Accessibility API (to read selection), `NSPasteboard` (to replace)

**Data Flow:**
```
User selects text in any app
    │
    ▼
Command hotkey pressed → DictationService records command
    │
    ▼
Accessibility reads selected text (AXUIElement)
    │
    ▼
CommandModeService.execute(selectedText:, command:)
    │ ── Constructs prompt: "Given this text: {selection}\nDo: {command}"
    │ ── Sends to AIService (non-thinking mode)
    │ ── Receives transformed text
    │
    ▼
Replace selection via NSPasteboard + CGEvent (Cmd+V)
```

#### 2.5 AudioProcessor

**Responsibility:** Audio format conversion and resampling. Converts any supported input format to 16kHz mono WAV for Parakeet. Also handles microphone audio buffer management for dictation.

**Key Types/Protocols:**
```swift
protocol AudioProcessorProtocol {
    func convert(file: URL) async throws -> URL       // → 16kHz mono WAV
    func startCapture() throws                         // mic recording
    func stopCapture() throws -> URL                   // → saved WAV
    var audioLevel: Float { get }                      // current amplitude
}
```

**Dependencies:** AVFoundation (mic capture), FFmpeg (file conversion — via bundled binary)

**Design Notes:**
- FFmpeg invoked as a subprocess (`Process`), not linked as a library
- Temp files written to app-scoped temp directory, cleaned after use
- Microphone capture uses `AVAudioEngine` with a tap on the input node
- Audio buffer stored in memory during recording, flushed to disk on stop
- Supports: MP3, WAV, M4A, FLAC, OGG, OPUS, MP4, MOV, MKV, WebM, AVI

#### 2.6 STTClient

**Responsibility:** JSON-RPC client that communicates with the Parakeet Python daemon. Manages daemon lifecycle (start, health check, restart).

**Key Types/Protocols:**
```swift
protocol STTClientProtocol {
    func transcribe(audioPath: URL, language: String?) async throws -> STTResult
    func isReady() async -> Bool
    func warmUp() async throws
}

struct STTResult {
    let text: String
    let words: [TimestampedWord]
    let duration: TimeInterval
}

struct TimestampedWord {
    let word: String
    let start: TimeInterval
    let end: TimeInterval
    let confidence: Float
}
```

**Dependencies:** Foundation (`Process`, `Pipe` for stdin/stdout IPC)

**Protocol (JSON-RPC 2.0 over stdin/stdout):**
```
┌─────────────────┐    stdin (JSON-RPC request)     ┌─────────────────┐
│                  │ ──────────────────────────────> │                  │
│    STTClient     │                                 │  Parakeet Daemon │
│    (Swift)       │ <────────────────────────────── │  (Python)        │
│                  │    stdout (JSON-RPC response)   │                  │
└─────────────────┘                                  └─────────────────┘
```

**Request:**
```json
{
  "jsonrpc": "2.0",
  "method": "transcribe",
  "params": {
    "audio_path": "/tmp/macparakeet/recording.wav",
    "language": "en"
  },
  "id": 1
}
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "result": {
    "text": "Hello world",
    "words": [
      {"word": "Hello", "start": 0.0, "end": 0.5, "confidence": 0.98},
      {"word": "world", "start": 0.6, "end": 1.0, "confidence": 0.97}
    ],
    "duration": 1.0
  },
  "id": 1
}
```

**Daemon Lifecycle:**
```
App Launch
    │
    ▼
STTClient.warmUp() called (lazy, on first use)
    │
    ├── Check: Is daemon process alive?
    │     │
    │     ├── Yes → Send "ping" health check → Ready
    │     │
    │     └── No ──► Check: Does Python venv exist?
    │                  │
    │                  ├── No ──► Run bundled `uv` to create venv
    │                  │          Install parakeet-mlx + dependencies
    │                  │
    │                  └── Yes ─► Start daemon: `python -m parakeet_daemon`
    │                              Wait for "ready" message on stdout
    │
    ▼
Daemon ready — STTClient accepts transcribe() calls
```

#### 2.7 AIService

**Responsibility:** Local LLM inference via MLX-Swift. Handles text refinement, command mode transformations, and summarization.

**Key Types/Protocols:**
```swift
protocol AIServiceProtocol {
    func refine(text: String, level: RefinementLevel) async throws -> String
    func transform(text: String, command: String) async throws -> String
    func summarize(text: String) async throws -> String
    func isModelLoaded() -> Bool
    func loadModel() async throws
    func unloadModel()
}

enum RefinementLevel {
    case none       // passthrough
    case clean      // remove fillers, fix punctuation
    case formal     // professional tone, grammar fixes
}
```

**Dependencies:** MLX-Swift framework

**Model Details:**

| Property | Value |
|----------|-------|
| Model | Qwen3-4B |
| HuggingFace ID | `mlx-community/Qwen3-4B-4bit` |
| Quantization | 4-bit |
| RAM | ~2.5 GB |
| Framework | MLX-Swift (Apple Silicon Metal) |

**Dual-Mode Operation (same model, different settings):**

| Mode | Use Case | Settings |
|------|----------|----------|
| Non-thinking | Refinement, cleanup, short commands | `temp=0.7, topP=0.8` |
| Thinking | Complex transforms, summarization | `temp=0.6, topP=0.95` |

**Memory Management:**
- Model loaded on-demand (first AI request)
- Unloaded after configurable idle timeout (default: 5 minutes)
- Loading takes ~2-3 seconds on M1; subsequent calls are instant
- Never loaded concurrently with Parakeet warm-up (stagger to avoid memory spike)

#### 2.8 ExportService

**Responsibility:** Convert transcription results into various output formats.

**Key Types/Protocols:**
```swift
protocol ExportServiceProtocol {
    func export(_ transcription: Transcription, format: ExportFormat, to: URL) throws
    func exportToClipboard(_ transcription: Transcription, format: ExportFormat)
}

enum ExportFormat {
    case plainText      // .txt
    case srt            // .srt (SubRip subtitles)
    case vtt            // .vtt (WebVTT subtitles)
    case json           // .json (structured data with timestamps)
}
```

**Dependencies:** Foundation (file I/O), `NSPasteboard` (clipboard)

**Data Flow:**
```
Transcription (from DB or in-memory)
    │
    ▼
ExportService.export(transcription, format: .srt, to: outputURL)
    │ ── Reads word timestamps from transcription
    │ ── Formats into target format (SRT, VTT, etc.)
    │ ── Writes to file
    │
    ▼
File saved at outputURL
```

#### 2.9 Models

All models conform to GRDB's `Codable` + `FetchableRecord` + `PersistableRecord` protocols.

```swift
struct Dictation: Codable, Identifiable {
    let id: UUID
    let createdAt: Date
    let durationMs: Int
    let rawTranscript: String
    let cleanTranscript: String?
    let audioPath: String?
    let pastedToApp: String?        // bundle ID of target app
    let processingMode: ProcessingMode
    let status: DictationStatus     // .completed, .failed, .cancelled
    let errorMessage: String?
}

struct Transcription: Codable, Identifiable {
    let id: UUID
    let createdAt: Date
    let fileName: String
    let filePath: String
    let durationMs: Int
    let transcript: String
    let wordTimestampsJson: String? // JSON-encoded [TimestampedWord]
    let status: TranscriptionStatus
}

struct CustomWord: Codable, Identifiable {
    let id: UUID
    var word: String                // what to match (case-insensitive)
    var replacement: String         // what to replace with
    var source: WordSource          // .user, .builtin
    var isEnabled: Bool
    let createdAt: Date
    var updatedAt: Date
}

struct TextSnippet: Codable, Identifiable {
    let id: UUID
    var trigger: String             // e.g., "addr"
    var expansion: String           // e.g., "123 Main St, Springfield, IL"
    var isEnabled: Bool
    var useCount: Int
    let createdAt: Date
    var updatedAt: Date
}
```

#### 2.10 Repositories

One repository per table. All use GRDB and follow the same pattern.

```swift
// Canonical pattern (DictationRepository shown):
protocol DictationRepositoryProtocol {
    func save(_ dictation: Dictation) async throws
    func fetch(id: UUID) async throws -> Dictation?
    func fetchAll(limit: Int, offset: Int) async throws -> [Dictation]
    func search(query: String) async throws -> [Dictation]
    func delete(id: UUID) async throws
    func stats() async throws -> DictationStats
}

// Same pattern for:
// - TranscriptionRepository
// - CustomWordRepository
// - TextSnippetRepository
```

**Dependencies:** GRDB (`DatabaseQueue`)

**Design Notes:**
- All repositories take a `DatabaseQueue` via init (dependency injection)
- Tests use in-memory SQLite: `DatabaseQueue()` with no path
- Repositories are `actor`-isolated for thread safety
- Migrations run inline on app startup (no migration files)

---

### 3. Parakeet STT Daemon (Python)

External Python process managed by `STTClient`.

**Responsibility:** Speech-to-text transcription using Parakeet TDT 0.6B-v3.

**Key Details:**

| Property | Value |
|----------|-------|
| Model | Parakeet TDT 0.6B-v3 |
| WER | ~6.3% |
| Speed | ~300x realtime on M1+ |
| RAM | ~1.5 GB |
| Input | 16kHz mono WAV |
| Output | Text + word-level timestamps + confidence |
| IPC | JSON-RPC 2.0 over stdin/stdout |

**Bootstrap:** Bundled `uv` binary creates an isolated Python environment on first run. No system Python dependency.

```
~/Library/Application Support/MacParakeet/python/
    ├── .venv/              # Isolated Python environment
    ├── parakeet_daemon.py  # JSON-RPC server script
    └── requirements.txt    # parakeet-mlx, mlx
```

**Methods:**

| Method | Description |
|--------|-------------|
| `transcribe` | Transcribe audio file → text + timestamps |
| `ping` | Health check (returns `"pong"`) |

---

### 4. MLX-Swift LLM (In-Process)

Runs in the Swift process via MLX-Swift framework. Not a separate daemon.

**Responsibility:** AI text refinement and command mode transformations.

**Why In-Process (Not Daemon)?**
- MLX-Swift provides native Swift API — no IPC overhead
- Metal shader compilation needs to happen in the app process
- Simpler lifecycle: load model into memory, call, unload
- Unlike Parakeet (Python), the LLM is pure Swift/Metal

---

## Data Flow Diagrams

### 1. Dictation Flow: Hotkey -> Record -> STT -> Pipeline -> Paste

```
┌─────────┐      ┌─────────────────┐      ┌────────────────┐
│  User    │      │  DictationService│      │  AudioProcessor │
│ (Hotkey) │      │                  │      │                 │
└────┬─────┘      └────────┬────────┘      └────────┬────────┘
     │                     │                        │
     │  Press hotkey       │                        │
     │ ──────────────────> │                        │
     │                     │  startCapture()        │
     │                     │ ─────────────────────> │
     │                     │                        │ ── AVAudioEngine
     │                     │                        │    tap on input
     │                     │    audioLevel updates  │
     │                     │ <───────────────────── │
     │   overlay updates   │                        │
     │ <────────────────── │                        │
     │                     │                        │
     │  Release hotkey     │                        │
     │ ──────────────────> │                        │
     │                     │  stopCapture() → WAV   │
     │                     │ ─────────────────────> │
     │                     │                        │
     │                     │      ┌─────────┐       │
     │                     │ ───> │STTClient│       │
     │                     │      └────┬────┘       │
     │                     │           │            │
     │                     │           │  transcribe(wav)
     │                     │           │ ────────────────────┐
     │                     │           │                     │
     │                     │           │    ┌────────────────▼───┐
     │                     │           │    │  Parakeet Daemon   │
     │                     │           │    └────────────────┬───┘
     │                     │           │                     │
     │                     │           │  raw transcript     │
     │                     │           │ <───────────────────┘
     │                     │           │
     │                     │  raw text │
     │                     │ <──────── │
     │                     │
     │                     │      ┌──────────────────────┐
     │                     │ ───> │TextProcessingPipeline│
     │                     │      └──────────┬───────────┘
     │                     │                 │
     │                     │  clean text     │
     │                     │ <───────────────┘
     │                     │
     │                     │  Save to DictationRepository
     │                     │  Copy to NSPasteboard
     │                     │  Simulate Cmd+V via CGEvent
     │                     │
     │   text pasted       │
     │ <────────────────── │
     │                     │
```

### 2. File Transcription Flow: File -> AudioProcessor -> STT -> Display

```
┌──────────────┐    ┌──────────────────────┐    ┌────────────────┐
│  MainWindow  │    │ TranscriptionService │    │ AudioProcessor │
│  (Drop Zone) │    │                      │    │                │
└──────┬───────┘    └──────────┬───────────┘    └───────┬────────┘
       │                       │                        │
       │  File dropped         │                        │
       │ ────────────────────> │                        │
       │                       │  convert(file)         │
       │                       │ ─────────────────────> │
       │                       │                        │ ── FFmpeg subprocess
       │                       │  16kHz mono WAV        │    input → WAV
       │                       │ <───────────────────── │
       │                       │
       │                       │     ┌──────────┐
       │                       │ ──> │STTClient │ ──> Parakeet Daemon
       │                       │     └─────┬────┘
       │                       │           │
       │                       │  STTResult (text + timestamps)
       │                       │ <──────── │
       │                       │
       │                       │     ┌──────────┐
       │                       │ ──> │AIService │  (optional: refine)
       │                       │     └─────┬────┘
       │                       │           │
       │                       │  refined text
       │                       │ <──────── │
       │                       │
       │                       │  Save to TranscriptionRepository
       │                       │
       │  TranscriptionResult  │
       │ <──────────────────── │
       │                       │
       │  Display transcript   │
       │  in TranscriptView    │
       │                       │
```

### 3. Command Mode Flow: Select Text -> Hotkey -> Record -> LLM -> Replace

```
┌──────┐   ┌──────────────────┐   ┌────────────────┐   ┌───────────┐
│ User │   │CommandModeService│   │DictationService│   │ AIService │
└──┬───┘   └────────┬─────────┘   └───────┬────────┘   └─────┬─────┘
   │                │                      │                  │
   │ Select text    │                      │                  │
   │ in any app     │                      │                  │
   │                │                      │                  │
   │ Command hotkey │                      │                  │
   │ ─────────────> │                      │                  │
   │                │  Record voice command│                  │
   │                │ ──────────────────── │                  │
   │                │                      │                  │
   │  (user speaks: │                      │                  │
   │  "make formal")│                      │                  │
   │                │                      │                  │
   │                │  command transcript  │                  │
   │                │ <─────────────────── │                  │
   │                │                      │                  │
   │                │  Read selected text via Accessibility   │
   │                │  (AXUIElement focused element → value)  │
   │                │                                         │
   │                │  transform(selectedText, command)       │
   │                │ ──────────────────────────────────────> │
   │                │                                         │
   │                │         ┌──────────────────────────┐    │
   │                │         │ Prompt:                  │    │
   │                │         │ "Given text: {selection} │    │
   │                │         │  Command: make formal    │    │
   │                │         │  Return transformed text"│    │
   │                │         └──────────────────────────┘    │
   │                │                                         │
   │                │  transformed text                       │
   │                │ <────────────────────────────────────── │
   │                │                                         │
   │                │  Replace via NSPasteboard + Cmd+V       │
   │                │                                         │
   │ Text replaced  │                                         │
   │ <───────────── │                                         │
   │                │                                         │
```

### 4. Export Flow: Transcription -> Format -> File

```
┌──────────────┐    ┌───────────────┐    ┌───────────────┐
│  MainWindow  │    │ ExportService │    │  File System  │
└──────┬───────┘    └───────┬───────┘    └───────┬───────┘
       │                    │                    │
       │ User clicks Export │                    │
       │ Selects format     │                    │
       │ (e.g., .srt)      │                    │
       │                    │                    │
       │ export(transcription, .srt, outputURL)  │
       │ ─────────────────> │                    │
       │                    │                    │
       │                    │  Read word timestamps
       │                    │  from transcription
       │                    │                    │
       │                    │  Format as SRT:    │
       │                    │  ┌───────────────┐ │
       │                    │  │ 1             │ │
       │                    │  │ 00:00:00,000  │ │
       │                    │  │ --> 00:00:00, │ │
       │                    │  │ 500           │ │
       │                    │  │ Hello world   │ │
       │                    │  └───────────────┘ │
       │                    │                    │
       │                    │  Write to file     │
       │                    │ ─────────────────> │
       │                    │                    │
       │  Success           │                    │
       │ <───────────────── │                    │
       │                    │                    │
```

---

## Database Architecture

Single SQLite file via GRDB. All data in one place. No external database processes.

**Location:** `~/Library/Application Support/MacParakeet/macparakeet.db`

### Schema

```sql
-- Dictation history (voice-to-text sessions)
CREATE TABLE dictations (
    id              TEXT PRIMARY KEY,       -- UUID
    created_at      TEXT NOT NULL,          -- ISO 8601
    duration_ms     INTEGER NOT NULL,       -- recording duration
    raw_transcript  TEXT NOT NULL,          -- exact STT output
    clean_transcript TEXT,                  -- after TextProcessingPipeline
    audio_path      TEXT,                   -- relative path to saved audio (nullable)
    pasted_to_app   TEXT,                   -- bundle ID of target app
    processing_mode TEXT NOT NULL,          -- 'raw' | 'clean'
    status          TEXT NOT NULL,          -- 'completed' | 'failed' | 'cancelled'
    error_message   TEXT                    -- non-null if status == 'failed'
);
CREATE INDEX idx_dictations_created_at ON dictations(created_at);
CREATE INDEX idx_dictations_status ON dictations(status);

-- File transcription history
CREATE TABLE transcriptions (
    id                   TEXT PRIMARY KEY,  -- UUID
    created_at           TEXT NOT NULL,     -- ISO 8601
    file_name            TEXT NOT NULL,     -- original file name
    file_path            TEXT NOT NULL,     -- original file path
    duration_ms          INTEGER NOT NULL,  -- audio duration
    transcript           TEXT NOT NULL,     -- final transcript text
    word_timestamps_json TEXT,              -- JSON: [{"word":...,"start":...,"end":...,"confidence":...}]
    status               TEXT NOT NULL      -- 'completed' | 'failed' | 'processing'
);
CREATE INDEX idx_transcriptions_created_at ON transcriptions(created_at);

-- Custom word corrections (vocabulary anchors)
CREATE TABLE custom_words (
    id          TEXT PRIMARY KEY,           -- UUID
    word        TEXT NOT NULL,              -- match target (case-insensitive)
    replacement TEXT NOT NULL,              -- replacement text
    source      TEXT NOT NULL DEFAULT 'user', -- 'user' | 'builtin'
    is_enabled  INTEGER NOT NULL DEFAULT 1,
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL
);
CREATE UNIQUE INDEX idx_custom_words_word ON custom_words(word);

-- Text snippet expansion (trigger → expansion)
CREATE TABLE text_snippets (
    id          TEXT PRIMARY KEY,           -- UUID
    trigger     TEXT NOT NULL,              -- trigger text (e.g., "addr")
    expansion   TEXT NOT NULL,              -- expanded text
    is_enabled  INTEGER NOT NULL DEFAULT 1,
    use_count   INTEGER NOT NULL DEFAULT 0,
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL
);
CREATE UNIQUE INDEX idx_text_snippets_trigger ON text_snippets(trigger);
```

### Migrations

Migrations run inline on app startup (not separate files). Pattern:

```swift
var migrator = DatabaseMigrator()

migrator.registerMigration("v1_initial") { db in
    try db.create(table: "dictations") { t in
        t.column("id", .text).primaryKey()
        t.column("created_at", .text).notNull()
        t.column("duration_ms", .integer).notNull()
        t.column("raw_transcript", .text).notNull()
        t.column("clean_transcript", .text)
        t.column("audio_path", .text)
        t.column("pasted_to_app", .text)
        t.column("processing_mode", .text).notNull()
        t.column("status", .text).notNull()
        t.column("error_message", .text)
    }
    // ... other tables
}

// Future migrations append here:
// migrator.registerMigration("v2_add_language") { ... }

try migrator.migrate(dbQueue)
```

### Entity-Relationship Diagram

```
┌─────────────────┐
│   dictations    │     (standalone — no foreign keys)
├─────────────────┤
│ id              │
│ created_at      │
│ duration_ms     │
│ raw_transcript  │
│ clean_transcript│
│ audio_path      │
│ pasted_to_app   │
│ processing_mode │
│ status          │
│ error_message   │
└─────────────────┘

┌─────────────────┐
│ transcriptions  │     (standalone — no foreign keys)
├─────────────────┤
│ id              │
│ created_at      │
│ file_name       │
│ file_path       │
│ duration_ms     │
│ transcript      │
│ word_timestamps │
│ status          │
└─────────────────┘

┌─────────────────┐
│  custom_words   │     (standalone — user vocabulary)
├─────────────────┤
│ id              │
│ word            │──── unique index
│ replacement     │
│ source          │
│ is_enabled      │
│ created_at      │
│ updated_at      │
└─────────────────┘

┌─────────────────┐
│ text_snippets   │     (standalone — user shortcuts)
├─────────────────┤
│ id              │
│ trigger         │──── unique index
│ expansion       │
│ is_enabled      │
│ use_count       │
│ created_at      │
│ updated_at      │
└─────────────────┘
```

All four tables are independent. No foreign key relationships. This keeps the schema simple and each repository self-contained.

---

## File Locations

| Item | Path |
|------|------|
| App bundle | `/Applications/MacParakeet.app` |
| Database | `~/Library/Application Support/MacParakeet/macparakeet.db` |
| Dictation audio | `~/Library/Application Support/MacParakeet/dictations/` |
| Transcription exports | `~/Library/Application Support/MacParakeet/transcriptions/` |
| Python venv | `~/Library/Application Support/MacParakeet/python/` |
| ML models | `~/Library/Application Support/MacParakeet/models/` |
| Logs | `~/Library/Logs/MacParakeet/` |
| Temp audio | `$TMPDIR/macparakeet/` (cleaned after use) |
| Settings | `UserDefaults` (standard `com.macparakeet.MacParakeet.plist`) |

### Directory Layout

```
~/Library/Application Support/MacParakeet/
    ├── macparakeet.db              # SQLite database (all app data)
    ├── dictations/                 # Saved dictation audio files
    │   ├── 2026-02-08/             # Organized by date
    │   │   ├── {uuid}.wav
    │   │   └── {uuid}.wav
    │   └── ...
    ├── transcriptions/             # Exported transcripts (user-saved)
    ├── python/                     # Parakeet STT daemon
    │   ├── .venv/                  # Isolated Python env (created by uv)
    │   ├── parakeet_daemon.py      # JSON-RPC server
    │   └── requirements.txt
    └── models/                     # Downloaded ML models
        └── Qwen3-4B-4bit/          # LLM model files
```

---

## Dependencies

### Swift Packages

| Package | SPM ID | Purpose | Notes |
|---------|--------|---------|-------|
| mlx-swift-lm | `MLXLLM`, `MLXLMCommon` | LLM inference (Qwen3-4B) | v2.29.0+, Apple Silicon Metal acceleration |
| GRDB.swift | `GRDB` | SQLite database | v6.29.0+, single-file storage, migrations, Codable records |
| swift-argument-parser | `ArgumentParser` | CLI (optional, future) | Thin CLI over MacParakeetCore |

### Python (Daemon)

| Package | Purpose | Notes |
|---------|---------|-------|
| parakeet-mlx | STT engine (Parakeet TDT 0.6B-v3) | MLX-accelerated inference |
| mlx | ML framework | Apple Silicon backend |

### Bundled Binaries

| Tool | Purpose | Notes |
|------|---------|-------|
| uv | Python environment management | Creates isolated venv, no system Python needed |
| FFmpeg | Audio format conversion | Any format to 16kHz mono WAV for Parakeet |

### System Frameworks

| Framework | Purpose |
|-----------|---------|
| AVFoundation / AVAudioEngine | Microphone capture |
| CoreGraphics (CGEvent) | Global hotkey detection, simulated keystrokes (Cmd+V) |
| AppKit (NSPasteboard) | Clipboard read/write for paste |
| Accessibility (AXUIElement) | Read selected text for command mode |
| SwiftUI | All UI |
| UniformTypeIdentifiers | File type detection for drag-and-drop |

---

## Security & Privacy

### Permissions Required

| Permission | Reason | When Requested | Required? |
|------------|--------|----------------|-----------|
| Microphone | Dictation recording | First dictation attempt | Yes (for dictation) |
| Accessibility | Global hotkey + simulated paste + read selection | First dictation attempt | Yes (for dictation) |

### Permission Flow

```
First Launch
    │
    ▼
Show onboarding: explain what permissions are needed and why
    │
    ▼
User triggers first dictation
    │
    ├── Microphone permission dialog (system)
    │     ├── Granted → continue
    │     └── Denied → show "enable in System Settings" guidance
    │
    ├── Accessibility permission dialog (system)
    │     ├── Granted → continue
    │     └── Denied → show guidance (hotkey + paste won't work)
    │
    ▼
Dictation ready
```

### Privacy Guarantees

1. **No network by default** — App works fully offline. No API calls, no telemetry, no analytics
2. **Temp files cleaned** — Audio files in `$TMPDIR` deleted immediately after transcription
3. **No accounts** — No login, no email, no user tracking
4. **No analytics** — Zero telemetry. Not even crash reporting (unless user opts in)
5. **Audio storage is opt-in** — Dictation audio only saved if user enables "Keep audio" in settings
6. **Local AI only** — All ML inference happens on-device via Metal GPU

### Sandboxing (App Store)

For App Store distribution, the app needs:

| Entitlement | Required For |
|-------------|-------------|
| `com.apple.security.device.audio-input` | Microphone access |
| `com.apple.security.temporary-exception.apple-events` | Accessibility (paste simulation) |
| `com.apple.security.files.user-selected.read-write` | File drag-and-drop |
| `com.apple.security.files.downloads.read-write` | Export to Downloads |
| Hardened Runtime | Code signing requirement |

**Sandboxing Challenges:**
- Accessibility API (`AXUIElement`) requires the app to be in the Accessibility allow-list, which is a system-level permission, not an entitlement
- Spawning Python subprocess (`Process`) works in sandbox but with restricted file access
- FFmpeg subprocess similarly needs careful path handling within the sandbox container
- Direct distribution (notarized DMG) avoids most sandbox restrictions

---

## Performance

### Memory Budget

```
┌────────────────────────────────────────────────────────────┐
│                    Memory at Peak                           │
├────────────────────────────────────────────────────────────┤
│  Parakeet model (loaded)         ~1.5 GB                   │
│  Qwen3-4B LLM (loaded)          ~2.5 GB                   │
│  App process (UI + services)     ~100 MB                   │
│  Audio buffers                   ~50 MB                    │
│  ──────────────────────────────────────                    │
│  Total peak                      ~4.2 GB                   │
│                                                            │
│  Recommended system RAM: 16 GB (Apple Silicon)             │
│  Minimum: 8 GB (LLM features disabled)                     │
└────────────────────────────────────────────────────────────┘
```

### Startup Performance

| Phase | Target | Strategy |
|-------|--------|----------|
| App window visible | <1 second | SwiftUI, no heavy init |
| Dictation ready | <2 seconds | Daemon started lazily, not at launch |
| First STT result | <3 seconds | Model warm-up on first transcribe call |
| LLM ready | <3 seconds | Loaded on-demand, not at launch |

**Lazy Loading Strategy:**
```
App Launch ──────────> Window shown (fast, no ML loaded)
                           │
                           │ User triggers dictation
                           ▼
                       Start Parakeet daemon (background)
                           │ ~2s
                           ▼
                       Daemon ready → recording starts
                           │
                           │ User stops recording
                           ▼
                       Transcribe (Parakeet: 300x realtime)
                           │
                           │ If AI refinement needed:
                           ▼
                       Load Qwen3-4B (background, ~2-3s)
                           │
                           ▼
                       Refine text (~1-2s)
                           │
                           ▼
                       Paste result
```

After initial warm-up, subsequent dictations are near-instant (daemon stays alive, model stays loaded with idle timeout).

### Transcription Speed

| Audio Length | Transcription Time (M1) | Transcription Time (M1 Pro+) |
|-------------|------------------------|-------------------------------|
| 1 minute | ~0.2 seconds | ~0.1 seconds |
| 10 minutes | ~2 seconds | ~1 second |
| 1 hour | ~12 seconds | ~6 seconds |
| 4 hours (max) | ~48 seconds | ~24 seconds |

Parakeet TDT 0.6B-v3 achieves approximately 300x realtime on Apple Silicon.

### Memory Management

- **Parakeet daemon:** Stays alive after first use. Terminated after app idle for 10 minutes (configurable). Restarted on next request.
- **LLM model:** Loaded into Metal GPU memory on first AI request. Unloaded after 5 minutes idle. Loading is async and does not block UI.
- **Audio buffers:** Ring buffer during recording, flushed to temp file on stop. No recording duration limit — local processing means no artificial caps.
- **Database:** GRDB uses WAL mode by default. No connection pooling needed (single-user app).

### Background Model Pre-warming

After the user's first dictation session, pre-warm models in the background:

```
First dictation completes
    │
    ▼
Schedule background task (low priority):
    ├── If Parakeet daemon not running → start it
    └── If LLM not loaded AND user uses AI refinement → load model
```

This ensures subsequent interactions feel instant without bloating initial startup.

---

## Testing Strategy

### Philosophy

"Write tests. Not too many. Mostly integration."

MacParakeet has a small surface area compared to Oatmeal. Focus testing on the core pipeline, not on UI chrome.

### Test Categories

| Category | What | How | Example |
|----------|------|-----|---------|
| Unit | Pure logic, models, pipeline stages | XCTest, fast, no I/O | `TextProcessingPipelineTests` |
| Database | CRUD, queries, migrations | In-memory SQLite via GRDB | `DictationRepositoryTests` |
| Integration | Service boundaries, multi-step flows | Protocol mocks, DI | `TranscriptionServiceTests` |
| Manual | Audio capture, paste, hotkeys | Real hardware | Checklist-based |

### What We Test

- **TextProcessingPipeline** — Every stage, edge cases, custom word matching, snippet expansion
- **Models** — Codable round-trip, validation, edge cases
- **Repositories** — CRUD operations, search queries, migration correctness
- **ExportService** — Format generation (SRT, VTT, TXT, JSON)
- **STTClient** — JSON-RPC serialization/deserialization (mock the daemon)
- **AudioProcessor** — Format detection, conversion parameter correctness (mock FFmpeg)

### What We Skip

- **SwiftUI views** — Test ViewModels, not views
- **AVAudioEngine** — Requires real hardware microphone
- **CGEvent / Accessibility** — Requires system permissions, not testable in CI
- **Parakeet model accuracy** — That is the model's problem, not ours
- **MLX-Swift internals** — Trust the framework

### Test Infrastructure

```swift
// In-memory database for tests (canonical pattern):
func makeTestDatabase() throws -> DatabaseQueue {
    let dbQueue = try DatabaseQueue()
    var migrator = DatabaseMigrator()
    // Register all migrations
    registerMigrations(&migrator)
    try migrator.migrate(dbQueue)
    return dbQueue
}

// Protocol-based mocking:
class MockSTTClient: STTClientProtocol {
    var transcribeResult: STTResult?
    func transcribe(audioPath: URL, language: String?) async throws -> STTResult {
        guard let result = transcribeResult else {
            throw STTError.notReady
        }
        return result
    }
}
```

### Running Tests

```bash
# All tests (unit + database + integration)
swift test

# Parallel execution
swift test --parallel

# Filter to specific test class
swift test --filter TextProcessingPipelineTests
```

Note: `swift test` works for tests (no Metal shaders needed). Use `xcodebuild` only for building the GUI app.

---

## Build & Run

### Why xcodebuild?

MLX-Swift requires Metal shaders. `swift build` compiles Swift code but **cannot compile Metal shaders** — the app builds but crashes at runtime with "Failed to load the default metallib." Use `xcodebuild` for app builds.

### Commands

```bash
# Build GUI app
xcodebuild build \
    -scheme MacParakeet \
    -destination 'platform=OS X' \
    -derivedDataPath .build/xcode

# Run GUI app
.build/xcode/Build/Products/Debug/MacParakeet.app/Contents/MacOS/MacParakeet

# Run tests (swift test works fine for tests)
swift test

# Open in Xcode
open Package.swift
```

---

## Architecture Principles

1. **MacParakeetCore has zero UI dependencies.** Import Foundation, never SwiftUI. This enables future CLI and keeps business logic testable.

2. **Protocol-first services.** Every service has a protocol. Tests inject mocks. No singletons.

3. **Local-only by default.** No network calls. No API keys. No cloud fallback. Privacy is the product.

4. **Lazy everything.** Python daemon, LLM model, and audio engine are all started on-demand. Cold launch is <1 second.

5. **Single database file.** All persistent state in one SQLite file. Easy to backup, easy to debug, easy to reset.

6. **Deterministic pipeline, probabilistic AI.** `TextProcessingPipeline` is rule-based and repeatable. `AIService` is LLM-based and optional. Users can choose either or both.

7. **Crash gracefully.** If Parakeet daemon dies, restart it. If LLM fails to load, skip refinement. If paste fails, copy to clipboard and notify. Never lose the transcript.

---

*Last updated: 2026-02-08*
