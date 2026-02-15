import XCTest
@testable import MacParakeetCore

final class CommandHotkeyArbiterTests: XCTestCase {
    func testChordRisingEdgeStartsCommandModeWhenInactive() {
        let arbiter = CommandHotkeyArbiter()

        let decision = arbiter.process(
            isFnPressed: true,
            isControlPressed: true,
            isCommandModeActive: false,
            isCommandModeAvailable: true
        )

        XCTAssertEqual(decision.action, .startCommandMode)
        XCTAssertTrue(decision.suppressDictation)
    }

    func testChordRisingEdgeCancelsCommandModeWhenActive() {
        let arbiter = CommandHotkeyArbiter()

        let decision = arbiter.process(
            isFnPressed: true,
            isControlPressed: true,
            isCommandModeActive: true,
            isCommandModeAvailable: true
        )

        XCTAssertEqual(decision.action, .cancelCommandMode)
        XCTAssertTrue(decision.suppressDictation)
    }

    func testHeldChordDoesNotRetriggerAction() {
        let arbiter = CommandHotkeyArbiter()

        _ = arbiter.process(
            isFnPressed: true,
            isControlPressed: true,
            isCommandModeActive: false,
            isCommandModeAvailable: true
        )

        let second = arbiter.process(
            isFnPressed: true,
            isControlPressed: true,
            isCommandModeActive: false,
            isCommandModeAvailable: true
        )

        XCTAssertEqual(second.action, .none)
        XCTAssertTrue(second.suppressDictation)
    }

    func testSuppressesUntilChordReleased() {
        let arbiter = CommandHotkeyArbiter()

        _ = arbiter.process(
            isFnPressed: true,
            isControlPressed: true,
            isCommandModeActive: false,
            isCommandModeAvailable: true
        )

        // Fn still held after control release; keep suppressing.
        let partialRelease = arbiter.process(
            isFnPressed: true,
            isControlPressed: false,
            isCommandModeActive: false,
            isCommandModeAvailable: true
        )
        XCTAssertEqual(partialRelease.action, .none)
        XCTAssertTrue(partialRelease.suppressDictation)

        // Fully released; suppression ends.
        let fullRelease = arbiter.process(
            isFnPressed: false,
            isControlPressed: false,
            isCommandModeActive: false,
            isCommandModeAvailable: true
        )
        XCTAssertEqual(fullRelease.action, .none)
        XCTAssertTrue(fullRelease.suppressDictation)

        let normalInput = arbiter.process(
            isFnPressed: true,
            isControlPressed: false,
            isCommandModeActive: false,
            isCommandModeAvailable: true
        )
        XCTAssertEqual(normalInput.action, .none)
        XCTAssertFalse(normalInput.suppressDictation)
    }

    func testDoesNotSuppressWhenCommandModeUnavailable() {
        let arbiter = CommandHotkeyArbiter()

        let decision = arbiter.process(
            isFnPressed: true,
            isControlPressed: true,
            isCommandModeActive: false,
            isCommandModeAvailable: false
        )

        XCTAssertEqual(decision.action, .none)
        XCTAssertFalse(decision.suppressDictation)
    }
}
