import XCTest
@testable import MacParakeetCore

final class MeetingTranscriptAssemblerTests: XCTestCase {
    func testApplyDeduplicatesOverlapForSingleSource() {
        var assembler = MeetingTranscriptAssembler()

        let firstChunk = AudioChunker.AudioChunk(samples: [0], startMs: 0, endMs: 5_000)
        let firstResult = STTResult(text: "Hello team", words: [
            TimestampedWord(word: "Hello", startMs: 100, endMs: 400, confidence: 0.9),
            TimestampedWord(word: "team", startMs: 4_200, endMs: 4_600, confidence: 0.9),
        ])
        _ = assembler.apply(result: firstResult, chunk: firstChunk, source: .microphone)

        let secondChunk = AudioChunker.AudioChunk(samples: [0], startMs: 4_000, endMs: 9_000)
        let secondResult = STTResult(text: "team again", words: [
            TimestampedWord(word: "team", startMs: 100, endMs: 500, confidence: 0.9),
            TimestampedWord(word: "again", startMs: 700, endMs: 1_000, confidence: 0.9),
        ])
        let update = assembler.apply(result: secondResult, chunk: secondChunk, source: .microphone)

        XCTAssertEqual(update.words.map(\.word), ["Hello", "team", "again"])
        XCTAssertEqual(update.words.map(\.speakerId), ["microphone", "microphone", "microphone"])
    }

    func testFinalizedTranscriptBuildsSpeakerMetadataAcrossSources() {
        var assembler = MeetingTranscriptAssembler()

        _ = assembler.apply(
            result: STTResult(text: "Hello there", words: [
                TimestampedWord(word: "Hello", startMs: 0, endMs: 300, confidence: 0.9),
                TimestampedWord(word: "there", startMs: 320, endMs: 650, confidence: 0.9),
            ]),
            chunk: AudioChunker.AudioChunk(samples: [0], startMs: 0, endMs: 5_000),
            source: .microphone
        )

        _ = assembler.apply(
            result: STTResult(text: "Sounds good", words: [
                TimestampedWord(word: "Sounds", startMs: 900, endMs: 1_200, confidence: 0.9),
                TimestampedWord(word: "good", startMs: 1_250, endMs: 1_500, confidence: 0.9),
            ]),
            chunk: AudioChunker.AudioChunk(samples: [0], startMs: 0, endMs: 5_000),
            source: .system
        )

        let transcript = assembler.finalizedTranscript(durationMs: 1_500)

        XCTAssertEqual(transcript?.speakerCount, 2)
        XCTAssertEqual(transcript?.speakers, [
            SpeakerInfo(id: "microphone", label: "Me"),
            SpeakerInfo(id: "system", label: "Others"),
        ])
        XCTAssertEqual(transcript?.words.map(\.word), ["Hello", "there", "Sounds", "good"])
        XCTAssertEqual(transcript?.diarizationSegments.count, 2)
        XCTAssertEqual(transcript?.rawTranscript, "Hello there Sounds good")
    }

    func testDropsMicrophoneEchoOfSystemSpeech() {
        var assembler = MeetingTranscriptAssembler()

        // Far-end ("Others") speech captured cleanly on the system stream.
        _ = assembler.apply(
            result: STTResult(text: "Hey Jensen", words: [
                TimestampedWord(word: "Hey", startMs: 1_000, endMs: 1_200, confidence: 0.92),
                TimestampedWord(word: "Jensen", startMs: 1_300, endMs: 1_700, confidence: 0.92),
            ]),
            chunk: AudioChunker.AudioChunk(samples: [0], startMs: 0, endMs: 5_000),
            source: .system
        )

        // The same far-end speech leaks through the speakers into the raw mic
        // ~120 ms later (acoustic echo). It must not appear a second time.
        _ = assembler.apply(
            result: STTResult(text: "Hey Jensen", words: [
                TimestampedWord(word: "Hey", startMs: 1_120, endMs: 1_320, confidence: 0.55),
                TimestampedWord(word: "Jensen,", startMs: 1_420, endMs: 1_820, confidence: 0.55),
            ]),
            chunk: AudioChunker.AudioChunk(samples: [0], startMs: 0, endMs: 5_000),
            source: .microphone
        )

        let transcript = assembler.finalizedTranscript(durationMs: 2_000)

        // Only the clean system copy survives; the mic echo is dropped.
        XCTAssertEqual(transcript?.words.map(\.word), ["Hey", "Jensen"])
        XCTAssertEqual(transcript?.words.map(\.speakerId), ["system", "system"])
        XCTAssertEqual(transcript?.rawTranscript, "Hey Jensen")
        XCTAssertEqual(transcript?.speakerCount, 1)
    }

    func testKeepsMicrophoneWordsWithoutMatchingSystemEcho() {
        var assembler = MeetingTranscriptAssembler()

        _ = assembler.apply(
            result: STTResult(text: "Hey Jensen", words: [
                TimestampedWord(word: "Hey", startMs: 1_000, endMs: 1_200, confidence: 0.92),
                TimestampedWord(word: "Jensen", startMs: 1_300, endMs: 1_700, confidence: 0.92),
            ]),
            chunk: AudioChunker.AudioChunk(samples: [0], startMs: 0, endMs: 5_000),
            source: .system
        )

        // Local user genuinely says "Hey" again much later — not an echo of the
        // earlier system word, so it must be preserved.
        _ = assembler.apply(
            result: STTResult(text: "Hey there", words: [
                TimestampedWord(word: "Hey", startMs: 4_000, endMs: 4_200, confidence: 0.9),
                TimestampedWord(word: "there", startMs: 4_300, endMs: 4_600, confidence: 0.9),
            ]),
            chunk: AudioChunker.AudioChunk(samples: [0], startMs: 0, endMs: 5_000),
            source: .microphone
        )

        let transcript = assembler.finalizedTranscript(durationMs: 5_000)

        XCTAssertEqual(transcript?.words.map(\.word), ["Hey", "Jensen", "Hey", "there"])
        XCTAssertEqual(transcript?.words.map(\.speakerId), ["system", "system", "microphone", "microphone"])
    }
}
