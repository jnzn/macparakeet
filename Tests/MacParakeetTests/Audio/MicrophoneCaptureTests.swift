import XCTest
@testable import MacParakeetCore

final class MicrophoneCaptureTests: XCTestCase {
    func testInitCreatesCaptureInstance() {
        let capture = MicrophoneCapture()
        XCTAssertNotNil(capture)
    }
}
