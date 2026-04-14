import XCTest
@testable import MacParakeetCore

final class AppProfileTests: XCTestCase {
    func testResolveReturnsMatchingProfile() {
        let profiles: [AppProfile] = [
            AppProfile(id: "mail", displayName: "Mail", bundleIDs: ["com.apple.mail"], promptOverride: "mail prompt"),
            AppProfile(id: "terminal", displayName: "Terminal", bundleIDs: ["com.apple.Terminal"], promptOverride: "terminal prompt"),
        ]

        let resolved = AppProfile.resolve(bundleID: "com.apple.mail", from: profiles)
        XCTAssertEqual(resolved?.id, "mail")
    }

    func testResolveReturnsFirstMatchingProfile() {
        // Two profiles claim the same bundle ID; first-match wins.
        let profiles: [AppProfile] = [
            AppProfile(id: "first", displayName: "First", bundleIDs: ["com.example.app"], promptOverride: nil),
            AppProfile(id: "second", displayName: "Second", bundleIDs: ["com.example.app"], promptOverride: nil),
        ]

        let resolved = AppProfile.resolve(bundleID: "com.example.app", from: profiles)
        XCTAssertEqual(resolved?.id, "first")
    }

    func testResolveSkipsDisabledProfiles() {
        let profiles: [AppProfile] = [
            AppProfile(id: "off", displayName: "Off", bundleIDs: ["com.example.app"], promptOverride: nil, enabled: false),
            AppProfile(id: "on", displayName: "On", bundleIDs: ["com.example.app"], promptOverride: nil, enabled: true),
        ]

        let resolved = AppProfile.resolve(bundleID: "com.example.app", from: profiles)
        XCTAssertEqual(resolved?.id, "on")
    }

    func testResolveReturnsNilForUnknownBundleID() {
        let profiles: [AppProfile] = [
            AppProfile(id: "mail", displayName: "Mail", bundleIDs: ["com.apple.mail"], promptOverride: nil),
        ]

        XCTAssertNil(AppProfile.resolve(bundleID: "com.unknown.app", from: profiles))
    }

    func testResolveReturnsNilForNilOrEmptyBundleID() {
        XCTAssertNil(AppProfile.resolve(bundleID: nil))
        XCTAssertNil(AppProfile.resolve(bundleID: ""))
    }

    func testMultipleBundleIDsInOneProfile() {
        // Email profile claims both Mail and Outlook.
        let profile = AppProfile(
            id: "email",
            displayName: "Email",
            bundleIDs: ["com.apple.mail", "com.microsoft.Outlook"],
            promptOverride: "email prompt"
        )

        XCTAssertEqual(AppProfile.resolve(bundleID: "com.apple.mail", from: [profile])?.id, "email")
        XCTAssertEqual(AppProfile.resolve(bundleID: "com.microsoft.Outlook", from: [profile])?.id, "email")
    }

    func testShippedDefaultsCoverExpectedApps() {
        // Sanity: the hardcoded defaults have entries for the apps the MVP targets.
        let expectedBundleIDs = [
            "com.apple.mail",
            "com.microsoft.Outlook",
            "md.obsidian",
            "com.microsoft.teams2",
            "com.apple.MobileSMS",
            "com.apple.Terminal",
        ]

        for bundleID in expectedBundleIDs {
            XCTAssertNotNil(
                AppProfile.resolve(bundleID: bundleID),
                "Expected a default profile to match bundle ID \(bundleID)"
            )
        }
    }

    func testShippedDefaultsHaveUniqueIDs() {
        let ids = AppProfile.defaults.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "AppProfile.defaults has duplicate IDs")
    }

    func testShippedDefaultsAllProvidePromptOverride() {
        // Every default profile must set a prompt override — otherwise it would
        // silently fall back to the user's global prompt, defeating the point.
        for profile in AppProfile.defaults {
            XCTAssertNotNil(profile.promptOverride, "Profile \(profile.id) is missing a promptOverride")
            XCTAssertTrue(
                profile.promptOverride?.contains(AIFormatter.transcriptPlaceholder) == true,
                "Profile \(profile.id) promptOverride missing {{TRANSCRIPT}} placeholder"
            )
        }
    }
}
