import XCTest
@testable import MacParakeetCore

final class AIFormatterTests: XCTestCase {
    func testV2DefaultFoldsToCurrentDefault() {
        XCTAssertEqual(
            AIFormatter.normalizedPromptTemplate(AIFormatter.legacyDefaultPromptTemplateV2),
            AIFormatter.defaultPromptTemplate
        )
    }

    func testCurrentDefaultMentionsPreservingFormatting() {
        XCTAssertTrue(AIFormatter.defaultPromptTemplate.contains("preserve them exactly as written"))
    }

    func testSampleProfilesDoNotInstructNumberConversion() {
        for profile in AppProfile.defaults {
            XCTAssertFalse(profile.promptOverride?.contains("write spoken numbers as digits") ?? false,
                           "\(profile.displayName) still instructs number conversion")
            XCTAssertFalse(profile.promptOverride?.contains("remove filler words") ?? false,
                           "\(profile.displayName) still instructs filler removal")
        }
    }
}
