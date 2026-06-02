import XCTest
@testable import MacParakeetCore

final class MeetingCallActivityTests: XCTestCase {
    func testTeamsCountsAsCall() {
        XCTAssertTrue(MeetingCallActivity.isCall(capturingBundleIDs: ["com.microsoft.teams2"]))
    }
    func testExcludesAVConferencedDaemon() {
        XCTAssertFalse(MeetingCallActivity.isCall(capturingBundleIDs: ["com.apple.avconferenced"]))
    }
    func testExcludesMacParakeetOwnCapture() {
        XCTAssertFalse(MeetingCallActivity.isCall(capturingBundleIDs: ["com.macparakeet.pdx"]))
        XCTAssertFalse(MeetingCallActivity.isCall(capturingBundleIDs: ["com.macparakeet.MacParakeet"]))
    }
    func testCallAlongsideDaemonStillCounts() {
        XCTAssertTrue(MeetingCallActivity.isCall(capturingBundleIDs: ["com.apple.avconferenced", "us.zoom.xos"]))
    }
    func testNilOrEmptyIsNotACall() {
        XCTAssertFalse(MeetingCallActivity.isCall(capturingBundleIDs: []))
        XCTAssertFalse(MeetingCallActivity.isCall(capturingBundleIDs: [nil]))
    }
}

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

    func testMacParakeetIsNotACallEvenIfSomehowListed() {
        // Self-capture can never arm the detector via the picker (the picker
        // hides MacParakeet), but even raw capture of our own bundle ID with a
        // normal allowlist must not count.
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
