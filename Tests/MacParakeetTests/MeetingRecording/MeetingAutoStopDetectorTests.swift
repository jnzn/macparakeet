import XCTest
@testable import MacParakeetCore

final class MeetingAutoStopDetectorTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func testNeverFiresWithoutACall() {
        var d = MeetingAutoStopDetector(delaySeconds: 5)
        for s in stride(from: 0.0, through: 30.0, by: 1.5) {
            XCTAssertEqual(d.sample(isCallActive: false, now: at(s)), .none)
        }
    }

    func testFiresAfterDelayOnceArmed() {
        var d = MeetingAutoStopDetector(delaySeconds: 5)
        XCTAssertEqual(d.sample(isCallActive: true, now: at(0)), .none)   // arm
        XCTAssertEqual(d.sample(isCallActive: false, now: at(1)), .none)  // released @1
        XCTAssertEqual(d.sample(isCallActive: false, now: at(5)), .none)  // 4s < 5
        XCTAssertEqual(d.sample(isCallActive: false, now: at(6)), .autoStop) // 5s elapsed
    }

    func testReactivationResetsTheTimer() {
        var d = MeetingAutoStopDetector(delaySeconds: 5)
        _ = d.sample(isCallActive: true, now: at(0))    // arm
        _ = d.sample(isCallActive: false, now: at(1))   // released @1
        XCTAssertEqual(d.sample(isCallActive: true, now: at(3)), .none)  // call back -> reset
        XCTAssertEqual(d.sample(isCallActive: false, now: at(4)), .none) // released @4
        XCTAssertEqual(d.sample(isCallActive: false, now: at(8)), .none) // 4s < 5
        XCTAssertEqual(d.sample(isCallActive: false, now: at(9)), .autoStop) // 5s from @4
    }

    func testFiresOnlyOnce() {
        var d = MeetingAutoStopDetector(delaySeconds: 5)
        _ = d.sample(isCallActive: true, now: at(0))
        _ = d.sample(isCallActive: false, now: at(1))
        XCTAssertEqual(d.sample(isCallActive: false, now: at(6)), .autoStop)
        XCTAssertEqual(d.sample(isCallActive: false, now: at(7)), .none)
        XCTAssertEqual(d.sample(isCallActive: true, now: at(8)), .none)   // stays fired
        XCTAssertEqual(d.sample(isCallActive: false, now: at(20)), .none)
    }
}
