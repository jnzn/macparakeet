import XCTest
@testable import MacParakeetCore

final class YearNormalizerTests: XCTestCase {
    func testTwoPartYears() {
        XCTAssertEqual(YearNormalizer.normalize("twenty twenty six"), "2026")
        XCTAssertEqual(YearNormalizer.normalize("nineteen ninety nine"), "1999")
        XCTAssertEqual(YearNormalizer.normalize("twenty twenty"), "2020")
    }
    func testYearInSentence() {
        XCTAssertEqual(YearNormalizer.normalize("back in twenty twenty four"), "back in 2024")
    }
    func testNonYearsPassThrough() {
        XCTAssertEqual(YearNormalizer.normalize("nineteen people"), "nineteen people")
        XCTAssertEqual(YearNormalizer.normalize("twenty cats"), "twenty cats")
        XCTAssertEqual(YearNormalizer.normalize("hello world"), "hello world")
    }
}
