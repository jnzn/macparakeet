import XCTest
@testable import MacParakeetCore

final class MeetingCallAppTests: XCTestCase {
    func testCodableRoundTrip() throws {
        let apps = [
            MeetingCallApp(displayName: "Microsoft Teams",
                           bundleIDPrefixes: ["com.microsoft.teams2", "com.microsoft.teams"]),
            MeetingCallApp(displayName: "Custom", bundleIDPrefixes: ["org.example.app"]),
        ]
        let data = try JSONEncoder().encode(apps)
        let decoded = try JSONDecoder().decode([MeetingCallApp].self, from: data)
        XCTAssertEqual(decoded, apps)
    }

    func testDefaultsIncludeOwnerCallApps() {
        let allPrefixes = MeetingCallApp.defaults.flatMap(\.bundleIDPrefixes)
        // Teams + browsers must work with zero configuration (spec §pre-seeds).
        XCTAssertTrue(allPrefixes.contains("com.microsoft.teams2"))
        XCTAssertTrue(allPrefixes.contains("com.apple.Safari"))
        XCTAssertTrue(allPrefixes.contains("com.apple.WebKit"))
        XCTAssertTrue(allPrefixes.contains("com.google.Chrome"))
        XCTAssertTrue(allPrefixes.contains("us.zoom.xos"))
    }

    func testDefaultsNeverIncludeMacParakeet() {
        let allPrefixes = MeetingCallApp.defaults.flatMap(\.bundleIDPrefixes)
        XCTAssertFalse(allPrefixes.contains { $0.hasPrefix("com.macparakeet") })
    }
}

// Note: the original ADR-023 Phase 1.5 also had a user-editable allowlist
// persisted via UserDefaultsAppRuntimePreferences.meetingAutoStopCallApps
// (Settings UI + live mic-app picker). This restore hardcodes
// MeetingCallApp.defaults instead — the persistence/Settings-UI layer was
// out of scope for the call-ended-signal fix and can be added later if
// customizing the allowlist is wanted.
