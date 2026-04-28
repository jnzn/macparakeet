import XCTest
@testable import MacParakeetCore

final class SpeechEnginePreferenceTests: XCTestCase {
    func testFriendlyVariantNameMapsDefaultWhisperVariant() {
        let raw = SpeechEnginePreference.defaultWhisperModelVariant
        XCTAssertEqual(SpeechEnginePreference.friendlyVariantName(raw), "Large v3 Turbo")
    }

    func testFriendlyVariantNameFallsBackToRawForUnknownShape() {
        XCTAssertEqual(
            SpeechEnginePreference.friendlyVariantName("xyzzy-experimental-build"),
            "xyzzy-experimental-build"
        )
    }
}
