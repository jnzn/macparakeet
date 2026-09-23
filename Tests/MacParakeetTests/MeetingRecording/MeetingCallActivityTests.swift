import XCTest
@testable import MacParakeetCore

final class MeetingCallActivityAllowlistTests: XCTestCase {
    private let teamsAndBrowsers = ["com.microsoft.teams2", "com.apple.Safari",
                                    "com.apple.WebKit", "com.google.Chrome"]

    func testAllowlistedAppCountsAsCall() {
        XCTAssertTrue(MeetingCallActivity.isCall(
            capturingBundleIDs: ["com.microsoft.teams2"],
            allowedPrefixes: teamsAndBrowsers))
    }

    func testPrefixMatchCoversHelperProcesses() {
        // Safari mic capture shows up as a WebKit helper; Chrome as a helper.
        XCTAssertTrue(MeetingCallActivity.isCall(
            capturingBundleIDs: ["com.apple.WebKit.GPU"],
            allowedPrefixes: teamsAndBrowsers))
        XCTAssertTrue(MeetingCallActivity.isCall(
            capturingBundleIDs: ["com.google.Chrome.helper"],
            allowedPrefixes: teamsAndBrowsers))
    }

    func testNonAllowlistedAppIsNotACall() {
        // Random mic users (voice memo app, system daemon) never arm auto-stop.
        XCTAssertFalse(MeetingCallActivity.isCall(
            capturingBundleIDs: ["com.apple.VoiceMemos", "com.apple.avconferenced"],
            allowedPrefixes: teamsAndBrowsers))
    }

    func testMacParakeetCaptureDoesNotCountWithNormalAllowlist() {
        // The new API is a pure allowlist gate — it has no built-in MacParakeet
        // exclusion. Self-capture safety is by construction: the pre-seeded
        // defaults never include a com.macparakeet prefix, and the Settings
        // picker hides MacParakeet so the user can't add it. This test pins the
        // by-construction behavior; enforcement is the caller's responsibility.
        XCTAssertFalse(MeetingCallActivity.isCall(
            capturingBundleIDs: ["com.macparakeet.pdx"],
            allowedPrefixes: teamsAndBrowsers))
    }

    func testEmptyAllowlistNeverDetectsACall() {
        XCTAssertFalse(MeetingCallActivity.isCall(
            capturingBundleIDs: ["com.microsoft.teams2"],
            allowedPrefixes: []))
    }

    func testNilAndEmptyBundleIDsAreIgnored() {
        XCTAssertFalse(MeetingCallActivity.isCall(
            capturingBundleIDs: [nil, ""],
            allowedPrefixes: teamsAndBrowsers))
    }

    func testMatchingBundleIDsReturnsOnlyAllowlistedMatches() {
        let matches = MeetingCallActivity.matchingBundleIDs(
            capturingBundleIDs: ["com.microsoft.teams2", "com.apple.VoiceMemos", nil],
            allowedPrefixes: teamsAndBrowsers)
        XCTAssertEqual(matches, ["com.microsoft.teams2"])
    }
}
