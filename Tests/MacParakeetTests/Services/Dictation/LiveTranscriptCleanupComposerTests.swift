import XCTest
@testable import MacParakeetCore

final class LiveTranscriptCleanupComposerTests: XCTestCase {
    func testPassesRawThroughBeforeAnyCleanup() {
        XCTAssertEqual(LiveTranscriptCleanupComposer().compose("um hello there"), "um hello there")
    }

    func testAppendsRawTailAfterCleanedPrefix() {
        var composer = LiveTranscriptCleanupComposer()
        composer.record(cleaned: "Hello there.", forRaw: "um hello there")
        XCTAssertEqual(composer.compose("um hello there"), "Hello there.")
        XCTAssertEqual(composer.compose("um hello there how are you"), "Hello there. how are you")
    }

    func testFallsBackToWordCountWhenRecognizerRevisesEarlierWords() {
        var composer = LiveTranscriptCleanupComposer()
        composer.record(cleaned: "Hello there.", forRaw: "um hello there")
        XCTAssertEqual(composer.compose("uh hello their friend"), "Hello there. friend")
        XCTAssertEqual(composer.compose("uh hello"), "Hello there.")
    }

    func testResetReturnsToRawText() {
        var composer = LiveTranscriptCleanupComposer()
        composer.record(cleaned: "Hello.", forRaw: "hello")
        composer.reset()
        XCTAssertEqual(composer.compose("hello world"), "hello world")
    }
}
