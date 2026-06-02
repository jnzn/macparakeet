import XCTest
import MacParakeetCore
@testable import MacParakeet

/// Mutable state boxes — Swift 6 forbids capturing mutable locals in
/// escaping @MainActor closures; these classes are captured immutably.
@MainActor
private final class StubProbe {
    var capturing: [String?] = []
}

@MainActor
private final class StopSpy {
    var attempts = 0
    /// Scripted return values for successive onAutoStop calls.
    var results: [Bool] = []
    func record() -> Bool {
        attempts += 1
        return results.isEmpty ? true : results.removeFirst()
    }
}

@MainActor
final class MeetingCallActivityMonitorTests: XCTestCase {
    func testFiresOnceAfterAllowlistedAppReleasesMic() async throws {
        let probe = StubProbe()
        let spy = StopSpy()
        probe.capturing = ["com.microsoft.teams2"]
        let monitor = MeetingCallActivityMonitor(
            delaySeconds: 1,
            allowedPrefixes: ["com.microsoft.teams2"],
            pollInterval: 0.05,
            capturingBundleIDs: { probe.capturing },
            onAutoStop: { spy.record() }
        )
        monitor.start()
        try await Task.sleep(for: .seconds(0.3))    // a few polls — arms
        probe.capturing = []                         // Teams releases the mic
        try await Task.sleep(for: .seconds(1.6))    // > 1s delay + poll slack
        XCTAssertEqual(spy.attempts, 1)
        monitor.stop()
    }

    func testNonAllowlistedAppNeverArms() async throws {
        let probe = StubProbe()
        let spy = StopSpy()
        probe.capturing = ["com.apple.VoiceMemos"]   // not allowlisted
        let monitor = MeetingCallActivityMonitor(
            delaySeconds: 1,
            allowedPrefixes: ["com.microsoft.teams2"],
            pollInterval: 0.05,
            capturingBundleIDs: { probe.capturing },
            onAutoStop: { spy.record() }
        )
        monitor.start()
        try await Task.sleep(for: .seconds(0.3))
        probe.capturing = []                          // releases — must NOT fire
        try await Task.sleep(for: .seconds(1.6))
        XCTAssertEqual(spy.attempts, 0)
        monitor.stop()
    }

    func testDroppedStopResetsDetectorSoItCanFireAgain() async throws {
        // Regression: pause during call-end used to permanently kill auto-stop.
        let probe = StubProbe()
        let spy = StopSpy()
        spy.results = [false, true]   // 1st delivery dropped (paused), 2nd lands
        probe.capturing = ["us.zoom.xos"]
        let monitor = MeetingCallActivityMonitor(
            delaySeconds: 1,
            allowedPrefixes: ["us.zoom.xos"],
            pollInterval: 0.05,
            capturingBundleIDs: { probe.capturing },
            onAutoStop: { spy.record() }
        )
        monitor.start()
        try await Task.sleep(for: .seconds(0.3))    // arm
        probe.capturing = []                         // release → fire #1 (dropped)
        try await Task.sleep(for: .seconds(1.6))
        XCTAssertEqual(spy.attempts, 1)
        probe.capturing = ["us.zoom.xos"]            // call returns → re-arm
        try await Task.sleep(for: .seconds(0.3))
        probe.capturing = []                         // release → fire #2 (delivered)
        try await Task.sleep(for: .seconds(1.6))
        XCTAssertEqual(spy.attempts, 2)
        monitor.stop()
    }
}
