import XCTest
@testable import MacParakeetCore

final class EmailURLNormalizerTests: XCTestCase {
    func testEmail() {
        XCTAssertEqual(EmailURLNormalizer.normalize("john at gmail dot com"), "john@gmail.com")
        XCTAssertEqual(EmailURLNormalizer.normalize("support at macparakeet dot com"), "support@macparakeet.com")
    }
    func testURL() {
        XCTAssertEqual(EmailURLNormalizer.normalize("example dot com"), "example.com")
        XCTAssertEqual(EmailURLNormalizer.normalize("example dot com slash docs"), "example.com/docs")
    }
    func testBareAtIsNeverConverted() {
        XCTAssertEqual(EmailURLNormalizer.normalize("I'm at home"), "I'm at home")
        XCTAssertEqual(EmailURLNormalizer.normalize("meet me at noon"), "meet me at noon")
    }
}
