import XCTest
@testable import MacParakeetCore

final class MicrophoneCaptureTests: XCTestCase {
    func testInitDefaultsVoiceProcessingToDisabled() {
        let capture = MicrophoneCapture()
        XCTAssertFalse(capture.isVoiceProcessingRequested)
    }

    func testInitAllowsVoiceProcessingToBeEnabled() {
        let capture = MicrophoneCapture(enableVoiceProcessing: true)
        XCTAssertTrue(capture.isVoiceProcessingRequested)
    }
}
