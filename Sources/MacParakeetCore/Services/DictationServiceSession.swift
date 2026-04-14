import Foundation

/// Owns monotonic dictation session IDs and provides explicit, session-bound
/// forwarding into DictationService for lifecycle operations.
@MainActor
public final class DictationServiceSession {
    private let service: DictationService
    private var activeSessionID: Int = 0

    public init(service: DictationService) {
        self.service = service
    }

    public var currentSessionID: Int {
        activeSessionID
    }

    public var state: DictationState {
        get async { await service.state }
    }

    public var audioLevel: Float {
        get async { await service.audioLevel }
    }

    public func recordingSnapshot() async -> (state: DictationState, audioLevel: Float, deviceName: String?) {
        async let state = service.state
        async let audioLevel = service.audioLevel
        async let deviceName = service.recordingDeviceName
        return await (state: state, audioLevel: audioLevel, deviceName: deviceName)
    }

    public func reserveNextSessionID() -> Int {
        activeSessionID += 1
        return activeSessionID
    }

    public func startRecording(
        sessionID: Int,
        context: DictationTelemetryContext
    ) async throws {
        try Task.checkCancellation()
        try await service.startRecording(context: context, sessionID: sessionID)
    }

    public func stopRecording(sessionID: Int) async throws -> DictationResult {
        try await service.stopRecording(sessionID: sessionID)
    }

    public func cancelRecording(
        reason: TelemetryDictationCancelReason?,
        sessionID: Int
    ) async {
        await service.cancelRecording(reason: reason, sessionID: sessionID)
    }

    public func confirmCancel(sessionID: Int) async {
        await service.confirmCancel(sessionID: sessionID)
    }

    /// Undo the most recently cancelled recording and transcribe its pending audio.
    /// This intentionally follows DictationService's most-recent-cancelled semantics
    /// rather than the current reserved session ID.
    public func undoCancel() async throws -> DictationResult {
        try await service.undoCancel()
    }

    /// Live LLM cleanup invoked on dictation pauses. Returns nil silently if the
    /// formatter is disabled or the call fails — callers should drop the result
    /// on nil and leave the bubble at raw text.
    public func cleanupTextLive(_ text: String) async -> String? {
        await service.cleanupTextLive(text)
    }
}
