import MacParakeetCore
import SwiftUI

public struct MeetingRecordingPreviewLine: Identifiable, Equatable, Sendable {
    public let id: String
    public let timestamp: String
    public let speakerLabel: String
    public let text: String
    public let source: AudioSource?

    public init(
        id: String,
        timestamp: String,
        speakerLabel: String,
        text: String,
        source: AudioSource?
    ) {
        self.id = id
        self.timestamp = timestamp
        self.speakerLabel = speakerLabel
        self.text = text
        self.source = source
    }
}

@MainActor @Observable
public final class MeetingRecordingPillViewModel {
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
    public var systemLevel: Float = 0
    public var isExpanded: Bool = false
    public var previewLines: [MeetingRecordingPreviewLine] = []
    public var onStop: (() -> Void)?

    private var hasAutoExpandedPreview = false

    public init() {}

    public func updatePreviewLines(_ lines: [MeetingRecordingPreviewLine]) {
        previewLines = lines
        if !lines.isEmpty, !hasAutoExpandedPreview {
            isExpanded = true
            hasAutoExpandedPreview = true
        }
        if lines.isEmpty {
            isExpanded = false
        }
    }

    public func resetPreview() {
        previewLines = []
        isExpanded = false
        hasAutoExpandedPreview = false
    }

    public var formattedElapsed: String {
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
