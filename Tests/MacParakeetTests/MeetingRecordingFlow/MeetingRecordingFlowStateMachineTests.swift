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

    func testIsCapturingIsFalseOnceStoppingSoMenuOffersStart() {
        // Regression: the menu-bar "Start/Stop Recording" label tracks active
        // capture. Once the user stops, the flow enters `.stopping` (audio
        // finalize) then `.idle` (background transcription) — in both the menu
        // must read "Start Recording", not "Stop". Bug: it read "Stop" during
        // the post-stop processing window because `isMeetingRecordingActive`
        // (used for the label) counted `.stopping` as active.
        var machine = MeetingRecordingFlowStateMachine()
        XCTAssertFalse(machine.state.isCapturing)  // idle

        _ = machine.handle(.startRequested)        // checkingPermissions
        XCTAssertTrue(machine.state.isCapturing)
        _ = machine.handle(.permissionsGranted(generation: machine.generation))  // starting
        XCTAssertTrue(machine.state.isCapturing)
        _ = machine.handle(.recordingStarted(generation: machine.generation))    // recording
        XCTAssertTrue(machine.state.isCapturing)

        _ = machine.handle(.stopRequested)         // stopping (audio finalize)
        XCTAssertEqual(machine.state, .stopping)
        XCTAssertFalse(machine.state.isCapturing, "menu must offer Start during post-capture finalize")

        _ = machine.handle(.handedOffToBackground(generation: machine.generation))  // idle (transcribing)
        XCTAssertEqual(machine.state, .idle)
        XCTAssertFalse(machine.state.isCapturing)
    }

    func testStopRequestedWhileIdleIsNoOp() {
        // Invariant: `.stopRequested` from `.idle` must be a no-op — a stop
        // must NEVER start a recording. (Privacy fix: a blind toggle would
        // silently begin mic + system-audio capture nobody asked for.)
        var machine = MeetingRecordingFlowStateMachine()

        let effects = machine.handle(.stopRequested)

        XCTAssertEqual(machine.state, .idle)
        XCTAssertTrue(effects.isEmpty)
        XCTAssertEqual(machine.generation, 0,
                       "No generation bump means no recording was started")
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
