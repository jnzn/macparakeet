import XCTest
@testable import MacParakeetCore

final class TitleSanitizerTests: XCTestCase {
    func testPassesThroughCleanTitle() {
        XCTAssertEqual(TitleSanitizer.sanitize("Q2 Roadmap Sync"), "Q2 Roadmap Sync")
    }

    func testStripsSurroundingStraightQuotes() {
        XCTAssertEqual(TitleSanitizer.sanitize("\"Q2 Roadmap Sync\""), "Q2 Roadmap Sync")
    }

    func testStripsSurroundingCurlyQuotes() {
        XCTAssertEqual(TitleSanitizer.sanitize("\u{201C}Budget Review\u{201D}"), "Budget Review")
    }

    func testStripsTitleLabelPrefix() {
        XCTAssertEqual(TitleSanitizer.sanitize("Title: Weekly Standup"), "Weekly Standup")
    }

    func testStripsMarkdownHeading() {
        XCTAssertEqual(TitleSanitizer.sanitize("# Design Review"), "Design Review")
    }

    func testTrimsTrailingPunctuation() {
        XCTAssertEqual(TitleSanitizer.sanitize("Planning Meeting."), "Planning Meeting")
    }

    func testTakesFirstNonEmptyLine() {
        XCTAssertEqual(
            TitleSanitizer.sanitize("\n\nHiring Debrief\nThis meeting was about..."),
            "Hiring Debrief"
        )
    }

    func testCollapsesInternalWhitespace() {
        XCTAssertEqual(TitleSanitizer.sanitize("Sprint    Retro"), "Sprint Retro")
    }

    func testClampsLongTitleOnWordBoundary() {
        let long = "This Is An Extremely Long Generated Meeting Title That Greatly Exceeds The Limit"
        let result = TitleSanitizer.sanitize(long)
        XCTAssertLessThanOrEqual(result.count, TitleSanitizer.maxLength)
        // Should not cut a word in half — last token is whole.
        XCTAssertFalse(result.hasSuffix(" "))
        XCTAssertTrue(long.hasPrefix(result))
    }

    func testNestedQuotesAndLabelTogether() {
        XCTAssertEqual(TitleSanitizer.sanitize("Title: \"Q3 Kickoff\""), "Q3 Kickoff")
    }
}
