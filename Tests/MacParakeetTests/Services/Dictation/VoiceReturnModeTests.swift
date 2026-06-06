import XCTest
@testable import MacParakeetCore

/// Unit tests for `DictationService.resolveVoiceReturnAction`, the pure helper
/// that turns the refinement engine's "trigger phrase spoken at end" signal
/// (`postPasteAction`) into the effective post-paste action, honoring the
/// Send/Hold mode.
final class VoiceReturnModeTests: XCTestCase {

    // MARK: - Send mode (original behavior)

    func testSendMode_phraseSpoken_submits() {
        let action = DictationService.resolveVoiceReturnAction(
            refinedAction: .returnKey,   // engine matched the trailing phrase
            mode: .send,
            voiceReturnActive: true
        )
        XCTAssertEqual(action, .returnKey)
    }

    func testSendMode_phraseAbsent_doesNothing() {
        let action = DictationService.resolveVoiceReturnAction(
            refinedAction: nil,          // no trailing phrase
            mode: .send,
            voiceReturnActive: true
        )
        XCTAssertNil(action)
    }

    // MARK: - Hold mode (inverted)

    func testHoldMode_phraseSpoken_holdsForReview() {
        let action = DictationService.resolveVoiceReturnAction(
            refinedAction: .returnKey,   // user said the phrase to suppress send
            mode: .hold,
            voiceReturnActive: true
        )
        XCTAssertNil(action, "Speaking the phrase in hold mode must suppress the auto-submit")
    }

    func testHoldMode_phraseAbsent_autoSubmits() {
        let action = DictationService.resolveVoiceReturnAction(
            refinedAction: nil,          // no phrase → default auto-submit
            mode: .hold,
            voiceReturnActive: true
        )
        XCTAssertEqual(action, .returnKey, "Hold mode auto-submits when the phrase is not spoken")
    }

    // MARK: - Feature inactive (disabled / empty phrase) never auto-submits

    func testInactive_holdMode_neverAutoSubmits() {
        let action = DictationService.resolveVoiceReturnAction(
            refinedAction: nil,
            mode: .hold,
            voiceReturnActive: false
        )
        XCTAssertNil(action, "A disabled Voice Return feature must never auto-submit, even in hold mode")
    }

    func testInactive_sendMode_passesThrough() {
        let action = DictationService.resolveVoiceReturnAction(
            refinedAction: nil,
            mode: .send,
            voiceReturnActive: false
        )
        XCTAssertNil(action)
    }

    // MARK: - Mode persistence defaults to the safe `.send`

    func testVoiceReturnModeDefaultsToSend() {
        let defaults = UserDefaults(suiteName: "VoiceReturnModeTests.\(UUID().uuidString)")!
        XCTAssertEqual(VoiceReturnMode.current(defaults: defaults), .send)
    }

    func testVoiceReturnModeRoundTrips() {
        let defaults = UserDefaults(suiteName: "VoiceReturnModeTests.\(UUID().uuidString)")!
        defaults.set(VoiceReturnMode.hold.rawValue, forKey: UserDefaultsAppRuntimePreferences.voiceReturnModeKey)
        XCTAssertEqual(VoiceReturnMode.current(defaults: defaults), .hold)
    }
}
