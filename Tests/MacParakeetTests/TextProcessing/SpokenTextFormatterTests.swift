import XCTest
@testable import MacParakeetCore

final class SpokenTextFormatterTests: XCTestCase {
    func testCurrencyAndDateChain() {
        XCTAssertEqual(SpokenTextFormatter.format("twenty five dollars on june second"),
                       "$25 on June 2nd")
    }
    func testPercentTimeAndTrailingPeriod() {
        XCTAssertEqual(SpokenTextFormatter.format("fifty percent by three thirty pm period"),
                       "50% by 3:30 PM.")
    }
    func testISODateWithTime() {
        XCTAssertEqual(SpokenTextFormatter.format("twenty twenty six dash june dash second at nine a m"),
                       "2026-06-02 at 9:00 AM")
    }
    func testGuardsHoldThroughTheChain() {
        XCTAssertEqual(SpokenTextFormatter.format("first of all I'm at home"),
                       "first of all I'm at home")
        XCTAssertEqual(SpokenTextFormatter.format("the trial period ended"),
                       "the trial period ended")
    }
    func testYearBeforeCardinals() {
        XCTAssertEqual(SpokenTextFormatter.format("back in twenty twenty four"), "back in 2024")
    }
    func testCompoundOrdinalBeforeCardinals() {
        XCTAssertEqual(SpokenTextFormatter.format("the twenty fifth item"), "the 25th item")
    }
    func testFractionsEndToEnd() {
        // Spec §5: "one half" → 1/2 requires NumberNormalizer → UnitNormalizer handoff
        XCTAssertEqual(SpokenTextFormatter.format("one half"), "1/2")
        XCTAssertEqual(SpokenTextFormatter.format("three quarters"), "3/4")
    }
    func testCurrencyWithSpokenAmounts() {
        // Full spoken path: cardinals → currency
        XCTAssertEqual(SpokenTextFormatter.format("three dollars and fifty cents"), "$3.50")
        XCTAssertEqual(SpokenTextFormatter.format("five thousand won"), "₩5,000")
    }
}
