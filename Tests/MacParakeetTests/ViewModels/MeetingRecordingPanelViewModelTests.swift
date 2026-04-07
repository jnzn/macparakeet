import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class MeetingRecordingPanelViewModelTests: XCTestCase {
    func testInitialStateIsHidden() {
        let viewModel = MeetingRecordingPanelViewModel()

        XCTAssertEqual(viewModel.state, .hidden)
        XCTAssertEqual(viewModel.elapsedSeconds, 0)
        XCTAssertTrue(viewModel.previewLines.isEmpty)
        XCTAssertFalse(viewModel.canStop)
    }

    func testFormattedElapsedUsesMinutesAndSeconds() {
        let viewModel = MeetingRecordingPanelViewModel()
        viewModel.elapsedSeconds = 125

        XCTAssertEqual(viewModel.formattedElapsed, "2:05")
    }

    func testRecordingStateAllowsStopAndUpdatesSegments() {
        let viewModel = MeetingRecordingPanelViewModel()
        let lines = [
            MeetingRecordingPreviewLine(
                id: "1",
                timestamp: "0:05",
                speakerLabel: "Me",
                text: "Testing the meeting panel",
                source: .microphone
            )
        ]

        viewModel.state = .recording
        viewModel.micLevel = 0.6
        viewModel.systemLevel = 0.3
        viewModel.updatePreviewLines(lines)

        XCTAssertTrue(viewModel.canStop)
        XCTAssertTrue(viewModel.showsAudioLevels)
        XCTAssertEqual(viewModel.previewLines, lines)
        XCTAssertEqual(viewModel.statusTitle, "Recording")
        XCTAssertFalse(viewModel.showsLaggingIndicator)
    }

    func testWordCountUpdatesWhenExistingSegmentGrows() {
        let viewModel = MeetingRecordingPanelViewModel()
        let initialLines = [
            MeetingRecordingPreviewLine(
                id: "1",
                timestamp: "0:05",
                speakerLabel: "Me",
                text: "Testing the panel",
                source: .microphone
            )
        ]
        let updatedLines = [
            MeetingRecordingPreviewLine(
                id: "1",
                timestamp: "0:05",
                speakerLabel: "Me",
                text: "Testing the panel with more words",
                source: .microphone
            ),
            MeetingRecordingPreviewLine(
                id: "2",
                timestamp: "0:07",
                speakerLabel: "Them",
                text: "Reply",
                source: .system
            )
        ]

        viewModel.updatePreviewLines(initialLines)
        XCTAssertEqual(viewModel.wordCount, 3)

        viewModel.updatePreviewLines(updatedLines)

        XCTAssertEqual(viewModel.wordCount, 7)
    }

    func testTranscribingAndErrorStatesUpdateStatusSurface() {
        let viewModel = MeetingRecordingPanelViewModel()

        viewModel.state = .transcribing
        XCTAssertFalse(viewModel.canStop)
        XCTAssertEqual(viewModel.statusTitle, "Transcribing")
        XCTAssertTrue(viewModel.showsElapsedTime)

        viewModel.state = .error("Boom")
        XCTAssertEqual(viewModel.statusTitle, "Recording Error")
        XCTAssertEqual(viewModel.statusMessage, "Boom")
        XCTAssertFalse(viewModel.showsElapsedTime)
    }

    func testLaggingRecordingStateUpdatesStatusSurface() {
        let viewModel = MeetingRecordingPanelViewModel()

        viewModel.state = .recording
        viewModel.updatePreviewLines([], isTranscriptionLagging: true)

        XCTAssertTrue(viewModel.showsLaggingIndicator)
        XCTAssertTrue(viewModel.statusMessage.contains("catching up"))

        viewModel.state = .transcribing
        XCTAssertFalse(viewModel.showsLaggingIndicator)
    }

    func testResetClearsTranscriptPreview() {
        let viewModel = MeetingRecordingPanelViewModel()
        viewModel.state = .recording
        viewModel.elapsedSeconds = 42
        viewModel.updatePreviewLines(
            [
                MeetingRecordingPreviewLine(
                    id: "1",
                    timestamp: "0:42",
                    speakerLabel: "Them",
                    text: "Reset should clear this",
                    source: .system
                )
            ],
            isTranscriptionLagging: true
        )

        viewModel.reset()

        XCTAssertEqual(viewModel.state, .hidden)
        XCTAssertEqual(viewModel.elapsedSeconds, 0)
        XCTAssertEqual(viewModel.micLevel, 0)
        XCTAssertEqual(viewModel.systemLevel, 0)
        XCTAssertTrue(viewModel.previewLines.isEmpty)
        XCTAssertFalse(viewModel.isTranscriptionLagging)
    }
}
