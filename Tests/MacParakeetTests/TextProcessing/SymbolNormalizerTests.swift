import XCTest
@testable import MacParakeetCore

final class SymbolNormalizerTests: XCTestCase {
    func testPrefixSymbolsAttachToNextWord() {
        XCTAssertEqual(SymbolNormalizer.normalize("hashtag standup"), "#standup")
        XCTAssertEqual(SymbolNormalizer.normalize("pound sign one"), "#one")
    }
    func testStandaloneSymbols() {
        XCTAssertEqual(SymbolNormalizer.normalize("at sign"), "@")
        XCTAssertEqual(SymbolNormalizer.normalize("ampersand"), "&")
        XCTAssertEqual(SymbolNormalizer.normalize("asterisk"), "*")
        XCTAssertEqual(SymbolNormalizer.normalize("underscore"), "_")
        XCTAssertEqual(SymbolNormalizer.normalize("tilde"), "~")
        XCTAssertEqual(SymbolNormalizer.normalize("backslash"), "\\")
        XCTAssertEqual(SymbolNormalizer.normalize("dollar sign"), "$")
        XCTAssertEqual(SymbolNormalizer.normalize("percent sign"), "%")
    }
    func testHyphenJoinsWords() {
        XCTAssertEqual(SymbolNormalizer.normalize("self hyphen aware"), "self-aware")
    }
    func testAmbiguousWordsAreNotConverted() {
        XCTAssertEqual(SymbolNormalizer.normalize("a dash of salt"), "a dash of salt")
        XCTAssertEqual(SymbolNormalizer.normalize("that's a plus"), "that's a plus")
        XCTAssertEqual(SymbolNormalizer.normalize("the pipe burst"), "the pipe burst")
    }
}
