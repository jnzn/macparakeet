import XCTest
import MacParakeetCore
@testable import MacParakeet

final class MeetingRecordingTileTests: XCTestCase {
    func testPermissionStateReadyWhenRequiredPermissionsGranted() {
        let state = MeetingRecordingTile.PermissionState(
            microphoneGranted: true,
            screenRecordingGranted: true,
            sourceMode: .microphoneAndSystem
        )

        XCTAssertEqual(state, .ready(capturesMicrophone: true))
    }

    func testPermissionStateRequiresMicrophoneOnlyWhenMeetingCapturesMicrophone() {
        let microphoneAndSystem = MeetingRecordingTile.PermissionState(
            microphoneGranted: false,
            screenRecordingGranted: true,
            sourceMode: .microphoneAndSystem
        )
        let systemOnly = MeetingRecordingTile.PermissionState(
            microphoneGranted: false,
            screenRecordingGranted: true,
            sourceMode: .systemOnly
        )

        XCTAssertEqual(microphoneAndSystem, .missing(microphone: true, screenRecording: false))
        XCTAssertEqual(systemOnly, .ready(capturesMicrophone: false))
    }

    func testPermissionStateRequiresScreenRecordingForEveryMeetingMode() {
        let microphoneAndSystem = MeetingRecordingTile.PermissionState(
            microphoneGranted: true,
            screenRecordingGranted: false,
            sourceMode: .microphoneAndSystem
        )
        let systemOnly = MeetingRecordingTile.PermissionState(
            microphoneGranted: true,
            screenRecordingGranted: false,
            sourceMode: .systemOnly
        )

        XCTAssertEqual(microphoneAndSystem, .missing(microphone: false, screenRecording: true))
        XCTAssertEqual(systemOnly, .missing(microphone: false, screenRecording: true))
    }
}
