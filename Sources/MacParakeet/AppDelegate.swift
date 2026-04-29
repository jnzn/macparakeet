import AppKit
import MacParakeetCore
import MacParakeetViewModels

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: - Runtime Services

    private var appEnvironment: AppEnvironment?
    private var hotkeyCoordinator: AppHotkeyCoordinator?
    private var dictationFlowCoordinator: DictationFlowCoordinator?
    private var meetingRecordingFlowCoordinator: MeetingRecordingFlowCoordinator?
    private var aiAssistantFlowCoordinator: AIAssistantFlowCoordinator?
    private var meetingAutoStartCoordinator: MeetingAutoStartCoordinator?
    private var hasPresentedHotkeyUnavailableAlert = false
    private var environmentSetupTask: Task<Void, Never>?
    private var meetingQuitTask: Task<Void, Never>?

    // MARK: - View Models

    private let transcriptionViewModel = TranscriptionViewModel()
    private let historyViewModel = DictationHistoryViewModel()
    private let settingsViewModel = SettingsViewModel()
    private let customWordsViewModel = CustomWordsViewModel()
    private let textSnippetsViewModel = TextSnippetsViewModel()
    private let vocabularyBackupViewModel = VocabularyBackupViewModel()
    private let feedbackViewModel = FeedbackViewModel()
    private let libraryViewModel = TranscriptionLibraryViewModel()
    private let meetingsViewModel = TranscriptionLibraryViewModel(scope: .meetings)
    private let llmSettingsViewModel = LLMSettingsViewModel()
    private let aiAssistantSettingsViewModel = AIAssistantSettingsViewModel()
    private let chatViewModel = TranscriptChatViewModel()
    private let promptResultsViewModel = PromptResultsViewModel()
    private let promptsViewModel = PromptsViewModel()
    private let mainWindowState = MainWindowState()
    private let onboardingWindowController = OnboardingWindowController()

    private lazy var youtubeInputController = YouTubeInputPanelController(
        transcriptionViewModel: transcriptionViewModel
    )

    // MARK: - Coordinators

    private let startupBootstrapper = AppStartupBootstrapper()

    private lazy var environmentConfigurer = AppEnvironmentConfigurer(
        transcriptionViewModel: transcriptionViewModel,
        historyViewModel: historyViewModel,
        settingsViewModel: settingsViewModel,
        customWordsViewModel: customWordsViewModel,
        textSnippetsViewModel: textSnippetsViewModel,
        vocabularyBackupViewModel: vocabularyBackupViewModel,
        libraryViewModel: libraryViewModel,
        meetingsViewModel: meetingsViewModel,
        llmSettingsViewModel: llmSettingsViewModel,
        aiAssistantSettingsViewModel: aiAssistantSettingsViewModel,
        chatViewModel: chatViewModel,
        promptResultsViewModel: promptResultsViewModel,
        promptsViewModel: promptsViewModel,
        mainWindowState: mainWindowState
    )

    private lazy var onboardingCoordinator = OnboardingCoordinator(
        onboardingWindowController: onboardingWindowController,
        onRefreshHotkeys: { [weak self] in
            self?.hotkeyCoordinator?.refreshAllHotkeys()
            self?.menuBarCoordinator.refreshHotkeyTitle()
            self?.menuBarCoordinator.refreshMeetingHotkeyShortcut()
            self?.menuBarCoordinator.refreshTranscriptionHotkeyShortcuts()
        },
        onOpenMainWindow: { [weak self] in
            self?.windowCoordinator.openMainWindow()
        },
        onOpenSettings: { [weak self] in
            self?.windowCoordinator.openMainWindowToSettings()
        }
    )

    private lazy var meetingRecoveryCoordinator = MeetingRecoveryCoordinator(
        environmentProvider: { [weak self] in
            self?.appEnvironment
        },
        settingsViewModel: settingsViewModel,
        libraryViewModel: libraryViewModel,
        meetingsViewModel: meetingsViewModel,
        onPresentRecoveredTranscription: { [weak self] transcription in
            guard let self else { return }
            self.transcriptionViewModel.presentCompletedTranscription(transcription, autoSave: true)
            self.mainWindowState.navigateToTranscription(from: .meetings)
            self.windowCoordinator.openMainWindow()
        }
    )

    private lazy var windowCoordinator = AppWindowCoordinator(
        mainWindowState: mainWindowState,
        transcriptionViewModel: transcriptionViewModel,
        historyViewModel: historyViewModel,
        settingsViewModel: settingsViewModel,
        llmSettingsViewModel: llmSettingsViewModel,
        aiAssistantSettingsViewModel: aiAssistantSettingsViewModel,
        chatViewModel: chatViewModel,
        promptResultsViewModel: promptResultsViewModel,
        promptsViewModel: promptsViewModel,
        customWordsViewModel: customWordsViewModel,
        textSnippetsViewModel: textSnippetsViewModel,
        vocabularyBackupViewModel: vocabularyBackupViewModel,
        feedbackViewModel: feedbackViewModel,
        libraryViewModel: libraryViewModel,
        meetingsViewModel: meetingsViewModel,
        onRecordMeeting: { [weak self] in
            self?.toggleMeetingRecording(originatesFromWindow: true)
        },
        onQuit: { [weak self] in
            self?.quitApp()
        },
        isOnboardingVisible: { [weak self] in
            self?.onboardingWindowController.isVisible ?? false
        }
    )

    private lazy var menuBarCoordinator = MenuBarCoordinator(
        transcriptionViewModel: transcriptionViewModel,
        youtubeInputController: youtubeInputController,
        environmentProvider: { [weak self] in
            self?.appEnvironment
        },
        hotkeyMenuTitleProvider: { [weak self] in
            self?.hotkeyMenuTitle ?? AppHotkeyCoordinator.menuTitle(for: HotkeyTrigger.current)
        },
        meetingHotkeyTriggerProvider: { [weak self] in
            self?.settingsViewModel.meetingHotkeyTrigger ?? .defaultMeetingRecording
        },
        fileTranscriptionHotkeyTriggerProvider: { [weak self] in
            self?.settingsViewModel.fileTranscriptionHotkeyTrigger ?? .disabled
        },
        youtubeTranscriptionHotkeyTriggerProvider: { [weak self] in
            self?.settingsViewModel.youtubeTranscriptionHotkeyTrigger ?? .disabled
        },
        meetingRecordingActiveProvider: { [weak self] in
            self?.meetingRecordingFlowCoordinator?.isMeetingRecordingActive == true
        },
        onOpenMainWindow: { [weak self] in
            self?.windowCoordinator.openMainWindow()
        },
        onOpenSettings: { [weak self] in
            self?.windowCoordinator.openMainWindowToSettings()
        },
        onToggleMeetingRecording: { [weak self] in
            self?.toggleMeetingRecording(originatesFromWindow: false)
        },
        onQuit: { [weak self] in
            self?.quitApp()
        },
        onShowAboutPanel: { [weak self] in
            self?.showAboutPanel()
        }
    )

    private lazy var settingsObserverCoordinator = AppSettingsObserverCoordinator(
        onOpenOnboarding: { [weak self] in
            guard let self else { return }
            self.onboardingCoordinator.show(environment: self.appEnvironment)
        },
        onOpenSettings: { [weak self] in
            self?.windowCoordinator.openMainWindowToSettings()
        },
        onHotkeyTriggerChanged: { [weak self] in
            self?.handleHotkeyTriggerChange()
        },
        onMeetingHotkeyTriggerChanged: { [weak self] in
            self?.handleMeetingHotkeyTriggerChange()
        },
        onFileTranscriptionHotkeyTriggerChanged: { [weak self] in
            self?.handleFileTranscriptionHotkeyTriggerChange()
        },
        onYouTubeTranscriptionHotkeyTriggerChanged: { [weak self] in
            self?.handleYouTubeTranscriptionHotkeyTriggerChange()
        },
        onMenuBarOnlyModeChanged: { [weak self] in
            self?.windowCoordinator.applyActivationPolicyFromSettings()
        },
        onShowIdlePillChanged: { [weak self] in
            self?.handleShowIdlePillChange()
        }
    )

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        if isRunningFromDiskImage() {
            showMoveToApplicationsAlert()
            return
        }

        // Resolve the user's full login-shell PATH off the launch path so
        // any later `LocalCLIExecutor.resolve(binary:)` (AI Assistant
        // onboarding, settings test connection, AI bubble ask) finds the
        // cached value instead of stalling up to 10s on the shell probe.
        LocalCLIExecutor.preWarmPATHCache()

        startEnvironmentSetup()
        menuBarCoordinator.setupMainMenu()
        menuBarCoordinator.setupMenuBar()
        settingsObserverCoordinator.startObserving()
        windowCoordinator.applyActivationPolicyFromSettings()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Telemetry.flushForTermination() is handled by TelemetryService's own
        // NSApplicationWillTerminateNotification observer — calling it here too
        // would send duplicate appQuit events and double the termination delay.
        dictationFlowCoordinator?.hideIdlePill()
        aiAssistantFlowCoordinator?.dismissAny()
        hotkeyCoordinator?.stopAll()
        meetingAutoStartCoordinator?.stop()
        settingsObserverCoordinator.stopObserving()
        environmentSetupTask?.cancel()

        // Bound the wait so termination does not hang, while still giving shutdown
        // a brief window to release resources cleanly.
        if let sttScheduler = appEnvironment?.sttScheduler {
            let done = DispatchSemaphore(value: 0)
            Task.detached(priority: .utility) {
                await sttScheduler.shutdown()
                done.signal()
            }
            _ = done.wait(timeout: .now() + 0.35)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Don't quit when window closes — dictation/menu bar features stay available.
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard meetingRecordingFlowCoordinator?.quitState != nil else {
            return .terminateNow
        }

        guard meetingQuitTask == nil else {
            return .terminateCancel
        }

        return presentActiveMeetingQuitAlert()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        windowCoordinator.handleAppReopen()
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        windowCoordinator.makeDockMenu()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        onboardingCoordinator.handleApplicationDidBecomeActive(environment: appEnvironment)
    }

    // MARK: - Startup

    private func startEnvironmentSetup() {
        environmentSetupTask?.cancel()
        environmentSetupTask = Task { [weak self] in
            guard let self else { return }
            do {
                let env = try await startupBootstrapper.bootstrapEnvironment()
                guard !Task.isCancelled else { return }
                setupEnvironment(env)
            } catch is CancellationError {
                return
            } catch {
                presentEnvironmentSetupError(error)
            }
        }
    }

    private func setupEnvironment(_ env: AppEnvironment) {
        appEnvironment = env

        // Warm up the STT models in the background. Parakeet CoreML compilation
        // takes ~3–5 s from disk cache, and the first actual inference adds
        // ~500 ms–2 s for ANE JIT warmup. Users typically launch the app and
        // dictate within 30–60 s, so prefetching while the UI boots turns the
        // first-dictation wait from 5–30 s into sub-second. Best-effort — any
        // failure surfaces later on the actual transcription path.
        //
        // Also warm up the AVAudioEngine / CoreAudio HAL. The first call to
        // engine.start() in a process fails reliably with
        // `com.apple.coreaudio.avfaudio error 2003329396` (cold-start race).
        // A throwaway start → stop here primes the HAL so the user's first
        // real dictation / AI-assistant invocation doesn't hit the error.
        // Runs after a short delay so the UI doesn't compete with the audio
        // engine for main-thread work during the first frame.
        Task.detached(priority: .utility) { [env] in
            await env.sttScheduler.backgroundWarmUp()
            if env.runtimePreferences.streamingOverlayEnabled {
                try? await env.streamingDictationTranscriber.loadModels()
            }
            try? await Task.sleep(for: .seconds(1))
            await Self.warmUpAudioEngine(audioProcessor: env.audioProcessor)
        }

        let runtime = environmentConfigurer.configure(
            environment: env,
            callbacks: .init(
                onMenuBarIconUpdate: { [weak self] in
                    self?.resolveAndUpdateMenuBarIcon()
                },
                onPresentEntitlementsAlert: { [weak self] error in
                    self?.presentEntitlementsAlert(error)
                },
                onOpenMainWindow: { [weak self] in
                    self?.windowCoordinator.openMainWindow()
                },
                onToggleMeetingRecordingFromHotkey: { [weak self] in
                    self?.toggleMeetingRecording(originatesFromWindow: false, trigger: .hotkey)
                },
                onTriggerFileTranscriptionFromHotkey: { [weak self] in
                    self?.triggerFileTranscriptionFromHotkey()
                },
                onTriggerYouTubeTranscriptionFromHotkey: { [weak self] in
                    self?.triggerYouTubeTranscriptionFromHotkey()
                },
                onHotkeyBecameAvailable: { [weak self] in
                    self?.hasPresentedHotkeyUnavailableAlert = false
                },
                onHotkeyUnavailable: { [weak self] in
                    self?.presentHotkeyUnavailableAlertIfNeeded()
                },
                onRecoverPendingMeetingRecordings: { [weak self] in
                    self?.meetingRecoveryCoordinator.presentPendingMeetingRecoveryDialog()
                }
            )
        )

        dictationFlowCoordinator = runtime.dictationFlowCoordinator
        meetingRecordingFlowCoordinator = runtime.meetingRecordingFlowCoordinator
        aiAssistantFlowCoordinator = runtime.aiAssistantFlowCoordinator
        hotkeyCoordinator = runtime.hotkeyCoordinator
        meetingAutoStartCoordinator = runtime.meetingAutoStartCoordinator

        menuBarCoordinator.refreshHotkeyTitle()
        menuBarCoordinator.refreshMeetingHotkeyShortcut()
        menuBarCoordinator.refreshTranscriptionHotkeyShortcuts()
        onboardingCoordinator.maybeShow(environment: env)
        meetingRecoveryCoordinator.scheduleLaunchRecoveryScanIfReady(environment: env)
    }

    /// Primes the AVAudioEngine/CoreAudio HAL with a tiny start→stop cycle so
    /// the user's first real dictation doesn't hit the cold-start 2003329396
    /// error. Best-effort: mic permission may not be granted yet (pre-onboarding)
    /// or the audio system may legitimately be in use — in either case we just
    /// swallow the error and let the real dictation path handle it.
    private static func warmUpAudioEngine(audioProcessor: AudioProcessor) async {
        do {
            try await audioProcessor.startCapture()
            // Immediately stop. `stop()` throws `insufficientSamples` when
            // the recording is < 1s — ignore that, we don't want the WAV.
            let url = try? await audioProcessor.stopCapture()
            if let url {
                try? FileManager.default.removeItem(at: url)
            }
        } catch {
            // Permission not granted, device in use, or another legit failure.
            // Silent — real invocations surface their own errors.
        }
    }

    private func presentEnvironmentSetupError(_ error: Error) {
        // Don't silently fail. Without a valid environment, the app can't function.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "MacParakeet Failed to Start"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "Quit")
        _ = alert.runModal()

        NSApp.terminate(nil)
    }

    // MARK: - Disk Image Guard

    private func isRunningFromDiskImage() -> Bool {
        Bundle.main.bundlePath.hasPrefix("/Volumes/")
    }

    private func showMoveToApplicationsAlert() {
        let alert = NSAlert()
        alert.messageText = "Move to Applications"
        alert.informativeText = "MacParakeet must be in your Applications folder to work correctly. " +
            "Running from a disk image prevents macOS from granting microphone and accessibility permissions.\n\n" +
            "Drag MacParakeet to the Applications folder in the DMG window, then launch it from there."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.runModal()

        NSApp.terminate(nil)
    }

    // MARK: - Event Handlers

    private func handleHotkeyTriggerChange() {
        hotkeyCoordinator?.refreshAllHotkeys()
        menuBarCoordinator.refreshHotkeyTitle()
        menuBarCoordinator.refreshMeetingHotkeyShortcut()
    }

    /// Any auxiliary hotkey change refreshes all three auxiliary hotkeys so a
    /// newly-claimed trigger can disable a now-colliding peer without waiting
    /// for the user to visit Settings again.
    private func handleMeetingHotkeyTriggerChange() {
        refreshAuxiliaryHotkeys()
    }

    private func handleFileTranscriptionHotkeyTriggerChange() {
        refreshAuxiliaryHotkeys()
    }

    private func handleYouTubeTranscriptionHotkeyTriggerChange() {
        refreshAuxiliaryHotkeys()
    }

    private func refreshAuxiliaryHotkeys() {
        hotkeyCoordinator?.refreshMeetingHotkey()
        hotkeyCoordinator?.refreshFileTranscriptionHotkey()
        hotkeyCoordinator?.refreshYouTubeTranscriptionHotkey()
        menuBarCoordinator.refreshMeetingHotkeyShortcut()
        menuBarCoordinator.refreshTranscriptionHotkeyShortcuts()
    }

    private func triggerFileTranscriptionFromHotkey() {
        guard appEnvironment != nil else { return }
        menuBarCoordinator.invokeTranscribeFileFlow()
    }

    private func triggerYouTubeTranscriptionFromHotkey() {
        guard appEnvironment != nil else { return }
        menuBarCoordinator.invokeTranscribeYouTubeFlow()
    }

    private func handleShowIdlePillChange() {
        if settingsViewModel.showIdlePill {
            dictationFlowCoordinator?.showIdlePill()
        } else {
            dictationFlowCoordinator?.hideIdlePill()
        }
    }

    private var hotkeyMenuTitle: String {
        hotkeyCoordinator?.hotkeyMenuTitle
            ?? AppHotkeyCoordinator.menuTitle(for: HotkeyTrigger.current)
    }

    // MARK: - Menu Bar Icon State

    /// Priority-based menu bar icon resolver (ADR-015).
    /// Meeting recording > dictation menu-bar preference > file transcription > idle.
    ///
    /// Uses `menuBarPreference` from the dictation flow (state-machine-aware) so
    /// `.processing` can render correctly and terminal states do not linger red.
    private func resolveAndUpdateMenuBarIcon() {
        let state = Self.resolveMenuBarState(
            isMeetingRecordingActive: meetingRecordingFlowCoordinator?.isMeetingRecordingActive == true,
            dictationMenuBarPreference: dictationFlowCoordinator?.menuBarPreference,
            isTranscribing: transcriptionViewModel.isTranscribing
        )
        menuBarCoordinator.updateIcon(state: state)
    }

    static func resolveMenuBarState(
        isMeetingRecordingActive: Bool,
        dictationMenuBarPreference: BreathWaveIcon.MenuBarState?,
        isTranscribing: Bool
    ) -> BreathWaveIcon.MenuBarState {
        if isMeetingRecordingActive {
            return .recording
        }
        if let dictationMenuBarPreference, dictationMenuBarPreference != .idle {
            return dictationMenuBarPreference
        }
        if isTranscribing {
            return .processing
        }
        return .idle
    }

    // MARK: - Meeting Recording

    private func toggleMeetingRecording(
        originatesFromWindow: Bool,
        trigger: TelemetryMeetingRecordingTrigger = .manual
    ) {
        guard appEnvironment != nil else { return }

        if meetingRecordingFlowCoordinator?.isMeetingRecordingActive == true {
            meetingRecordingFlowCoordinator?.toggleRecording()
            return
        }

        if originatesFromWindow {
            mainWindowState.selectedItem = .meetings
            windowCoordinator.openMainWindow()
        }

        meetingRecordingFlowCoordinator?.toggleRecording(trigger: trigger)
    }

    private func presentActiveMeetingQuitAlert() -> NSApplication.TerminateReply {
        guard let quitState = meetingRecordingFlowCoordinator?.quitState else {
            return .terminateNow
        }

        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning

        switch quitState {
        case .starting:
            alert.messageText = "Meeting Recording Is Starting"
            alert.informativeText = "Cancel the pending recording before quitting, or keep MacParakeet open."
            alert.addButton(withTitle: "Cancel Recording & Quit")
            alert.addButton(withTitle: "Cancel Quit")
            if alert.buttons.indices.contains(0) {
                alert.buttons[0].hasDestructiveAction = true
            }
            if alert.runModal() == .alertFirstButtonReturn {
                finishMeetingThenQuit(discard: true)
            }

        case .recording:
            alert.messageText = "Meeting Recording in Progress"
            alert.informativeText = "End and transcribe the meeting before quitting, discard the recording, or keep MacParakeet open."
            alert.addButton(withTitle: "End & Transcribe")
            alert.addButton(withTitle: "Discard Recording")
            alert.addButton(withTitle: "Cancel Quit")
            if alert.buttons.indices.contains(1) {
                alert.buttons[1].hasDestructiveAction = true
            }
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                finishMeetingThenQuit(discard: false)
            case .alertSecondButtonReturn:
                finishMeetingThenQuit(discard: true)
            default:
                break
            }

        case .finishing:
            alert.messageText = "Meeting Transcription in Progress"
            alert.informativeText = "MacParakeet is saving the meeting. Finish transcription before quitting, or keep the app open."
            alert.addButton(withTitle: "Finish & Quit")
            alert.addButton(withTitle: "Cancel Quit")
            if alert.runModal() == .alertFirstButtonReturn {
                finishMeetingThenQuit(discard: false)
            }
        }

        return .terminateCancel
    }

    private func finishMeetingThenQuit(discard: Bool) {
        guard let coordinator = meetingRecordingFlowCoordinator else { return }

        meetingQuitTask?.cancel()
        meetingQuitTask = Task { @MainActor [weak self, coordinator] in
            if discard {
                await coordinator.discardRecordingAndWaitForCompletion()
            } else {
                await coordinator.stopRecordingAndWaitForCompletion()
            }
            guard !Task.isCancelled else { return }
            self?.meetingQuitTask = nil
            NSApp.terminate(nil)
        }
    }

    // MARK: - Alerts

    private func presentEntitlementsAlert(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Unlock Required"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Not Now")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            windowCoordinator.openMainWindowToSettings()
        }
    }

    private func presentHotkeyUnavailableAlertIfNeeded() {
        #if !DEBUG
        guard !hasPresentedHotkeyUnavailableAlert else { return }
        guard settingsViewModel.accessibilityGranted == false else { return }
        // Suppress while onboarding is on screen — the user hasn't been
        // asked for Accessibility yet, and the onboarding flow's own
        // accessibility step is the right place to request it.
        guard !onboardingWindowController.isVisible else { return }
        // Suppress on first launch (before onboarding has been completed)
        // — onboarding will show shortly and run its own accessibility
        // request, so this redundant alert just lands before any UI is
        // interactive.
        let completed = UserDefaults.standard.string(forKey: OnboardingViewModel.onboardingCompletedKey) != nil
        guard completed else { return }

        hasPresentedHotkeyUnavailableAlert = true
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Global Hotkey Unavailable"
        alert.informativeText =
            "MacParakeet couldn’t enable the system-wide hotkey because Accessibility access is missing. " +
            "You can still open the app manually, but dictation shortcuts won’t work until this is enabled."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Not Now")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            windowCoordinator.openMainWindowToSettings()
        }
        #endif
    }

    private func showAboutPanel() {
        let repoLink = "https://github.com/moona3k/macparakeet"
        guard let repoURL = URL(string: repoLink) else { return }
        let credits = NSMutableAttributedString()

        let style = NSMutableParagraphStyle()
        style.alignment = .center

        let normalAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .paragraphStyle: style,
        ]
        let linkAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .link: repoURL,
            .paragraphStyle: style,
        ]

        credits.append(NSAttributedString(string: "Free and open source (GPL-3.0)\n", attributes: normalAttributes))
        credits.append(NSAttributedString(string: repoLink, attributes: linkAttributes))

        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    private func quitApp() {
        NSApp.terminate(nil)
    }
}
