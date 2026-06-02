import XCTest
@testable import MacParakeetCore

final class CurrencyNormalizerTests: XCTestCase {
    func testDollars() {
        XCTAssertEqual(CurrencyNormalizer.normalize("25 dollars"), "$25")
        XCTAssertEqual(CurrencyNormalizer.normalize("fifty bucks"), "fifty bucks") // words → untouched (digits required)
        XCTAssertEqual(CurrencyNormalizer.normalize("50 bucks"), "$50")
    }
    func testDollarsAndCents() {
        XCTAssertEqual(CurrencyNormalizer.normalize("3 dollars and 50 cents"), "$3.50")
        XCTAssertEqual(CurrencyNormalizer.normalize("3 dollars and 5 cents"), "$3.05")
    }
    func testScaleWords() {
        XCTAssertEqual(CurrencyNormalizer.normalize("1.5 million dollars"), "$1.5 million")
    }
    func testOtherCurrencies() {
        XCTAssertEqual(CurrencyNormalizer.normalize("20 euros"), "€20")
        XCTAssertEqual(CurrencyNormalizer.normalize("5000 won"), "₩5,000")
        XCTAssertEqual(CurrencyNormalizer.normalize("500 yen"), "¥500")
    }
    func testPoundsExcluded() {
        XCTAssertEqual(CurrencyNormalizer.normalize("ten pounds"), "ten pounds")
        XCTAssertEqual(CurrencyNormalizer.normalize("10 pounds"), "10 pounds")
    }
    func testInSentence() {
        XCTAssertEqual(CurrencyNormalizer.normalize("send 25 dollars to John"), "send $25 to John")
    }
}
