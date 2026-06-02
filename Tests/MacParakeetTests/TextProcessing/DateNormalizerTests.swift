import XCTest
@testable import MacParakeetCore

final class DateNormalizerTests: XCTestCase {
    func testOwnerSuffixRule_StNdRdKept_ThDropped() {
        XCTAssertEqual(DateNormalizer.normalize("june first"), "June 1st")
        XCTAssertEqual(DateNormalizer.normalize("june second"), "June 2nd")
        XCTAssertEqual(DateNormalizer.normalize("june third"), "June 3rd")
        XCTAssertEqual(DateNormalizer.normalize("june fourth"), "June 4")
        XCTAssertEqual(DateNormalizer.normalize("june fifth"), "June 5")
    }
    func testCompoundDays() {
        // Input has digits already (OrdinalNormalizer ran first).
        XCTAssertEqual(DateNormalizer.normalize("june 21st"), "June 21st")
        XCTAssertEqual(DateNormalizer.normalize("june 25th"), "June 25")
    }
    func testCardinalDay() {
        XCTAssertEqual(DateNormalizer.normalize("june 2"), "June 2nd")
    }
    func testWithYear() {
        XCTAssertEqual(DateNormalizer.normalize("june second 2026"), "June 2nd, 2026")
    }
    func testTheXOfMonth() {
        XCTAssertEqual(DateNormalizer.normalize("the fifth of may"), "May 5")
        XCTAssertEqual(DateNormalizer.normalize("the third of may"), "May 3rd")
    }
    func testISOTrigger() {
        XCTAssertEqual(DateNormalizer.normalize("2026 hyphen june hyphen second"), "2026-06-02")
        XCTAssertEqual(DateNormalizer.normalize("2026 dash june dash second"), "2026-06-02")
        XCTAssertEqual(DateNormalizer.normalize("2026 dash december dash 31st"), "2026-12-31")
    }
    func testMonthAloneUntouched() {
        XCTAssertEqual(DateNormalizer.normalize("june is busy"), "june is busy")
        XCTAssertEqual(DateNormalizer.normalize("may I help you"), "may I help you")
    }
}
