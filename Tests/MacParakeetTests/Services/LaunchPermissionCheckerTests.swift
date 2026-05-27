import XCTest
@testable import MacParakeetCore

final class LaunchPermissionCheckerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "LaunchPermissionCheckerTests.\(UUID())"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        suiteName = nil
        super.tearDown()
    }

    // MARK: - No stored fingerprint (first post-onboarding launch)

    func testNoFingerprint_allGranted_noAlert() {
        let missing = LaunchPermissionChecker.check(
            micGranted: true,
            accessibilityGranted: true,
            screenRecordingGranted: true,
            meetingRecordingEnabled: true,
            defaults: defaults
        )
        XCTAssertEqual(missing, [])
    }

    func testNoFingerprint_micMissing_alertsFired() {
        let missing = LaunchPermissionChecker.check(
            micGranted: false,
            accessibilityGranted: true,
            screenRecordingGranted: true,
            meetingRecordingEnabled: true,
            defaults: defaults
        )
        XCTAssertEqual(missing, [.microphone])
    }

    func testNoFingerprint_allMissing_alertsAll() {
        let missing = LaunchPermissionChecker.check(
            micGranted: false,
            accessibilityGranted: false,
            screenRecordingGranted: false,
            meetingRecordingEnabled: true,
            defaults: defaults
        )
        XCTAssertEqual(missing, [.microphone, .accessibility, .screenRecording])
    }

    func testNoFingerprint_screenRecordingMissing_meetingDisabled_noAlert() {
        let missing = LaunchPermissionChecker.check(
            micGranted: true,
            accessibilityGranted: true,
            screenRecordingGranted: false,
            meetingRecordingEnabled: false,
            defaults: defaults
        )
        XCTAssertEqual(missing, [])
    }

    // MARK: - Stored fingerprint — revocation detection

    func testRevocation_micRevoked_alertsFired() {
        LaunchPermissionChecker.saveFingerprint(
            micGranted: true,
            accessibilityGranted: true,
            screenRecordingGranted: false,
            meetingRecordingEnabled: false,
            defaults: defaults
        )
        let missing = LaunchPermissionChecker.check(
            micGranted: false,
            accessibilityGranted: true,
            screenRecordingGranted: false,
            meetingRecordingEnabled: false,
            defaults: defaults
        )
        XCTAssertEqual(missing, [.microphone])
    }

    func testNoRevocation_samePermissions_noAlert() {
        LaunchPermissionChecker.saveFingerprint(
            micGranted: true,
            accessibilityGranted: true,
            screenRecordingGranted: false,
            meetingRecordingEnabled: false,
            defaults: defaults
        )
        let missing = LaunchPermissionChecker.check(
            micGranted: true,
            accessibilityGranted: true,
            screenRecordingGranted: false,
            meetingRecordingEnabled: false,
            defaults: defaults
        )
        XCTAssertEqual(missing, [])
    }

    func testPermissionGained_noAlert() {
        LaunchPermissionChecker.saveFingerprint(
            micGranted: true,
            accessibilityGranted: false,
            screenRecordingGranted: false,
            meetingRecordingEnabled: false,
            defaults: defaults
        )
        let missing = LaunchPermissionChecker.check(
            micGranted: true,
            accessibilityGranted: true,
            screenRecordingGranted: false,
            meetingRecordingEnabled: false,
            defaults: defaults
        )
        XCTAssertEqual(missing, [])
    }

    func testAllRevoked_alertsAll() {
        LaunchPermissionChecker.saveFingerprint(
            micGranted: true,
            accessibilityGranted: true,
            screenRecordingGranted: true,
            meetingRecordingEnabled: true,
            defaults: defaults
        )
        let missing = LaunchPermissionChecker.check(
            micGranted: false,
            accessibilityGranted: false,
            screenRecordingGranted: false,
            meetingRecordingEnabled: true,
            defaults: defaults
        )
        XCTAssertEqual(missing, [.microphone, .accessibility, .screenRecording])
    }

    // MARK: - saveFingerprint persists correctly

    func testSaveFingerprint_persistsToDefaults() {
        LaunchPermissionChecker.saveFingerprint(
            micGranted: true,
            accessibilityGranted: false,
            screenRecordingGranted: true,
            meetingRecordingEnabled: true,
            defaults: defaults
        )
        let stored = defaults.integer(forKey: LaunchPermissionChecker.fingerprintKey)
        // bit 0 (mic) + bit 2 (screen) = 0b101 = 5
        XCTAssertEqual(stored, 5)
    }
}
