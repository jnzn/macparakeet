import XCTest
@testable import MacParakeet

@MainActor
final class MerkabaPillIconViewTests: XCTestCase {
    /// Starting a new recording while the "flying off" stop transition is
    /// still in flight (e.g. Metatron already showing from a fast back-to-back
    /// recording) must cancel the transition and show the parakeet as
    /// normal — never strand the mark mid-exit or under the Metatron bloom.
    func testRecordingReentryCancelsInFlightLeavingTransition() {
        let view = MerkabaPillIconView(frame: NSRect(x: 0, y: 0, width: 30, height: 74))
        view.layoutSubtreeIfNeeded()

        view.playCompletion(reduceMotion: false) {}
        view.showMetatron(animated: true)
        XCTAssertTrue(view.testHook_isLeaving)

        view.update(isAnimating: true, audioLevel: 0)

        XCTAssertFalse(view.testHook_isLeaving)
        XCTAssertTrue(view.testHook_isAnimating)
    }

    func testRecordingReentryCancelsLeavingTransitionBeforeMetatron() {
        let view = MerkabaPillIconView(frame: NSRect(x: 0, y: 0, width: 30, height: 74))
        view.layoutSubtreeIfNeeded()

        view.playCompletion(reduceMotion: false) {}
        XCTAssertTrue(view.testHook_isLeaving)

        view.update(isAnimating: true, audioLevel: 0)

        XCTAssertFalse(view.testHook_isLeaving)
        XCTAssertTrue(view.testHook_isAnimating)
    }

    func testPauseStopsAnimatingWithoutLeaving() {
        let view = MerkabaPillIconView(frame: NSRect(x: 0, y: 0, width: 30, height: 74))
        view.layoutSubtreeIfNeeded()

        view.update(isAnimating: true, audioLevel: 0)
        XCTAssertTrue(view.testHook_isAnimating)

        view.update(isAnimating: false, audioLevel: 0)

        XCTAssertFalse(view.testHook_isAnimating)
        XCTAssertFalse(view.testHook_isLeaving)
    }

    func testPlayCompletionMarksLeavingUntilFinished() async {
        let view = MerkabaPillIconView(frame: NSRect(x: 0, y: 0, width: 30, height: 74))
        view.layoutSubtreeIfNeeded()
        view.update(isAnimating: true, audioLevel: 0)

        let finished = expectation(description: "completion callback fires")
        view.playCompletion(reduceMotion: true) { finished.fulfill() }

        XCTAssertTrue(view.testHook_isLeaving)
        await fulfillment(of: [finished], timeout: 1)
    }
}
