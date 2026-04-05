import AppKit
import MacParakeetCore

@MainActor
final class MeetingRecordingFlowCoordinator {
    var isMeetingRecordingActive: Bool {
        switch stateMachine.state {
        case .idle, .finishing:
            return false
        case .checkingPermissions, .starting, .recording, .pendingStop, .transcribing:
            return true
        }
    }

    private let meetingRecordingService: MeetingRecordingServiceProtocol
    private let transcriptionService: TranscriptionServiceProtocol
    private let permissionService: PermissionServiceProtocol
    private let onMenuBarIconUpdate: (BreathWaveIcon.MenuBarState) -> Void
    private let onTranscriptionReady: (Transcription) -> Void
    private let onRecordingBegan: () -> Void
    private let onFlowReturnedToIdle: () -> Void

    private var stateMachine = MeetingRecordingFlowStateMachine()
    private var overlayController: MeetingRecordingOverlayController?
    private var overlayViewModel: MeetingRecordingOverlayViewModel?
    private var actionTask: Task<Void, Never>?
    private var autoDismissTask: Task<Void, Never>?
    private var completedTranscription: Transcription?

    init(
        meetingRecordingService: MeetingRecordingServiceProtocol,
        transcriptionService: TranscriptionServiceProtocol,
        permissionService: PermissionServiceProtocol,
        onMenuBarIconUpdate: @escaping (BreathWaveIcon.MenuBarState) -> Void,
        onTranscriptionReady: @escaping (Transcription) -> Void,
        onRecordingBegan: @escaping () -> Void = {},
        onFlowReturnedToIdle: @escaping () -> Void = {}
    ) {
        self.meetingRecordingService = meetingRecordingService
        self.transcriptionService = transcriptionService
        self.permissionService = permissionService
        self.onMenuBarIconUpdate = onMenuBarIconUpdate
        self.onTranscriptionReady = onTranscriptionReady
        self.onRecordingBegan = onRecordingBegan
        self.onFlowReturnedToIdle = onFlowReturnedToIdle
    }

    func toggleRecording() {
        switch stateMachine.state {
        case .idle:
            sendEvent(.startRequested)
        case .recording, .starting, .pendingStop:
            sendEvent(.stopRequested)
        case .checkingPermissions, .transcribing, .finishing:
            break
        }
    }

    private func sendEvent(_ event: MeetingRecordingFlowEvent) {
        let effects = stateMachine.handle(event)
        executeEffects(effects)
    }

    private func executeEffects(_ effects: [MeetingRecordingFlowEffect]) {
        for effect in effects {
            executeEffect(effect)
        }
    }

