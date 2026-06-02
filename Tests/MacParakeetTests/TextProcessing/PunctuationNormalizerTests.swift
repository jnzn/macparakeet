import XCTest
@testable import MacParakeetCore

final class PunctuationNormalizerTests: XCTestCase {
    func testAlwaysConvertedCommands() {
        XCTAssertEqual(PunctuationNormalizer.normalize("is this right question mark"), "is this right?")
        XCTAssertEqual(PunctuationNormalizer.normalize("wow exclamation point"), "wow!")
        XCTAssertEqual(PunctuationNormalizer.normalize("wow exclamation mark"), "wow!")
        XCTAssertEqual(PunctuationNormalizer.normalize("one semicolon two"), "one; two")
    }
    func testPeriodAndCommaOnlyAtEnd() {
        XCTAssertEqual(PunctuationNormalizer.normalize("ship it today period"), "ship it today.")
        XCTAssertEqual(PunctuationNormalizer.normalize("add milk comma"), "add milk,")
        // Mid-text: untouched.
        XCTAssertEqual(PunctuationNormalizer.normalize("the trial period ended"), "the trial period ended")
        XCTAssertEqual(PunctuationNormalizer.normalize("comma separated values"), "comma separated values")
    }
    func testGuardedWordsStayWords() {
        XCTAssertEqual(PunctuationNormalizer.normalize("use a colon here"), "use a colon here")
        XCTAssertEqual(PunctuationNormalizer.normalize("start a new line"), "start a new line")
    }
    func testQuotes() {
        XCTAssertEqual(PunctuationNormalizer.normalize("she said open quote hello close quote"),
                       "she said \"hello\"")
    }
}
