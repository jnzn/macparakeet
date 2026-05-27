import Foundation

public enum MeetingRecordingPermissionFailure: Equatable, Sendable {
    case microphone
    case screenRecording
}

public enum MeetingRecordingFlowState: Equatable, Sendable {
    case idle
    case checkingPermissions
    case starting
    case recording
    /// Brief wrap-up after a stop: notes are flushed and the audio writer is
    /// finalized, then the recording is handed to the background processor and
    /// the flow returns to `.idle`. Transcription no longer blocks this flow —
    /// it runs detached so a new recording can start immediately.
    case stopping
    case finishing(outcome: MeetingRecordingFlowFinishOutcome)
}

public enum MeetingRecordingFlowFinishOutcome: Equatable, Sendable {
    case error(String)
}

public enum MeetingRecordingFlowEvent: Equatable, Sendable {
    case startRequested
    case permissionsGranted(generation: Int)
    case permissionsDenied(generation: Int, reason: MeetingRecordingPermissionFailure)
    case recordingStarted(generation: Int)
    case startFailed(generation: Int, message: String)
    case stopRequested
    case cancelRequested
    /// Emitted by the pill polling task when it detects that audio capture
    /// has stopped unexpectedly while the state machine still believes a
    /// recording is in progress (e.g., a USB mic was unplugged mid-meeting,
    /// `MeetingRecordingService.failCapture` ran). Routes through the same
    /// stop+handoff path as `.stopRequested` so whatever audio was captured
    /// before the failure still becomes a saved Transcription in the background.
    case captureFailed(generation: Int)
    /// Audio finalized and the recording was handed to the background
    /// processor; the foreground flow can return to idle.
    case handedOffToBackground(generation: Int)
    /// Stop / audio finalize failed before handoff (rare — disk full, writer
    /// error). Surface an error pill rather than silently losing the recording.
    case handoffFailed(generation: Int, message: String)
    case dismissRequested
    case autoDismissExpired(generation: Int)
}

public enum MeetingRecordingFlowEffect: Equatable, Sendable {
    case checkPermissions
    case showRecordingPill
    case startRecording
    /// Flush notes, finalize audio, hand the recording to the background
    /// transcription processor, then emit `.handedOffToBackground`.
    case stopRecordingAndHandOff
    case showError(String)
    case cancelRecording
    case hidePill
    case updateMenuBar(DictationFlowMenuBarState)
    case presentPermissionAlert(MeetingRecordingPermissionFailure)
    case startAutoDismissTimer(seconds: Double)
    case cancelAutoDismissTimer
}

public struct MeetingRecordingFlowStateMachine: Equatable, Sendable {
    public private(set) var state: MeetingRecordingFlowState = .idle
    public private(set) var generation: Int = 0

    public init() {}

    public mutating func handle(_ event: MeetingRecordingFlowEvent) -> [MeetingRecordingFlowEffect] {
        switch (state, event) {
        case (.idle, .startRequested):
            generation += 1
            state = .checkingPermissions
            return [.checkPermissions]

        case (.checkingPermissions, .permissionsGranted(let gen)):
            guard gen == generation else { return [] }
            state = .starting
            return [.showRecordingPill, .startRecording, .updateMenuBar(.recording)]

        case (.checkingPermissions, .permissionsDenied(let gen, let reason)):
            guard gen == generation else { return [] }
            state = .idle
            return [.updateMenuBar(.idle), .presentPermissionAlert(reason)]

        case (.checkingPermissions, .cancelRequested):
            state = .idle
            return [.cancelRecording, .hidePill, .updateMenuBar(.idle)]

        case (.starting, .recordingStarted(let gen)):
            guard gen == generation else { return [] }
            state = .recording
            return []

        case (.starting, .startFailed(let gen, let message)):
            guard gen == generation else { return [] }
            state = .finishing(outcome: .error(message))
            return [.showError(message), .updateMenuBar(.idle), .startAutoDismissTimer(seconds: 5)]

        case (.starting, .stopRequested):
            // Stop arrived before the recording confirmed start. Defer the
            // handoff until `.recordingStarted` so there is something to finalize.
            state = .stopping
            return []

        case (.starting, .cancelRequested):
            state = .idle
            return [.cancelRecording, .hidePill, .updateMenuBar(.idle)]

        case (.stopping, .recordingStarted(let gen)):
            guard gen == generation else { return [] }
            // The deferred stop (above) now has a live recording to finalize.
            state = .stopping
            return [.stopRecordingAndHandOff]

        case (.stopping, .startFailed(let gen, let message)):
            guard gen == generation else { return [] }
            state = .finishing(outcome: .error(message))
            return [.showError(message), .updateMenuBar(.idle), .startAutoDismissTimer(seconds: 5)]

        case (.recording, .cancelRequested):
            state = .idle
            return [.cancelRecording, .hidePill, .updateMenuBar(.idle)]

        case (.recording, .stopRequested):
            state = .stopping
            return [.stopRecordingAndHandOff]

        case (.recording, .captureFailed(let gen)):
            guard gen == generation else { return [] }
            state = .stopping
            return [.stopRecordingAndHandOff]

        case (.stopping, .handedOffToBackground(let gen)):
            guard gen == generation else { return [] }
            // Audio is finalized and the background processor owns the
            // transcription. Free the pill and return to idle so the user can
            // record again immediately; the menu-bar badge reflects the
            // in-flight job independently.
            state = .idle
            return [.hidePill, .updateMenuBar(.idle)]

        case (.stopping, .handoffFailed(let gen, let message)):
            guard gen == generation else { return [] }
            state = .finishing(outcome: .error(message))
            return [.showError(message), .updateMenuBar(.idle), .startAutoDismissTimer(seconds: 5)]

        case (.finishing, .dismissRequested):
            state = .idle
            return [.cancelAutoDismissTimer, .hidePill]

        case (.finishing, .autoDismissExpired(let gen)):
            guard gen == generation else { return [] }
            state = .idle
            return [.hidePill]

        case (.recording, .dismissRequested),
             (.starting, .dismissRequested),
             (.stopping, .dismissRequested),
             (.checkingPermissions, .dismissRequested):
            return []

        default:
            return []
        }
    }
}
