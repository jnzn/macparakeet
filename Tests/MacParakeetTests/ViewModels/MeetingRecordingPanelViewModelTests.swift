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
        viewModel.updatePreviewLines(lines)

        XCTAssertTrue(viewModel.canStop)
        XCTAssertEqual(viewModel.previewLines, lines)
        XCTAssertEqual(viewModel.statusTitle, "Recording")
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

    func testResetClearsTranscriptPreview() {
        let viewModel = MeetingRecordingPanelViewModel()
        viewModel.state = .recording
        viewModel.elapsedSeconds = 42
        viewModel.updatePreviewLines([
            MeetingRecordingPreviewLine(
                id: "1",
                timestamp: "0:42",
                speakerLabel: "Them",
                text: "Reset should clear this",
                source: .system
            )
        ])

        viewModel.reset()

        XCTAssertEqual(viewModel.state, .hidden)
        XCTAssertEqual(viewModel.elapsedSeconds, 0)
        XCTAssertTrue(viewModel.previewLines.isEmpty)
    }
}
