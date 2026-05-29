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
    private let quickPromptRepo: QuickPromptRepositoryProtocol
    private let configStore: LLMConfigStoreProtocol
    private let llmService: LLMServiceProtocol?
    // Transcription is handed to the shared background processor on stop so the
    // pill frees immediately and a new memo/meeting can start without waiting
    // for the (potentially multi-minute) transcript.
    private let backgroundProcessor: MeetingBackgroundProcessor
    private let isMeetingRecordingActive: @MainActor () -> Bool
    private let onRecordingBegan: () -> Void
    private let onFlowReturnedToIdle: () -> Void

    private var pillController: VoiceMemoPillController?
    private var pillViewModel: VoiceMemoPillViewModel?
    // Voice memos reuse the meeting live panel (Notes / Transcript / Ask) so a
    // user can watch the live Parakeet transcript and ask their LLM about the
    // memo-so-far — same surface meetings get, retitled "Voice Memo".
    private var panelViewModel: MeetingRecordingPanelViewModel?
    private var panelController: MeetingRecordingPanelController?
    private var actionTask: Task<Void, Never>?
    private var pillPollingTask: Task<Void, Never>?
    private var transcriptObservationTask: Task<Void, Never>?
    private var pauseToggleTask: Task<Void, Never>?
    private var microphoneMuteToggleTask: Task<Void, Never>?
    private var autoDismissTask: Task<Void, Never>?

    private let logger = Logger(subsystem: "com.macparakeet", category: "VoiceMemoFlow")

    init(
        meetingRecordingService: MeetingRecordingServiceProtocol,
        transcriptionService: TranscriptionServiceProtocol,
        permissionService: PermissionServiceProtocol,
        libraryViewModel: TranscriptionLibraryViewModel,
        quickPromptRepo: QuickPromptRepositoryProtocol,
        configStore: LLMConfigStoreProtocol,
        llmService: LLMServiceProtocol?,
        backgroundProcessor: MeetingBackgroundProcessor,
        isMeetingRecordingActive: @escaping @MainActor () -> Bool = { false },
        onRecordingBegan: @escaping () -> Void = {},
        onFlowReturnedToIdle: @escaping () -> Void = {}
    ) {
        self.meetingRecordingService = meetingRecordingService
        self.transcriptionService = transcriptionService
        self.permissionService = permissionService
        self.libraryViewModel = libraryViewModel
        self.quickPromptRepo = quickPromptRepo
        self.configStore = configStore
        self.llmService = llmService
        self.backgroundProcessor = backgroundProcessor
        self.isMeetingRecordingActive = isMeetingRecordingActive
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
                self.panelViewModel?.updateLiveTranscriptStatus(.listening)
                self.startPillPolling()
                self.startTranscriptObservation()
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
        stopTranscriptObservation()
        pillViewModel?.state = .transcribing
        panelViewModel?.state = .transcribing
        // The memo is over; the live panel has nothing more to show. Closing it
        // mirrors the meeting flow (the panel is a live-recording surface).
        hidePanel()

        // Capture notes + carried Ask-tab chat before the panel tears down so
        // they persist onto the transcription (same path as meetings).
        let notes = panelViewModel?.notesViewModel.notesText
        let carriedChat = panelViewModel?.chatViewModel.liveChatHistorySnapshot() ?? []
        let liveWordCount = panelViewModel?.wordCount ?? 0

        actionTask = Task { @MainActor in
            do {
                if let notes { await self.meetingRecordingService.updateNotes(notes) }
                // Finalize audio (fast — just mux/close files), then hand the
                // transcription to the shared background processor and free the
                // pill immediately. This lets the user start a new memo/meeting
                // right away instead of waiting minutes for the transcript.
                let output = try await self.meetingRecordingService.stopRecording()
                self.backgroundProcessor.process(
                    output: output,
                    operationContext: ObservabilityOperationContext(),
                    trigger: nil,
                    liveWordCount: liveWordCount,
                    liveTranscriptLagged: false,
                    shouldAutoGenerateTitle: false,
                    carriedChat: carriedChat
                )
                self.returnToIdle()
            } catch {
                self.logger.error("voice_memo stop/handoff failed: \(error)")
                // Surface the underlying reason (e.g. "No meeting audio was
                // captured.") rather than a generic message. MeetingAudioError
                // is LocalizedError, so localizedDescription is human-readable.
                self.pillViewModel?.state = .error(error.localizedDescription)
                self.scheduleAutoDismiss(after: 6)
            }
        }
    }

    func togglePause() {
        guard state == .recording else { return }
        let wantPause = !(panelViewModel?.isPaused ?? false)
        pauseToggleTask?.cancel()
        pauseToggleTask = Task { @MainActor [meetingRecordingService, weak self] in
            if wantPause {
                await meetingRecordingService.pauseRecording()
            } else {
                await meetingRecordingService.resumeRecording()
            }
            guard !Task.isCancelled, let self, self.state == .recording else { return }
            self.panelViewModel?.isPaused = wantPause
        }
    }

    func toggleMicrophoneMute() {
        guard state == .recording, panelViewModel?.canToggleMicrophoneMute == true else { return }
        let wantMuted = !(panelViewModel?.isMicrophoneMuted ?? false)
        microphoneMuteToggleTask?.cancel()
        microphoneMuteToggleTask = Task { @MainActor [meetingRecordingService, weak self] in
            let muteState = await meetingRecordingService.setMicrophoneMuted(wantMuted)
            guard !Task.isCancelled, let self else { return }
            self.panelViewModel?.isMicrophoneMuted = muteState.isMuted
            self.panelViewModel?.canToggleMicrophoneMute = muteState.canMute
        }
    }

    private func showPill() {
        let vm = VoiceMemoPillViewModel()
        vm.state = .recording
        vm.onStop = { [weak self] in self?.stopRecording() }
        vm.onTap = { [weak self] in self?.showPanel() }
        pillViewModel = vm

        if pillController == nil {
            pillController = VoiceMemoPillController(viewModel: vm)
        }
        pillController?.show()

        setupPanel()
    }

    private func setupPanel() {
        let panelVM = MeetingRecordingPanelViewModel()
        panelVM.state = .recording
        panelVM.elapsedSeconds = 0
        panelVM.micLevel = 0
        panelVM.systemLevel = 0
        panelVM.isPaused = false
        panelVM.isMicrophoneMuted = false
        panelVM.canToggleMicrophoneMute = true
        // Voice-memo header shows the red pulsing dot, not the meeting orb.
        panelVM.usesVoiceMemoIndicator = true
        // Open straight to the live transcript — the reason a user taps the pill.
        panelVM.selectedTab = .transcript
        panelVM.updateLiveTranscriptStatus(.startingAudio)
        panelVM.updatePreviewLines([], isTranscriptionLagging: false)
        panelVM.onStop = { [weak self] in self?.stopRecording() }
        panelVM.onPauseToggle = { [weak self] in self?.togglePause() }
        panelVM.onMicrophoneMuteToggle = { [weak self] in self?.toggleMicrophoneMute() }
        panelVM.onClose = { [weak self] in self?.hidePanel() }
        // Live Ask in in-memory mode (no transcriptionId/conversationRepo); the
        // memo's transcript is fed live via updatePreviewLines below.
        panelVM.chatViewModel.configure(
            llmService: llmService,
            transcriptText: panelVM.chatTranscript,
            configStore: configStore
        )
        panelVM.quickPromptsViewModel.configure(repo: quickPromptRepo)
        panelVM.notesViewModel.bindPersist { [weak self] notes in
            await self?.meetingRecordingService.updateNotes(notes)
        }
        panelViewModel = panelVM

        let controller = MeetingRecordingPanelController(
            viewModel: panelVM,
            title: "Voice Memo",
            frameAutosaveName: "VoiceMemoPanel"
        )
        controller.onCloseRequested = { [weak self] in self?.hidePanel() }
        panelController = controller
    }

    private func showPanel() {
        guard state == .recording else { return }
        panelController?.show()
    }

    private func hidePanel() {
        panelController?.hide()
    }

    private func hidePill() {
        stopPillPolling()
        stopTranscriptObservation()
        pillController?.hide()
        pillController = nil
        pillViewModel = nil
        panelController?.close()
        panelController = nil
        panelViewModel = nil
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
                panelViewModel?.micLevel = micLevel
                panelViewModel?.elapsedSeconds = elapsedSeconds
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    private func stopPillPolling() {
        pillPollingTask?.cancel()
        pillPollingTask = nil
    }

    private func startTranscriptObservation() {
        transcriptObservationTask?.cancel()
        transcriptObservationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = await meetingRecordingService.transcriptUpdates
            for await update in stream {
                guard !Task.isCancelled else { break }
                let previewLines = await Task.detached(priority: .utility) {
                    Self.makePreviewLines(from: update)
                }.value
                guard !Task.isCancelled else { break }
                panelViewModel?.updatePreviewLines(
                    previewLines,
                    isTranscriptionLagging: update.isTranscriptionLagging
                )
            }
        }
    }

    private func stopTranscriptObservation() {
        transcriptObservationTask?.cancel()
        transcriptObservationTask = nil
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

    nonisolated private static func makePreviewLines(from update: MeetingTranscriptUpdate) -> [MeetingRecordingPreviewLine] {
        let speakerLabels = Dictionary(uniqueKeysWithValues: update.speakers.map { ($0.id, $0.label) })
        let segments = TranscriptSegmenter.groupIntoSegments(words: update.words)
        return segments.map { segment in
            let source = segment.speakerId.flatMap(AudioSource.init(rawValue:))
            return MeetingRecordingPreviewLine(
                id: "\(segment.startMs)-\(segment.speakerId ?? "unknown")",
                timestamp: format(milliseconds: segment.startMs),
                speakerLabel: speakerLabels[segment.speakerId ?? ""] ?? source?.displayLabel ?? "Speaker",
                text: segment.text,
                source: source
            )
        }
    }

    nonisolated private static func format(milliseconds: Int) -> String {
        let totalSeconds = max(0, milliseconds / 1000)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private static func defaultTitle() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return "Voice Memo – \(formatter.string(from: Date()))"
    }
}
