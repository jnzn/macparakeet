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
    case pendingStop
    case transcribing
    case finishing(outcome: MeetingRecordingFlowFinishOutcome)
}

public enum MeetingRecordingFlowFinishOutcome: Equatable, Sendable {
    case completed(UUID)
    case error(String)
}

public enum MeetingRecordingFlowEvent: Equatable, Sendable {
    case startRequested
    case permissionsGranted(generation: Int)
    case permissionsDenied(generation: Int, reason: MeetingRecordingPermissionFailure)
    case recordingStarted(generation: Int)
    case startFailed(generation: Int, message: String)
    case stopRequested
    case transcriptionCompleted(generation: Int, transcriptionID: UUID)
    case transcriptionFailed(generation: Int, message: String)
    case dismissRequested
    case autoDismissExpired(generation: Int)
}

public enum MeetingRecordingFlowEffect: Equatable, Sendable {
    case checkPermissions
    case showRecordingOverlay
    case startRecording
    case showTranscribingState
    case stopRecordingAndTranscribe
    case showCompleted
    case showError(String)
    case hideOverlay
    case updateMenuBar(DictationFlowMenuBarState)
    case navigateToTranscription(UUID)
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
            return [.showRecordingOverlay, .startRecording, .updateMenuBar(.recording)]

        case (.checkingPermissions, .permissionsDenied(let gen, let reason)):
            guard gen == generation else { return [] }
            state = .idle
            return [.updateMenuBar(.idle), .presentPermissionAlert(reason)]

        case (.starting, .recordingStarted(let gen)):
            guard gen == generation else { return [] }
            state = .recording
            return []

        case (.starting, .startFailed(let gen, let message)):
            guard gen == generation else { return [] }
            state = .finishing(outcome: .error(message))
            return [.showError(message), .updateMenuBar(.idle), .startAutoDismissTimer(seconds: 5)]

        case (.starting, .stopRequested):
            state = .pendingStop
            return []

        case (.pendingStop, .recordingStarted(let gen)):
            guard gen == generation else { return [] }
            state = .transcribing
            return [.showTranscribingState, .updateMenuBar(.processing), .stopRecordingAndTranscribe]

        case (.pendingStop, .startFailed(let gen, let message)):
            guard gen == generation else { return [] }
            state = .finishing(outcome: .error(message))
            return [.showError(message), .updateMenuBar(.idle), .startAutoDismissTimer(seconds: 5)]

        case (.recording, .stopRequested):
            state = .transcribing
            return [.showTranscribingState, .updateMenuBar(.processing), .stopRecordingAndTranscribe]

        case (.transcribing, .transcriptionCompleted(let gen, let transcriptionID)):
            guard gen == generation else { return [] }
            state = .finishing(outcome: .completed(transcriptionID))
            return [
                .showCompleted,
                .updateMenuBar(.idle),
                .navigateToTranscription(transcriptionID),
                .startAutoDismissTimer(seconds: 1),
            ]

        case (.transcribing, .transcriptionFailed(let gen, let message)):
            guard gen == generation else { return [] }
            state = .finishing(outcome: .error(message))
            return [.showError(message), .updateMenuBar(.idle), .startAutoDismissTimer(seconds: 5)]

        case (.finishing, .dismissRequested):
            state = .idle
            return [.cancelAutoDismissTimer, .hideOverlay]

        case (.finishing, .autoDismissExpired(let gen)):
            guard gen == generation else { return [] }
            state = .idle
            return [.cancelAutoDismissTimer, .hideOverlay]

        case (.recording, .dismissRequested),
             (.starting, .dismissRequested),
             (.pendingStop, .dismissRequested),
             (.transcribing, .dismissRequested),
             (.checkingPermissions, .dismissRequested):
            return []

        default:
            return []
        }
    }
}
