import XCTest
@testable import MacParakeetCore

final class SpeechEnginePreferenceTests: XCTestCase {
    func testFriendlyVariantNameMapsDefaultWhisperVariant() {
        let raw = SpeechEnginePreference.defaultWhisperModelVariant
        XCTAssertEqual(SpeechEnginePreference.friendlyVariantName(raw), "Large v3 Turbo")
    }

    func testFriendlyVariantNameDropsWhisperPrefix() {
        XCTAssertEqual(
            SpeechEnginePreference.friendlyVariantName("whisper-large-v3-v20240930_turbo_632MB"),
            "Large v3 Turbo"
        )
    }

    func testFriendlyVariantNameMapsLargeWithoutTurbo() {
        XCTAssertEqual(SpeechEnginePreference.friendlyVariantName("large-v3"), "Large v3")
    }

    func testFriendlyVariantNameMapsSmallerSizes() {
        XCTAssertEqual(SpeechEnginePreference.friendlyVariantName("small"), "Small")
        XCTAssertEqual(SpeechEnginePreference.friendlyVariantName("base"), "Base")
        XCTAssertEqual(SpeechEnginePreference.friendlyVariantName("tiny"), "Tiny")
        XCTAssertEqual(SpeechEnginePreference.friendlyVariantName("medium-turbo"), "Medium Turbo")
    }

    func testFriendlyVariantNameFallsBackToRawForUnknownShape() {
        XCTAssertEqual(
            SpeechEnginePreference.friendlyVariantName("xyzzy-experimental-build"),
            "xyzzy-experimental-build"
        )
    }
}
