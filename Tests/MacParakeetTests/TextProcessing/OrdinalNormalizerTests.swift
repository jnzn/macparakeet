import XCTest
@testable import MacParakeetCore

final class OrdinalNormalizerTests: XCTestCase {
    func testCompoundOrdinalsConvert() {
        XCTAssertEqual(OrdinalNormalizer.normalize("the twenty fifth item"), "the 25th item")
        XCTAssertEqual(OrdinalNormalizer.normalize("their thirty third anniversary"), "their 33rd anniversary")
        XCTAssertEqual(OrdinalNormalizer.normalize("twenty first"), "21st")
    }
    func testTeensAndTensOrdinalsConvert() {
        XCTAssertEqual(OrdinalNormalizer.normalize("the twelfth floor"), "the 12th floor")
        XCTAssertEqual(OrdinalNormalizer.normalize("the twentieth century"), "the 20th century")
    }
    func testStandaloneSimpleOrdinalsAreGuarded() {
        XCTAssertEqual(OrdinalNormalizer.normalize("first of all"), "first of all")
        XCTAssertEqual(OrdinalNormalizer.normalize("wait a second"), "wait a second")
        XCTAssertEqual(OrdinalNormalizer.normalize("the third option"), "the third option")
    }
    func testSuffixes() {
        XCTAssertEqual(OrdinalNormalizer.suffix(for: 21), "st")
        XCTAssertEqual(OrdinalNormalizer.suffix(for: 22), "nd")
        XCTAssertEqual(OrdinalNormalizer.suffix(for: 23), "rd")
        XCTAssertEqual(OrdinalNormalizer.suffix(for: 25), "th")
        XCTAssertEqual(OrdinalNormalizer.suffix(for: 11), "th")
        XCTAssertEqual(OrdinalNormalizer.suffix(for: 12), "th")
        XCTAssertEqual(OrdinalNormalizer.suffix(for: 13), "th")
    }
}
