import SwiftUI

@Observable
final class MeetingRecordingOverlayViewModel {
    enum OverlayState: Equatable {
        case recording
        case transcribing
        case completed
        case error(String)
    }

    var state: OverlayState = .recording
    var microphoneLevel: Float = 0
    var systemLevel: Float = 0
    var recordingElapsedSeconds: Int = 0
    var onStop: (() -> Void)?

    private var timerTask: Task<Void, Never>?

    func startTimer() {
        recordingElapsedSeconds = 0
        timerTask?.cancel()
        timerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { break }
                self.recordingElapsedSeconds += 1
            }
        }
    }

    func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
    }

    var formattedElapsed: String {
        let minutes = recordingElapsedSeconds / 60
        let seconds = recordingElapsedSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
