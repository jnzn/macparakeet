import XCTest
@testable import MacParakeetCore

final class MeetingMicrophoneEchoClassifierTests: XCTestCase {
    private func mic(_ word: String, _ startMs: Int) -> WordTimestamp {
        WordTimestamp(word: word, startMs: startMs, endMs: startMs + 150, confidence: 0.55, speakerId: "microphone")
    }

    private func sys(_ word: String, _ startMs: Int) -> WordTimestamp {
        WordTimestamp(word: word, startMs: startMs, endMs: startMs + 150, confidence: 0.95, speakerId: "system")
    }

    // A mic run that mostly tracks an overlapping far-end run is echo in full —
    // including the word the degraded echo transcribed differently ("team" came
    // through the speakers and back as "Tim").
    func testDropsDivergentEchoRunInFull() {
        let microphone = [mic("Hey", 140), mic("Tim", 260), mic("good", 380), mic("morning", 490)]
        let system = [sys("Hey", 0), sys("team", 120), sys("good", 240), sys("morning", 350)]

        let indices = MeetingMicrophoneEchoClassifier.echoIndices(
            microphoneWords: microphone,
            systemWords: system
        )

        XCTAssertEqual(indices, [0, 1, 2, 3])
    }

    // Genuinely distinct local speech that merely overlaps the far-end in time
    // is preserved — it does not track the far-end's words.
    func testKeepsDistinctLocalRunThatOverlapsFarEnd() {
        let microphone = [mic("yes", 120), mic("exactly", 300)]
        let system = [sys("Can", 0), sys("you", 120), sys("hear", 220), sys("me", 350)]

        let indices = MeetingMicrophoneEchoClassifier.echoIndices(
            microphoneWords: microphone,
            systemWords: system
        )

        XCTAssertTrue(indices.isEmpty)
    }

    // Short common words must not fuzzy-match (they collide too easily); only
    // tokens that are both five-plus characters tolerate a length-scaled
    // edit-distance budget, which is where degraded echoes actually drift.
    func testShortTokensRequireExactMatchButLongTokensTolerateDrift() {
        XCTAssertFalse(MeetingMicrophoneEchoClassifier.tokensMatch("yes", "you"))
        XCTAssertFalse(MeetingMicrophoneEchoClassifier.tokensMatch("the", "them"))
        XCTAssertFalse(MeetingMicrophoneEchoClassifier.tokensMatch("what", "that"))
        XCTAssertTrue(MeetingMicrophoneEchoClassifier.tokensMatch("replying", "deploying"))
        XCTAssertTrue(MeetingMicrophoneEchoClassifier.tokensMatch("morning", "mornin"))
    }

    func testNormalizedTokenLowercasesAndStripsEdgePunctuation() {
        XCTAssertEqual(MeetingMicrophoneEchoClassifier.normalizedToken("Greg,"), "greg")
        XCTAssertEqual(MeetingMicrophoneEchoClassifier.normalizedToken("Jensen's"), "jensen's")
        XCTAssertNil(MeetingMicrophoneEchoClassifier.normalizedToken("—"))
    }

    // Floor below the run bar: a single word that exactly echoes the far-end is
    // dropped even when its surrounding run is mostly local — the rapid
    // back-and-forth tail of a call where one far-end word leaks mid-sentence.
    func testDropsIsolatedExactEchoWordInsideLocalRun() {
        let microphone = [
            mic("so", 1_000), mic("the", 1_200), mic("plan", 1_400), mic("works", 1_600), mic("okay", 1_800),
        ]
        let system = [sys("okay", 1_750)]

        let indices = MeetingMicrophoneEchoClassifier.echoIndices(
            microphoneWords: microphone,
            systemWords: system
        )

        XCTAssertEqual(indices, [4])
    }
}
