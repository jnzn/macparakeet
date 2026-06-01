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
