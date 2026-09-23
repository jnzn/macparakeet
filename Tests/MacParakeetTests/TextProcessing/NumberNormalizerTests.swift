import XCTest

@testable import MacParakeetCore

final class NumberNormalizerTests: XCTestCase {
    private func check(
        _ input: String, _ expected: String,
        file: StaticString = #file, line: UInt = #line
    ) {
        XCTAssertEqual(NumberNormalizer.normalize(input), expected, "input: \"\(input)\"", file: file, line: line)
    }

    func test_simpleCardinals() {
        // Bare unit digits (zero-nine) read as words, not digits, when
        // they're not part of a compound, decimal, or spoken digit sequence.
        check("zero", "zero")
        check("five", "five")
        // Teens/tens don't carry that ambiguity and always convert.
        check("nineteen", "19")
        check("twenty", "20")
    }

    func test_compoundTensUnits() {
        check("twenty five", "25")
        check("Twenty-five", "25")   // case + hyphen
        check("ninety nine", "99")
    }

    func test_hundredsAndThousands() {
        check("three hundred forty two", "342")
        check("a hundred", "100")
        check("one hundred thousand", "100000")
        check("two thousand twenty four", "2024")
        check("fifteen hundred", "1500")
    }

    func test_andConnective() {
        check("three hundred and five", "305")
    }

    func test_decimals() {
        check("three point five", "3.5")
        check("three point one four", "3.14")
    }

    func test_nonComposableRunsStaySeparate() {
        check("one two three", "1 2 3")   // units can't chain
        check("seven seven", "7 7")
        check("thirty forty", "30 40")    // tens can't chain
    }

    func test_embeddedInProse() {
        check("I need twenty five dollars", "I need 25 dollars")
        check("two reasons", "two reasons")          // isolated unit stays a word
        check("call me at four", "call me at four")
    }

    func test_isolatedUnitsStayWords() {
        // "one" doubles heavily as an indefinite pronoun/determiner; the
        // other units get the same treatment for consistency — a lone digit
        // floating in prose almost never reads better as a numeral.
        check("the one thing", "the one thing")
        check("that one", "that one")
        check("just one", "just one")
        check("one time", "one time")
        check("no one", "no one")
        check("the answer is zero", "the answer is zero")
        check("she said no, not three", "she said no, not three")
        check("give me a minute, just one", "give me a minute, just one")
    }

    func test_bareUnitConvertsBeforeCurrencyFractionOrClockAnchor() {
        // A lone unit reads unambiguously as a number when it precedes a
        // downstream normalizer's anchor noun, unlike ordinary prose
        // ("that one", "call me at four") — see test_isolatedUnitsStayWords.
        check("three dollars", "3 dollars")
        check("one dollar", "1 dollar")
        check("five cents", "5 cents")
        check("two euros", "2 euros")
        check("one won", "1 won")
        check("one yen", "1 yen")
        check("one percent", "1 percent")
        check("one half", "1 half")
        check("three quarters", "3 quarters")
        check("nine a m", "9 a m")
        check("nine p m", "9 p m")
        // "a" alone (not followed by "m") is still just the article.
        check("give me a minute", "give me a minute")
    }

    func test_passthrough() {
        check("no numbers here", "no numbers here")
        check("", "")
    }

    func test_punctuationAdjacency() {
        check("twenty five.", "25.")
        check("thirty, forty", "30, 40")
    }
}
