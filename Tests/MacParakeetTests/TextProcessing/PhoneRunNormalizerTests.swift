import XCTest
@testable import MacParakeetCore

final class PhoneRunNormalizerTests: XCTestCase {
    func testSevenDigitRun() {
        XCTAssertEqual(PhoneRunNormalizer.normalize("5 5 5 1 2 1 2"), "555-1212")
    }
    func testTenDigitRun() {
        XCTAssertEqual(PhoneRunNormalizer.normalize("6 1 7 5 5 5 1 2 1 2"), "617-555-1212")
    }
    func testShortRunsUntouched() {
        XCTAssertEqual(PhoneRunNormalizer.normalize("1 2 3"), "1 2 3")
        XCTAssertEqual(PhoneRunNormalizer.normalize("4 5 6 7"), "4 5 6 7")
    }
    func testInSentence() {
        XCTAssertEqual(PhoneRunNormalizer.normalize("call me at 5 5 5 1 2 1 2 tomorrow"),
                       "call me at 555-1212 tomorrow")
    }
}
