import XCTest
@testable import MacParakeetCore

final class MeetingTranscriptNoiseFilterTests: XCTestCase {
    func testFinalizeDropsFillerOnlyMicrophoneRuns() {
        let finalized = MeetingTranscriptFinalizer.finalize(sourceTranscripts: [
            .init(
                source: .microphone,
                result: STTResult(
                    text: "Uh uh",
                    words: [
                        TimestampedWord(word: "Uh", startMs: 0, endMs: 120, confidence: 0.92),
                        TimestampedWord(word: "uh", startMs: 180, endMs: 300, confidence: 0.90),
                    ]
                ),
                startOffsetMs: 0
            ),
            .init(
                source: .system,
                result: STTResult(
                    text: "lecture content",
                    words: [
                        TimestampedWord(word: "lecture", startMs: 0, endMs: 240, confidence: 0.95),
                        TimestampedWord(word: "content", startMs: 280, endMs: 560, confidence: 0.95),
                    ]
                ),
                startOffsetMs: 0
            ),
        ])

        XCTAssertEqual(finalized.words.map(\.word), ["lecture", "content"])
        XCTAssertEqual(finalized.words.map(\.speakerId), ["system", "system"])
        XCTAssertEqual(finalized.speakers, [
            SpeakerInfo(id: "system", label: "Others"),
        ])
        XCTAssertEqual(finalized.rawTranscript, "lecture content")
    }

    func testFinalizeDropsLowConfidenceMicDuplicateOfSystemRun() {
        let finalized = MeetingTranscriptFinalizer.finalize(sourceTranscripts: [
            .init(
                source: .microphone,
                result: STTResult(
                    text: "account information",
                    words: [
                        TimestampedWord(word: "account", startMs: 80, endMs: 220, confidence: 0.48),
                        TimestampedWord(word: "information", startMs: 240, endMs: 480, confidence: 0.50),
                    ]
                ),
                startOffsetMs: 0
            ),
            .init(
                source: .system,
                result: STTResult(
                    text: "account information",
                    words: [
                        TimestampedWord(word: "account", startMs: 0, endMs: 140, confidence: 0.93),
                        TimestampedWord(word: "information", startMs: 160, endMs: 400, confidence: 0.93),
                    ]
                ),
                startOffsetMs: 0
            ),
        ])

        XCTAssertEqual(finalized.words.map(\.speakerId), ["system", "system"])
        XCTAssertEqual(finalized.rawTranscript, "account information")
    }

    // A loud, clean MacBook-speaker echo is transcribed at HIGH confidence, so
    // the old confidence gate preserved it and the far-end appeared twice
    // ("Can Can you you hear hear me me"). An exact token-sequence match that
    // overlaps a system run in time is an echo regardless of confidence, so the
    // mic run is dropped and only the clean system copy remains.
    func testFinalizeDropsHighConfidenceEchoMatchingSystemRun() {
        let finalized = MeetingTranscriptFinalizer.finalize(sourceTranscripts: [
            .init(
                source: .microphone,
                result: STTResult(
                    text: "Can you hear me",
                    words: [
                        TimestampedWord(word: "Can", startMs: 120, endMs: 220, confidence: 0.90),
                        TimestampedWord(word: "you", startMs: 240, endMs: 320, confidence: 0.90),
                        TimestampedWord(word: "hear", startMs: 340, endMs: 450, confidence: 0.90),
                        TimestampedWord(word: "me", startMs: 470, endMs: 540, confidence: 0.90),
                    ]
                ),
                startOffsetMs: 0
            ),
            .init(
                source: .system,
                result: STTResult(
                    text: "Can you hear me",
                    words: [
                        TimestampedWord(word: "Can", startMs: 0, endMs: 100, confidence: 0.90),
                        TimestampedWord(word: "you", startMs: 120, endMs: 200, confidence: 0.90),
                        TimestampedWord(word: "hear", startMs: 220, endMs: 330, confidence: 0.90),
                        TimestampedWord(word: "me", startMs: 350, endMs: 420, confidence: 0.90),
                    ]
                ),
                startOffsetMs: 0
            ),
        ])

        XCTAssertEqual(finalized.words.map(\.speakerId), ["system", "system", "system", "system"])
        XCTAssertEqual(finalized.rawTranscript, "Can you hear me")
    }

    // Genuine double-talk: the local speaker says something DIFFERENT while the
    // far-end talks. Those mic words do not match the system run, so they must
    // be preserved (we only strip exact echoes, not all overlapping speech).
    func testFinalizePreservesOverlappingMicSpeechThatDiffersFromSystem() {
        let finalized = MeetingTranscriptFinalizer.finalize(sourceTranscripts: [
            .init(
                source: .microphone,
                result: STTResult(
                    text: "yes exactly",
                    words: [
                        TimestampedWord(word: "yes", startMs: 120, endMs: 260, confidence: 0.90),
                        TimestampedWord(word: "exactly", startMs: 300, endMs: 540, confidence: 0.90),
                    ]
                ),
                startOffsetMs: 0
            ),
            .init(
                source: .system,
                result: STTResult(
                    text: "Can you hear me",
                    words: [
                        TimestampedWord(word: "Can", startMs: 0, endMs: 100, confidence: 0.90),
                        TimestampedWord(word: "you", startMs: 120, endMs: 200, confidence: 0.90),
                        TimestampedWord(word: "hear", startMs: 220, endMs: 330, confidence: 0.90),
                        TimestampedWord(word: "me", startMs: 350, endMs: 420, confidence: 0.90),
                    ]
                ),
                startOffsetMs: 0
            ),
        ])

        XCTAssertEqual(Set(finalized.words.map(\.word)), ["yes", "exactly", "Can", "you", "hear", "me"])
        XCTAssertTrue(finalized.words.contains { $0.word == "yes" && $0.speakerId == "microphone" })
        XCTAssertTrue(finalized.words.contains { $0.word == "exactly" && $0.speakerId == "microphone" })
    }
}