    private func executeEffect(_ effect: MeetingRecordingFlowEffect) {
        switch effect {
        case .checkPermissions:
            let gen = stateMachine.generation
            actionTask = Task { @MainActor in
                let microphoneStatus = await permissionService.checkMicrophonePermission()
                let microphoneGranted: Bool
                switch microphoneStatus {
                case .granted:
                    microphoneGranted = true
                case .denied:
                    microphoneGranted = false
                case .notDetermined:
                    Telemetry.send(.permissionPrompted(permission: .microphone))
                    microphoneGranted = await permissionService.requestMicrophonePermission()
                }

                if !microphoneGranted {
                    Telemetry.send(.permissionDenied(permission: .microphone))
                    self.sendEvent(.permissionsDenied(generation: gen, reason: .microphone))
                    return
                }
                Telemetry.send(.permissionGranted(permission: .microphone))

                let existingScreenGrant = permissionService.checkScreenRecordingPermission()
                if !existingScreenGrant {
                    Telemetry.send(.permissionPrompted(permission: .screenRecording))
                }
                let screenGranted = existingScreenGrant || permissionService.requestScreenRecordingPermission()
                if !screenGranted {
                    Telemetry.send(.permissionDenied(permission: .screenRecording))
                    self.sendEvent(.permissionsDenied(generation: gen, reason: .screenRecording))
                    return
                }
                Telemetry.send(.permissionGranted(permission: .screenRecording))
                self.sendEvent(.permissionsGranted(generation: gen))
            }

        case .showRecordingOverlay:
            onRecordingBegan()
            let vm = overlayViewModel ?? MeetingRecordingOverlayViewModel()
            vm.onStop = { [weak self] in self?.toggleRecording() }
            vm.state = .recording
            vm.startTimer()
            overlayViewModel = vm

            if overlayController == nil {
                overlayController = MeetingRecordingOverlayController(viewModel: vm)
            }
            overlayController?.show()

        case .startRecording:
            let gen = stateMachine.generation
            actionTask = Task { @MainActor in
                do {
                    try await meetingRecordingService.startRecording { [weak self] levels in
                        Task { @MainActor [weak self] in
                            self?.overlayViewModel?.microphoneLevel = levels.microphone
                            self?.overlayViewModel?.systemLevel = levels.system
                        }
                    }
                    self.sendEvent(.recordingStarted(generation: gen))
                } catch {
                    self.sendEvent(.startFailed(generation: gen, message: error.localizedDescription))
                }
            }

        case .showTranscribingState:
            overlayViewModel?.stopTimer()
            overlayViewModel?.state = .transcribing

        case .stopRecordingAndTranscribe:
            let gen = stateMachine.generation
            actionTask = Task { @MainActor in
                do {
                    let output = try await meetingRecordingService.stopRecording()
                    let transcription = try await transcriptionService.transcribeMeeting(recording: output, onProgress: nil)
                    self.completedTranscription = transcription
                    self.sendEvent(.transcriptionCompleted(generation: gen, transcriptionID: transcription.id))
                } catch {
                    self.sendEvent(.transcriptionFailed(generation: gen, message: error.localizedDescription))
                }
            }

        case .showCompleted:
            overlayViewModel?.stopTimer()
            overlayViewModel?.state = .completed

        case .showError(let message):
            overlayViewModel?.stopTimer()
            overlayViewModel?.state = .error(message)

        case .hideOverlay:
            overlayViewModel?.stopTimer()
            overlayController?.hide()
            overlayController = nil
            overlayViewModel = nil
            completedTranscription = nil
            onFlowReturnedToIdle()

        case .updateMenuBar(let state):
            let iconState: BreathWaveIcon.MenuBarState = switch state {
            case .idle: .idle
            case .recording: .recording
            case .processing: .processing
            }
            onMenuBarIconUpdate(iconState)

        case .navigateToTranscription(let id):
            guard completedTranscription?.id == id, let transcription = completedTranscription else { return }
            onTranscriptionReady(transcription)

        case .presentPermissionAlert(let reason):
            onFlowReturnedToIdle()
            presentPermissionAlert(for: reason)

        case .startAutoDismissTimer(let seconds):
            autoDismissTask?.cancel()
            let gen = stateMachine.generation
            autoDismissTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                self.sendEvent(.autoDismissExpired(generation: gen))
            }

        case .cancelAutoDismissTimer:
            autoDismissTask?.cancel()
            autoDismissTask = nil
        }
    }

    private func presentPermissionAlert(for reason: MeetingRecordingPermissionFailure) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        switch reason {
        case .microphone:
            alert.messageText = "Microphone Access Required"
            alert.informativeText = "Meeting recording needs microphone access to capture your voice."
        case .screenRecording:
            alert.messageText = "Screen Recording Access Required"
            alert.informativeText = "Meeting recording needs Screen & System Audio Recording access to capture system audio."
        }
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openSystemSettings(for: reason)
        }
    }

    private func openSystemSettings(for reason: MeetingRecordingPermissionFailure) {
        let anchor = switch reason {
        case .microphone:
            "Privacy_Microphone"
        case .screenRecording:
            "Privacy_ScreenCapture"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
