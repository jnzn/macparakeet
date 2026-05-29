import SwiftUI

@MainActor @Observable
public final class VoiceMemoPillViewModel {
    public enum PillState: Equatable {
        case idle
        case recording
        case transcribing
        case completed
        case error(String)
    }

    public var state: PillState = .idle
    public var elapsedSeconds: Int = 0
    public var micLevel: Float = 0
    public var onStop: (() -> Void)?
    /// Tapping the recording pill opens the live Voice Memo panel (live
    /// transcript + Ask). Stop now lives in that panel, mirroring meetings.
    public var onTap: (() -> Void)?

    public init() {}

    public var formattedElapsed: String {
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
