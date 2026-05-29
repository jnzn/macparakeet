import AppKit
import MacParakeetCore
import MacParakeetViewModels
import os

@MainActor
final class VoiceMemoFlowCoordinator {
    private enum State {
        case idle
        case checkingPermissions
        case recording
        case transcribing
    }

    var isVoiceMemoActive: Bool { state != .idle }

    private var state: State = .idle
    private let meetingRecordingService: MeetingRecordingServiceProtocol
    private let transcriptionService: TranscriptionServiceProtocol
    private let permissionService: PermissionServiceProtocol
    private let libraryViewModel: TranscriptionLibraryViewModel
    private let isMeetingRecordingActive: @MainActor () -> Bool
    private let onTranscriptionReady: (Transcription) -> Void
    private let onRecordingBegan: () -> Void
    private let onFlowReturnedToIdle: () -> Void

    private var pillController: VoiceMemoPillController?
    private var pillViewModel: VoiceMemoPillViewModel?
    private var actionTask: Task<Void, Never>?
    private var pillPollingTask: Task<Void, Never>?
    private var autoDismissTask: Task<Void, Never>?

    private let logger = Logger(subsystem: "com.macparakeet", category: "VoiceMemoFlow")

    init(
        meetingRecordingService: MeetingRecordingServiceProtocol,
        transcriptionService: TranscriptionServiceProtocol,
        permissionService: PermissionServiceProtocol,
        libraryViewModel: TranscriptionLibraryViewModel,
        isMeetingRecordingActive: @escaping @MainActor () -> Bool = { false },
        onTranscriptionReady: @escaping (Transcription) -> Void,
        onRecordingBegan: @escaping () -> Void = {},
        onFlowReturnedToIdle: @escaping () -> Void = {}
    ) {
        self.meetingRecordingService = meetingRecordingService
        self.transcriptionService = transcriptionService
        self.permissionService = permissionService
        self.libraryViewModel = libraryViewModel
        self.isMeetingRecordingActive = isMeetingRecordingActive
        self.onTranscriptionReady = onTranscriptionReady
        self.onRecordingBegan = onRecordingBegan
        self.onFlowReturnedToIdle = onFlowReturnedToIdle
    }

    func toggleRecording() {
        switch state {
        case .idle:
            startRecording()
        case .recording:
            stopRecording()
        case .checkingPermissions, .transcribing:
            break
        }
    }

    func cancelAndWaitForCompletion() async {
        guard state != .idle else { return }
        actionTask?.cancel()
        actionTask = nil
        await meetingRecordingService.cancelRecording()
        returnToIdle()
    }

    // MARK: - Private

    private func startRecording() {
        guard !isMeetingRecordingActive() else { return }
        state = .checkingPermissions
        actionTask = Task { @MainActor in
            let micStatus = await self.permissionService.checkMicrophonePermission()
            let micGranted: Bool
            switch micStatus {
            case .granted:
                micGranted = true
            case .denied:
                micGranted = false
            case .notDetermined:
                micGranted = await self.permissionService.requestMicrophonePermission()
            }

            guard !Task.isCancelled else { return }

            if !micGranted {
                self.showPermissionAlert()
                self.returnToIdle()
                return
            }

            self.state = .recording
            self.showPill()
            self.onRecordingBegan()

            do {
                try await self.meetingRecordingService.startRecording(
                    title: Self.defaultTitle(),
                    sourceMode: .microphoneOnly
                )
                self.startPillPolling()
            } catch {
                self.logger.error("voice_memo start failed: \(error)")
                self.pillViewModel?.state = .error("Recording failed to start.")
                self.scheduleAutoDismiss(after: 3)
            }
        }
    }

    private func stopRecording() {
        guard state == .recording else { return }
        state = .transcribing
        stopPillPolling()
        pillViewModel?.state = .transcribing

        actionTask = Task { @MainActor in
            do {
                let output = try await self.meetingRecordingService.stopRecording()
                let transcription = try await self.transcriptionService.transcribeMeeting(
                    recording: output,
                    onProgress: nil
                )
                await self.meetingRecordingService.completeTranscription(for: output)
                self.libraryViewModel.loadTranscriptions()
                self.pillViewModel?.state = .completed
                self.scheduleAutoDismiss(after: 2)
                self.onTranscriptionReady(transcription)
            } catch {
                self.logger.error("voice_memo stop/transcribe failed: \(error)")
                // Surface the underlying reason so failures are diagnosable from
                // the pill itself (e.g. "No meeting audio was captured", a
                // convert/STT error) rather than a generic message that hides
                // the failing stage. MeetingAudioError is LocalizedError, so
                // localizedDescription already yields its human-readable text.
                self.pillViewModel?.state = .error(error.localizedDescription)
                self.scheduleAutoDismiss(after: 6)
            }
        }
    }

    private func showPill() {
        let vm = VoiceMemoPillViewModel()
        vm.state = .recording
        vm.onStop = { [weak self] in self?.stopRecording() }
        pillViewModel = vm

        if pillController == nil {
            pillController = VoiceMemoPillController(viewModel: vm)
        }
        pillController?.show()
    }

    private func hidePill() {
        stopPillPolling()
        pillController?.hide()
        pillController = nil
        pillViewModel = nil
    }

    private func returnToIdle() {
        hidePill()
        state = .idle
        onFlowReturnedToIdle()
    }

    private func startPillPolling() {
        pillPollingTask?.cancel()
        pillPollingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let micLevel = await meetingRecordingService.micLevel
                let elapsedSeconds = await meetingRecordingService.elapsedSeconds
                guard !Task.isCancelled else { break }
                pillViewModel?.micLevel = micLevel
                pillViewModel?.elapsedSeconds = elapsedSeconds
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    private func stopPillPolling() {
        pillPollingTask?.cancel()
        pillPollingTask = nil
    }

    private func scheduleAutoDismiss(after seconds: Double) {
        autoDismissTask?.cancel()
        autoDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.returnToIdle()
        }
    }

    private func showPermissionAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Microphone Access Required"
        alert.informativeText = "Voice memo recording needs microphone access to capture audio."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            permissionService.openMicrophoneSettings()
        }
    }

    private static func defaultTitle() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return "Voice Memo – \(formatter.string(from: Date()))"
    }
}
