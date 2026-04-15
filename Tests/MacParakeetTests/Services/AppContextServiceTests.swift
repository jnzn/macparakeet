import XCTest
@testable import MacParakeetCore

final class AppContextServiceTests: XCTestCase {
    // MARK: - AppContext.isEmpty

    func testEmptyContextIsEmpty() {
        XCTAssertTrue(AppContext().isEmpty)
        XCTAssertTrue(AppContext(bundleID: "com.example").isEmpty)
    }

    func testContextWithWindowTitleIsNotEmpty() {
        XCTAssertFalse(AppContext(windowTitle: "Chat with Yeswanth").isEmpty)
    }

    func testContextWithFocusedFieldIsNotEmpty() {
        XCTAssertFalse(AppContext(focusedFieldValue: "hello").isEmpty)
    }

    func testContextWithSelectedTextIsNotEmpty() {
        XCTAssertFalse(AppContext(selectedText: "picked").isEmpty)
    }

    func testWhitespaceOnlyFieldsCountAsEmpty() {
        let ctx = AppContext(
            windowTitle: "   \n\t",
            focusedFieldValue: "",
            selectedText: "   "
        )
        XCTAssertTrue(ctx.isEmpty)
    }

    // MARK: - AppContext.asPromptBlock

    func testAsPromptBlockIncludesAllFields() {
        let ctx = AppContext(
            windowTitle: "Inbox",
            focusedFieldValue: "Draft: Hi team",
            selectedText: "schedule"
        )
        let block = ctx.asPromptBlock()
        XCTAssertTrue(block.contains("- Window: Inbox"))
        XCTAssertTrue(block.contains("- Current field contains:"))
        XCTAssertTrue(block.contains("Draft: Hi team"))
        XCTAssertTrue(block.contains("- Selected text:"))
        XCTAssertTrue(block.contains("schedule"))
    }

    func testAsPromptBlockSkipsBlankFields() {
        let ctx = AppContext(windowTitle: "Chat with Yeswanth", focusedFieldValue: "", selectedText: nil)
        let block = ctx.asPromptBlock()
        XCTAssertEqual(block, "- Window: Chat with Yeswanth")
    }

    func testAsPromptBlockTruncatesLongSelection() {
        let long = String(repeating: "x", count: 1_200)
        let ctx = AppContext(selectedText: long)
        let block = ctx.asPromptBlock(maxFieldChars: 100, maxSelectionChars: 80)
        XCTAssertTrue(block.contains("…"))
        // "- Selected text: \"" + 80 chars + "…\"" = 80 truncated + overhead.
        // Sanity check the line doesn't contain the full 1200 chars verbatim.
        XCTAssertLessThan(block.count, 200)
    }

    func testAsPromptBlockEmptyForEmptyContext() {
        XCTAssertEqual(AppContext().asPromptBlock(), "")
    }

    // MARK: - AppContextService.isBlocklisted

    func testBlocklistHitsOnePassword() {
        XCTAssertTrue(AppContextService.isBlocklisted(bundleID: "com.1password.1password"))
        XCTAssertTrue(AppContextService.isBlocklisted(bundleID: "com.1password.1password7"))
        XCTAssertTrue(AppContextService.isBlocklisted(bundleID: "com.agilebits.onepassword7"))
    }

    func testBlocklistHitsKeychainAndSettings() {
        XCTAssertTrue(AppContextService.isBlocklisted(bundleID: "com.apple.keychainaccess"))
        XCTAssertTrue(AppContextService.isBlocklisted(bundleID: "com.apple.systempreferences"))
        XCTAssertTrue(AppContextService.isBlocklisted(bundleID: "com.apple.systemsettings"))
    }

    func testBlocklistMissesNormalApps() {
        XCTAssertFalse(AppContextService.isBlocklisted(bundleID: "com.apple.mail"))
        XCTAssertFalse(AppContextService.isBlocklisted(bundleID: "com.microsoft.teams2"))
        XCTAssertFalse(AppContextService.isBlocklisted(bundleID: "md.obsidian"))
    }

    func testBlocklistHandlesNilAndEmpty() {
        XCTAssertFalse(AppContextService.isBlocklisted(bundleID: nil))
        XCTAssertFalse(AppContextService.isBlocklisted(bundleID: ""))
    }

    func testBlocklistIsCaseSensitive() {
        // macOS bundle IDs are canonically lowercase per Apple's convention;
        // if an upper-case variant ever appeared, we'd rather miss the block
        // than accidentally block a legitimate app. Document the behavior.
        XCTAssertFalse(AppContextService.isBlocklisted(bundleID: "COM.1PASSWORD.1PASSWORD"))
    }
}
