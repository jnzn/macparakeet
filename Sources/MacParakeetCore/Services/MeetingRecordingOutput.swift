import Foundation

public struct MeetingRecordingOutput: Sendable, Equatable {
    public let sessionID: UUID
    public let displayName: String
    public let folderURL: URL
    public let mixedAudioURL: URL
    public let microphoneAudioURL: URL
    public let systemAudioURL: URL
    public let durationSeconds: TimeInterval
    public let sourceAlignment: MeetingSourceAlignment

    public init(
        sessionID: UUID,
        displayName: String,
        folderURL: URL,
        mixedAudioURL: URL,
        microphoneAudioURL: URL,
        systemAudioURL: URL,
        durationSeconds: TimeInterval,
        sourceAlignment: MeetingSourceAlignment
    ) {
        self.sessionID = sessionID
        self.displayName = displayName
        self.folderURL = folderURL
        self.mixedAudioURL = mixedAudioURL
        self.microphoneAudioURL = microphoneAudioURL
        self.systemAudioURL = systemAudioURL
        self.durationSeconds = durationSeconds
        self.sourceAlignment = sourceAlignment
    }
}
