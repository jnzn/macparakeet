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

final class MeetingAutoStopCallAppsPreferenceTests: XCTestCase {
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

    func testReturnsPreSeededDefaultsWhenNeverEdited() {
        let prefs = UserDefaultsAppRuntimePreferences(defaults: defaults)
        XCTAssertEqual(prefs.meetingAutoStopCallApps, MeetingCallApp.defaults)
    }

    func testReturnsStoredListWhenEdited() throws {
        let custom = [MeetingCallApp(displayName: "Teams",
                                     bundleIDPrefixes: ["com.microsoft.teams2"])]
        defaults.set(try JSONEncoder().encode(custom),
                     forKey: UserDefaultsAppRuntimePreferences.meetingAutoStopCallAppsKey)
        let prefs = UserDefaultsAppRuntimePreferences(defaults: defaults)
        XCTAssertEqual(prefs.meetingAutoStopCallApps, custom)
    }

    func testEmptyStoredListStaysEmpty() throws {
        // Removing every app is a deliberate user choice — do not re-seed.
        defaults.set(try JSONEncoder().encode([MeetingCallApp]()),
                     forKey: UserDefaultsAppRuntimePreferences.meetingAutoStopCallAppsKey)
        let prefs = UserDefaultsAppRuntimePreferences(defaults: defaults)
        XCTAssertEqual(prefs.meetingAutoStopCallApps, [])
    }

    func testCorruptDataFallsBackToDefaults() {
        defaults.set(Data("not json".utf8),
                     forKey: UserDefaultsAppRuntimePreferences.meetingAutoStopCallAppsKey)
        let prefs = UserDefaultsAppRuntimePreferences(defaults: defaults)
        XCTAssertEqual(prefs.meetingAutoStopCallApps, MeetingCallApp.defaults)
    }
}
