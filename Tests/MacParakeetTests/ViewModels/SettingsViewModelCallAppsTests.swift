import XCTest
import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class SettingsViewModelCallAppsTests: XCTestCase {
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

    func testLoadsPreSeededDefaultsOnFirstRun() {
        let vm = SettingsViewModel(defaults: defaults)
        XCTAssertEqual(vm.meetingCallApps, MeetingCallApp.defaults)
    }

    func testAddCallAppPersists() throws {
        let vm = SettingsViewModel(defaults: defaults)
        vm.addCallApp(bundleID: "com.cisco.webexmeetingsapp", displayName: "Webex")

        // Reload from a fresh prefs reader — the add must have been persisted.
        let prefs = UserDefaultsAppRuntimePreferences(defaults: defaults)
        XCTAssertTrue(prefs.meetingAutoStopCallApps.contains(
            MeetingCallApp(displayName: "Webex",
                           bundleIDPrefixes: ["com.cisco.webexmeetingsapp"])))
    }

    func testAddDuplicateBundleIDIsIgnored() {
        let vm = SettingsViewModel(defaults: defaults)
        let before = vm.meetingCallApps.count
        vm.addCallApp(bundleID: "com.microsoft.teams2", displayName: "Teams Again")
        XCTAssertEqual(vm.meetingCallApps.count, before)
    }

    func testRemoveCallAppPersists() {
        let vm = SettingsViewModel(defaults: defaults)
        let safari = vm.meetingCallApps.first { $0.displayName == "Safari" }!
        vm.removeCallApp(safari)

        let prefs = UserDefaultsAppRuntimePreferences(defaults: defaults)
        XCTAssertFalse(prefs.meetingAutoStopCallApps.contains { $0.displayName == "Safari" })
    }

    func testMicCandidatesHideMacParakeetDaemonsAndAlreadyAddedApps() {
        let vm = SettingsViewModel(
            defaults: defaults,
            capturingBundleIDsProvider: {
                ["com.macparakeet.pdx",          // self — hidden
                 "com.apple.avconferenced",      // daemon — hidden
                 "com.microsoft.teams2",         // already in defaults — hidden
                 "com.cisco.webexmeetingsapp",   // genuinely new — shown
                 nil]
            },
            callAppDisplayNameResolver: { _ in "Webex" }
        )
        vm.refreshMicCandidatesNow()
        XCTAssertEqual(vm.micCaptureCandidates.map(\.bundleID), ["com.cisco.webexmeetingsapp"])
        XCTAssertEqual(vm.micCaptureCandidates.first?.displayName, "Webex")
    }

    func testMicCandidateFallsBackToBundleIDWhenNameUnknown() {
        let vm = SettingsViewModel(
            defaults: defaults,
            capturingBundleIDsProvider: { ["org.example.unknownapp"] },
            callAppDisplayNameResolver: { _ in nil }
        )
        vm.refreshMicCandidatesNow()
        XCTAssertEqual(vm.micCaptureCandidates.first?.displayName, "org.example.unknownapp")
    }
}
