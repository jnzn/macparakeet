import XCTest
@testable import MacParakeetCore

final class MeetingRecordingFlowStateMachineTests: XCTestCase {
    func testStartRequestsPermissions() {
        var machine = MeetingRecordingFlowStateMachine()

        let effects = machine.handle(.startRequested)

        XCTAssertEqual(machine.state, .checkingPermissions)
        XCTAssertEqual(machine.generation, 1)
        XCTAssertEqual(effects, [.checkPermissions])
    }

    func testPermissionDeniedReturnsToIdleAndPresentsAlert() {
        var machine = MeetingRecordingFlowStateMachine()
        _ = machine.handle(.startRequested)

        let effects = machine.handle(.permissionsDenied(generation: 1, reason: .screenRecording))

        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(effects, [.updateMenuBar(.idle), .presentPermissionAlert(.screenRecording)])
    }

    func testPermissionsGrantedStartsRecordingFlow() {
        var machine = MeetingRecordingFlowStateMachine()
        _ = machine.handle(.startRequested)

        let effects = machine.handle(.permissionsGranted(generation: 1))

        XCTAssertEqual(machine.state, .starting)
        XCTAssertEqual(
            effects,
            [.showRecordingPill, .startRecording, .updateMenuBar(.recording)]
        )
    }

    func testStopWhileStartingQueuesPendingStop() {
        var machine = MeetingRecordingFlowStateMachine()
        _ = machine.handle(.startRequested)
        _ = machine.handle(.permissionsGranted(generation: 1))

        let effects = machine.handle(.stopRequested)

        XCTAssertEqual(machine.state, .stopping)
        XCTAssertTrue(effects.isEmpty)
    }

    func testPendingStopHandsOffOnceRecordingStarts() {
        var machine = MeetingRecordingFlowStateMachine()
        _ = machine.handle(.startRequested)
        _ = machine.handle(.permissionsGranted(generation: 1))
        _ = machine.handle(.stopRequested)

        let effects = machine.handle(.recordingStarted(generation: 1))

        XCTAssertEqual(machine.state, .stopping)
        XCTAssertEqual(effects, [.stopRecordingAndHandOff])
    }

    func testRecordingStopHandsOff() {
        var machine = MeetingRecordingFlowStateMachine()
        _ = machine.handle(.startRequested)
        _ = machine.handle(.permissionsGranted(generation: 1))
        _ = machine.handle(.recordingStarted(generation: 1))

        let effects = machine.handle(.stopRequested)

        XCTAssertEqual(machine.state, .stopping)
        XCTAssertEqual(effects, [.stopRecordingAndHandOff])
    }

    func testCaptureFailureWhileRecordingHandsOff() {
        var machine = MeetingRecordingFlowStateMachine()
        _ = machine.handle(.startRequested)
        _ = machine.handle(.permissionsGranted(generation: 1))
        _ = machine.handle(.recordingStarted(generation: 1))

        let effects = machine.handle(.captureFailed(generation: 1))

        XCTAssertEqual(machine.state, .stopping)
        XCTAssertEqual(effects, [.stopRecordingAndHandOff])
    }

    func testCaptureFailureWhileStartingIsIgnored() {
        var machine = MeetingRecordingFlowStateMachine()
        _ = machine.handle(.startRequested)
        _ = machine.handle(.permissionsGranted(generation: 1))

        let effects = machine.handle(.captureFailed(generation: 1))

        XCTAssertEqual(machine.state, .starting)
        XCTAssertTrue(effects.isEmpty)
    }

    func testStaleCaptureFailureIsIgnored() {
        var machine = MeetingRecordingFlowStateMachine()
        _ = machine.handle(.startRequested)
        _ = machine.handle(.permissionsGranted(generation: 1))
        _ = machine.handle(.recordingStarted(generation: 1))

        let effects = machine.handle(.captureFailed(generation: 0))

        XCTAssertEqual(machine.state, .recording)
        XCTAssertTrue(effects.isEmpty)
    }

    func testHandoffToBackgroundReturnsToIdle() {
        var machine = MeetingRecordingFlowStateMachine()
        _ = machine.handle(.startRequested)
        _ = machine.handle(.permissionsGranted(generation: 1))
        _ = machine.handle(.recordingStarted(generation: 1))
        _ = machine.handle(.stopRequested)

        let effects = machine.handle(.handedOffToBackground(generation: 1))

        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(effects, [.hidePill, .updateMenuBar(.idle)])
    }

