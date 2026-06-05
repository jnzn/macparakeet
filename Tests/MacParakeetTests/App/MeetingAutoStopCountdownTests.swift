import XCTest
@testable import MacParakeet

/// The cancellable grace countdown before activity auto-stop ends a recording
/// (audit PDX-014). The safety-critical guarantee: cancelling (the user clicked
/// "Keep recording") must prevent the stop; only an undisturbed countdown fires.
@MainActor
final class MeetingAutoStopCountdownTests: XCTestCase {
    func testExpiryCallsOnExpireExactlyOnce() async {
        let gate = ManualSleepGate()
        let countdown = MeetingAutoStopCountdown(sleep: { await gate.sleep($0) })
        var expiredCount = 0
        countdown.start(seconds: 5) { expiredCount += 1 }

        await gate.waitUntilStarted(1)
        XCTAssertTrue(countdown.isActive)

        gate.resumeNext()
        await settle()

        XCTAssertEqual(expiredCount, 1)
        XCTAssertFalse(countdown.isActive)
    }

    func testCancelBeforeExpiryNeverFires() async {
        let gate = ManualSleepGate()
        let countdown = MeetingAutoStopCountdown(sleep: { await gate.sleep($0) })
        var expiredCount = 0
        countdown.start(seconds: 5) { expiredCount += 1 }

        await gate.waitUntilStarted(1)
        XCTAssertTrue(countdown.isActive)

        countdown.cancel()
        XCTAssertFalse(countdown.isActive)

        gate.resumeNext()   // let the cancelled task resume past sleep — must not fire
        await settle()

        XCTAssertEqual(expiredCount, 0)
    }

    func testRestartSupersedesPriorCountdown() async {
        let gate = ManualSleepGate()
        let countdown = MeetingAutoStopCountdown(sleep: { await gate.sleep($0) })
        var first = 0
        var second = 0
        countdown.start(seconds: 5) { first += 1 }
        await gate.waitUntilStarted(1)
        countdown.start(seconds: 5) { second += 1 }   // supersedes -> cancels the first
        await gate.waitUntilStarted(2)

        gate.resumeNext()   // first task resumes -> cancelled -> no fire
        gate.resumeNext()   // second task resumes -> fires
        await settle()

        XCTAssertEqual(first, 0)
        XCTAssertEqual(second, 1)
        XCTAssertFalse(countdown.isActive)
    }

    private func settle() async {
        for _ in 0..<10 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }
}

private final class ManualSleepGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [CheckedContinuation<Void, Never>] = []
    private var started = 0

    func sleep(_ seconds: TimeInterval) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            started += 1
            pending.append(continuation)
            lock.unlock()
        }
    }

    var startedCount: Int { lock.withLock { started } }

    func resumeNext() {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            pending.isEmpty ? nil : pending.removeFirst()
        }
        continuation?.resume()
    }

    func waitUntilStarted(_ count: Int) async {
        for _ in 0..<200 where startedCount < count {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
