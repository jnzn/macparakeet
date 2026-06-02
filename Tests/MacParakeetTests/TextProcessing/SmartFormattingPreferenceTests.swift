import XCTest
@testable import MacParakeetCore

final class SmartFormattingPreferenceTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "macparakeet.test.config.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDefaultsToTrue() {
        XCTAssertTrue(UserDefaultsAppRuntimePreferences(defaults: defaults).smartFormattingEnabled)
    }
    func testExplicitValueWins() {
        defaults.set(false, forKey: UserDefaultsAppRuntimePreferences.smartFormattingEnabledKey)
        XCTAssertFalse(UserDefaultsAppRuntimePreferences(defaults: defaults).smartFormattingEnabled)
    }
    func testLegacyOptOutMigrates() {
        defaults.set(false, forKey: UserDefaultsAppRuntimePreferences.normalizeNumbersKey)
        XCTAssertFalse(UserDefaultsAppRuntimePreferences(defaults: defaults).smartFormattingEnabled)
    }
    func testPipelineRunsChainWhenEnabled() async {
        let result = await TextRefinementService().refine(
            rawText: "twenty five dollars",
            mode: .clean,
            customWords: [],
            snippets: [],
            smartFormatting: true
        )
        XCTAssertEqual(result.text, "$25")
    }
    func testPipelineSkipsChainWhenDisabled() async {
        let result = await TextRefinementService().refine(
            rawText: "twenty five dollars",
            mode: .clean,
            customWords: [],
            snippets: [],
            smartFormatting: false
        )
        XCTAssertEqual(result.text, "Twenty five dollars")  // only whitespace/capitalization step
    }
}
