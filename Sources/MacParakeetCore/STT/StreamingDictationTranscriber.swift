@preconcurrency import AVFoundation
import Foundation

/// Abstraction over a streaming ASR session for dictation.
///
/// Lifecycle: `loadModels()` once → per-dictation-session `startSession()` → many
/// `appendAudio(_:)` calls as mic buffers arrive → terminal `finish()` (returns final
/// transcript) or `cancel()` (discards). Returned `AsyncStream<String>` yields the
/// current cumulative partial transcript each time the streaming model emits one,
/// and terminates when the session ends.
///
/// Implementations must be thread-safe (actors). Callers feed audio from any thread;
/// the transcriber serializes internally.
public protocol StreamingDictationTranscriber: Sendable {
    /// Download and load the streaming ASR model. Idempotent — safe to call multiple times.
    func loadModels() async throws

    /// True if models are loaded and the transcriber can start sessions.
    func isReady() async -> Bool

    /// Begin a new streaming session. Returns a stream that yields cumulative partial
    /// transcripts. If a session is already active it is cancelled first.
    ///
    /// Throws `StreamingDictationError.modelNotLoaded` if `loadModels()` has not succeeded.
    func startSession() async throws -> AsyncStream<String>

    /// Append an audio buffer to the current session. Any supported format; the
    /// transcriber resamples to 16 kHz mono internally.
    ///
    /// Throws `StreamingDictationError.sessionNotStarted` if no session is active.
    func appendAudio(_ buffer: AVAudioPCMBuffer) async throws

    /// End the current session, flush buffered audio, and return the final transcript.
    /// The partial stream terminates on return.
    ///
    /// Throws `StreamingDictationError.sessionNotStarted` if no session is active.
    func finish() async throws -> String

    /// Abort the current session without returning a transcript. No-op if idle.
    func cancel() async

    /// Release loaded models and free memory. After calling, `loadModels()` must run
    /// again before new sessions.
    func shutdown() async
}

public enum StreamingDictationError: Error, LocalizedError, Equatable {
    case modelNotLoaded
    case sessionNotStarted
    case modelLoadFailed(String)
    case transcriptionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Streaming dictation model is not loaded"
        case .sessionNotStarted:
            return "No active streaming dictation session"
        case .modelLoadFailed(let reason):
            return "Failed to load streaming dictation model: \(reason)"
        case .transcriptionFailed(let reason):
            return "Streaming transcription failed: \(reason)"
        }
    }
}