    /// The core concurrency guarantee: once a stopped meeting is handed to the
    /// background, the flow is idle and a fresh recording can start immediately.
    func testNewRecordingCanStartImmediatelyAfterHandoff() {
        var machine = MeetingRecordingFlowStateMachine()
        _ = machine.handle(.startRequested)
        _ = machine.handle(.permissionsGranted(generation: 1))
        _ = machine.handle(.recordingStarted(generation: 1))
        _ = machine.handle(.stopRequested)
        _ = machine.handle(.handedOffToBackground(generation: 1))

        let effects = machine.handle(.startRequested)

        XCTAssertEqual(machine.state, .checkingPermissions)
        XCTAssertEqual(machine.generation, 2)
        XCTAssertEqual(effects, [.checkPermissions])
    }

    func testStaleHandoffIsIgnored() {
        var machine = MeetingRecordingFlowStateMachine()
        _ = machine.handle(.startRequested)
        _ = machine.handle(.permissionsGranted(generation: 1))
        _ = machine.handle(.recordingStarted(generation: 1))
        _ = machine.handle(.stopRequested)

        let effects = machine.handle(.handedOffToBackground(generation: 0))

        XCTAssertEqual(machine.state, .stopping)
        XCTAssertTrue(effects.isEmpty)
    }

    func testHandoffFailureShowsErrorAndSchedulesDismiss() {
        var machine = MeetingRecordingFlowStateMachine()
        _ = machine.handle(.startRequested)
        _ = machine.handle(.permissionsGranted(generation: 1))
        _ = machine.handle(.recordingStarted(generation: 1))
        _ = machine.handle(.stopRequested)

        let effects = machine.handle(.handoffFailed(generation: 1, message: "Boom"))

        XCTAssertEqual(machine.state, .finishing(outcome: .error("Boom")))
        XCTAssertEqual(
            effects,
            [.showError("Boom"), .updateMenuBar(.idle), .startAutoDismissTimer(seconds: 5)]
        )
    }

    func testStartFailureShowsErrorAndSchedulesDismiss() {
        var machine = MeetingRecordingFlowStateMachine()
        _ = machine.handle(.startRequested)
        _ = machine.handle(.permissionsGranted(generation: 1))

        let effects = machine.handle(.startFailed(generation: 1, message: "No mic"))

        XCTAssertEqual(machine.state, .finishing(outcome: .error("No mic")))
        XCTAssertEqual(
            effects,
            [.showError("No mic"), .updateMenuBar(.idle), .startAutoDismissTimer(seconds: 5)]
        )
    }

    func testAutoDismissReturnsToIdle() {
        var machine = MeetingRecordingFlowStateMachine()
        _ = machine.handle(.startRequested)
        _ = machine.handle(.permissionsGranted(generation: 1))
        _ = machine.handle(.recordingStarted(generation: 1))
        _ = machine.handle(.stopRequested)
        _ = machine.handle(.handoffFailed(generation: 1, message: "Boom"))

        let effects = machine.handle(.autoDismissExpired(generation: 1))

        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(effects, [.hidePill])
    }

    func testCancelFromRecordingDiscards() {
        var machine = MeetingRecordingFlowStateMachine()
        _ = machine.handle(.startRequested)
        _ = machine.handle(.permissionsGranted(generation: 1))
        _ = machine.handle(.recordingStarted(generation: 1))

        let effects = machine.handle(.cancelRequested)

        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(effects, [.cancelRecording, .hidePill, .updateMenuBar(.idle)])
    }

    func testCancelFromStartingDiscards() {
        var machine = MeetingRecordingFlowStateMachine()
        _ = machine.handle(.startRequested)
        _ = machine.handle(.permissionsGranted(generation: 1))

        let effects = machine.handle(.cancelRequested)

        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(effects, [.cancelRecording, .hidePill, .updateMenuBar(.idle)])
    }

    func testCancelFromCheckingPermissionsDiscardsPendingStart() {
        var machine = MeetingRecordingFlowStateMachine()
        _ = machine.handle(.startRequested)

        let effects = machine.handle(.cancelRequested)

        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(effects, [.cancelRecording, .hidePill, .updateMenuBar(.idle)])
    }

    func testCancelWhileStoppingIsIgnored() {
        var machine = MeetingRecordingFlowStateMachine()
        _ = machine.handle(.startRequested)
        _ = machine.handle(.permissionsGranted(generation: 1))
        _ = machine.handle(.recordingStarted(generation: 1))
        _ = machine.handle(.stopRequested)

        let effects = machine.handle(.cancelRequested)

        XCTAssertEqual(machine.state, .stopping)
        XCTAssertTrue(effects.isEmpty)
    }

    func testStaleGenerationIsIgnored() {
        var machine = MeetingRecordingFlowStateMachine()
        _ = machine.handle(.startRequested)
        _ = machine.handle(.permissionsDenied(generation: 1, reason: .microphone))
        _ = machine.handle(.startRequested)

        let effects = machine.handle(.permissionsGranted(generation: 1))

        XCTAssertEqual(machine.state, .checkingPermissions)
        XCTAssertTrue(effects.isEmpty)
    }
}
