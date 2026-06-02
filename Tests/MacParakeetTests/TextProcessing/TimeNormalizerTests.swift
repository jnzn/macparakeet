import XCTest
@testable import MacParakeetCore

final class TimeNormalizerTests: XCTestCase {
    func testTimesWithAnchor() {
        XCTAssertEqual(TimeNormalizer.normalize("3 30 pm"), "3:30 PM")
        XCTAssertEqual(TimeNormalizer.normalize("9 am"), "9:00 AM")
        XCTAssertEqual(TimeNormalizer.normalize("9 a m"), "9:00 AM")
        XCTAssertEqual(TimeNormalizer.normalize("12 15 pm"), "12:15 PM")
        XCTAssertEqual(TimeNormalizer.normalize("3 o'clock"), "3:00")
        XCTAssertEqual(TimeNormalizer.normalize("3 oclock"), "3:00")
    }
    func testNoAnchorNoConversion() {
        XCTAssertEqual(TimeNormalizer.normalize("there were 3 30 year olds"), "there were 3 30 year olds")
        XCTAssertEqual(TimeNormalizer.normalize("3 30"), "3 30")
    }
}
