import XCTest
@testable import MacParakeet
@testable import MacParakeetCore

final class HotkeyManagerTests: XCTestCase {
    func testAdditionalModifierInterruptsBareFnBeforeStartup() {
        let manager = HotkeyManager(trigger: .fn)

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn],
                timestampMs: 1_000
            ),
            [
                .scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs),
                .scheduleHoldWindow(milliseconds: FnKeyStateMachine.defaultTapThresholdMs),
            ]
        )

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn, .maskControl],
                timestampMs: 1_050
            ),
            [
                .cancelStartupDebounce,
                .cancelHoldWindow,
            ]
        )

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskControl],
                timestampMs: 1_100
            ),
            [
                .cancelStartupDebounce,
                .cancelHoldWindow,
            ]
        )
    }

    func testAdditionalModifierSilentlyDiscardsAfterProvisionalStartup() {
        let manager = HotkeyManager(trigger: .fn)

        _ = manager.modifierFlagsChangedOutputsForTesting(
            flags: [.maskSecondaryFn],
            timestampMs: 1_000
        )

        XCTAssertEqual(
            manager.startupDebounceElapsedForTesting(),
            [.startRecording(mode: .holdToTalk)]
        )

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn, .maskControl],
                timestampMs: 1_175
            ),
            [
                .cancelStartupDebounce,
                .cancelHoldWindow,
                .discardRecording(showReadyPill: false),
            ]
        )
    }

    // MARK: - Side-Specific Modifier Detection

    func testSideSpecificRightOptionOnlyTriggersOnRightKey() {
        let trigger = HotkeyTrigger(kind: .modifier, modifierName: "option", keyCode: nil, modifierKeyCode: 61)
        let manager = HotkeyManager(trigger: trigger)

        // Right option pressed (keyCode 61) — should trigger
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskAlternate],
                keyCode: 61,
                timestampMs: 1_000
            ),
            [
                .scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs),
                .scheduleHoldWindow(milliseconds: FnKeyStateMachine.defaultTapThresholdMs),
            ]
        )
    }

    func testSideSpecificRightOptionIgnoresLeftKey() {
        let trigger = HotkeyTrigger(kind: .modifier, modifierName: "option", keyCode: nil, modifierKeyCode: 61)
        let manager = HotkeyManager(trigger: trigger)

        // Left option pressed (keyCode 58) — should NOT trigger
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskAlternate],
                keyCode: 58,
                timestampMs: 1_000
            ),
            []
        )
    }

    func testSideSpecificRightOptionTapReleaseProducesTriggerReleased() {
        let trigger = HotkeyTrigger(kind: .modifier, modifierName: "option", keyCode: nil, modifierKeyCode: 61)
        let manager = HotkeyManager(trigger: trigger)

        // Press right option
        _ = manager.modifierFlagsChangedOutputsForTesting(
            flags: [.maskAlternate],
            keyCode: 61,
            timestampMs: 1_000
        )

        // Release right option (within tap threshold)
        let outputs = manager.modifierFlagsChangedOutputsForTesting(
            flags: [],
            keyCode: 61,
            timestampMs: 1_050
        )

        // Should produce triggerReleased outputs (showReadyForSecondTap for tap gesture)
        XCTAssertFalse(outputs.isEmpty, "Releasing the trigger should produce outputs")
    }

    func testSideSpecificOtherKeyInterruptsWhileHeld() {
        let trigger = HotkeyTrigger(kind: .modifier, modifierName: "option", keyCode: nil, modifierKeyCode: 61)
        let manager = HotkeyManager(trigger: trigger)

        // Press right option
        _ = manager.modifierFlagsChangedOutputsForTesting(
            flags: [.maskAlternate],
            keyCode: 61,
            timestampMs: 1_000
        )

        // Left option pressed while right is held — should interrupt bare-tap
        let outputs = manager.modifierFlagsChangedOutputsForTesting(
            flags: [.maskAlternate],
            keyCode: 58,
            timestampMs: 1_050
        )
        XCTAssertEqual(outputs, [.cancelStartupDebounce, .cancelHoldWindow])
    }

    func testGenericOptionStillTriggersOnEitherSide() {
        // Generic trigger (no modifierKeyCode) — both sides should work
        let manager = HotkeyManager(trigger: .option)

        // Left option pressed
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskAlternate],
                keyCode: 58,
                timestampMs: 1_000
            ),
            [
                .scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultStartupDebounceMs),
                .scheduleHoldWindow(milliseconds: FnKeyStateMachine.defaultTapThresholdMs),
            ]
        )
    }
}
