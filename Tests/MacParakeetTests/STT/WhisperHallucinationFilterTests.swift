import XCTest
@testable import MacParakeetCore

final class WhisperHallucinationFilterTests: XCTestCase {

    // MARK: - Text filtering

    func testPureRussianHallucinationIsStripped() {
        let (text, words) = WhisperEngine.filterHallucinations(
            text: "Продолжение следует",
            words: []
        )
        XCTAssertEqual(text, "")
        XCTAssertTrue(words.isEmpty)
    }

    func testRussianHallucinationWithLeadingWhitespaceIsStripped() {
        let (text, _) = WhisperEngine.filterHallucinations(
            text: "  Продолжение следует  ",
            words: []
        )
        XCTAssertEqual(text, "")
    }

    func testRussianCreditIsStripped() {
        let (text, _) = WhisperEngine.filterHallucinations(
            text: "Субтитры сделал DimaTorzok",
            words: []
        )
        XCTAssertEqual(text, "")
    }

    func testEnglishHallucinationIsStripped() {
        let (text, _) = WhisperEngine.filterHallucinations(
            text: "Thanks for watching",
            words: []
        )
        XCTAssertEqual(text, "")
    }

    func testHallucinationPrefixIsStrippedLeavingRealSpeech() {
        let (text, _) = WhisperEngine.filterHallucinations(
            text: "Продолжение следует Good morning everyone.",
            words: []
        )
        XCTAssertEqual(text, "Good morning everyone.")
    }

    func testLegitimateTextPassesThrough() {
        let input = "The quarterly results look strong."
        let (text, _) = WhisperEngine.filterHallucinations(text: input, words: [])
        XCTAssertEqual(text, input)
    }

    func testEmptyInputReturnsEmpty() {
        let (text, words) = WhisperEngine.filterHallucinations(text: "", words: [])
        XCTAssertEqual(text, "")
        XCTAssertTrue(words.isEmpty)
    }

    // MARK: - Word filtering

    func testHallucinationWordsAreRemovedWhenTextIsEmpty() {
        let hallucinationWords = [
            makeWord("Продолжение", start: 0, end: 500),
            makeWord("следует", start: 500, end: 1000),
        ]
        let (text, words) = WhisperEngine.filterHallucinations(
            text: "Продолжение следует",
            words: hallucinationWords
        )
        XCTAssertEqual(text, "")
        XCTAssertTrue(words.isEmpty)
    }

    func testHallucinationWordsAreRemovedWhenRealSpeechRemains() {
        let allWords = [
            makeWord("Продолжение", start: 0, end: 500),
            makeWord("следует", start: 500, end: 1000),
            makeWord("Hello", start: 1000, end: 1300),
            makeWord("world", start: 1300, end: 1600),
        ]
        let (text, words) = WhisperEngine.filterHallucinations(
            text: "Продолжение следует Hello world",
            words: allWords
        )
        XCTAssertEqual(text, "Hello world")
        XCTAssertEqual(words.count, 2)
        XCTAssertEqual(words.map(\.word), ["Hello", "world"])
    }

    func testLegitimateWordsArePreserved() {
        let input = [
            makeWord("Good", start: 0, end: 300),
            makeWord("morning", start: 300, end: 700),
        ]
        let (_, words) = WhisperEngine.filterHallucinations(
            text: "Good morning",
            words: input
        )
        XCTAssertEqual(words.count, 2)
    }

    // MARK: - Phrase coverage

    func testAllKnownPhrasesAreStripped() {
        for phrase in WhisperEngine.knownHallucinationPhrases {
            let (text, _) = WhisperEngine.filterHallucinations(text: phrase, words: [])
            XCTAssertEqual(text, "", "phrase not stripped: \(phrase)")
        }
    }

    // MARK: - Helpers

    private func makeWord(_ word: String, start: Int, end: Int) -> TimestampedWord {
        TimestampedWord(word: word, startMs: start, endMs: end, confidence: 0.9)
    }
}
