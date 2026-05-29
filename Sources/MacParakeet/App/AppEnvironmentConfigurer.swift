import Foundation
import MacParakeetCore
import MacParakeetViewModels

@MainActor
final class AppEnvironmentConfigurer {
    private final class CoordinatorRefs {
        weak var dictation: DictationFlowCoordinator?
        weak var meeting: MeetingRecordingFlowCoordinator?
        weak var voiceMemo: VoiceMemoFlowCoordinator?
    }

    struct Runtime {
        let dictationFlowCoordinator: DictationFlowCoordinator
        let meetingRecordingFlowCoordinator: MeetingRecordingFlowCoordinator
        let voiceMemoFlowCoordinator: VoiceMemoFlowCoordinator
        let hotkeyCoordinator: AppHotkeyCoordinator
        let meetingAutoStartCoordinator: MeetingAutoStartCoordinator?
        let aiAssistantFlowCoordinator: AIAssistantFlowCoordinator
    }

    struct Callbacks {
        let onMenuBarIconUpdate: () -> Void
        let onPresentEntitlementsAlert: (Error) -> Void
        let onOpenMainWindow: () -> Void
        let onToggleMeetingRecordingFromHotkey: () -> Void
        let onTriggerFileTranscriptionFromHotkey: () -> Void
        let onTriggerYouTubeTranscriptionFromHotkey: () -> Void
        let onHotkeyBecameAvailable: () -> Void
        let onHotkeyUnavailable: () -> Void
        let onHotkeyConflict: (HotkeyTrigger, [HotkeyTrigger]) -> Void
        let onRecoverPendingMeetingRecordings: () -> Void
        let isHotkeyRecordingActive: () -> Bool
        /// True while the onboarding window is showing. Used to gate the real
        /// dictation flow so a hotkey press during onboarding (e.g. the "Learn
        /// the Hotkey" rehearsal, or a returning user whose taps are armed)
        /// can never start a real, model-less dictation.
        let isOnboardingVisible: () -> Bool
        /// Number of meetings transcribing in the background changed — drives
        /// the menu-bar "N processing" row and the processing icon state.
        let onMeetingProcessingCountChanged: (Int) -> Void
    }

    private let transcriptionViewModel: TranscriptionViewModel
    private let historyViewModel: DictationHistoryViewModel
    private let settingsViewModel: SettingsViewModel
    private let customWordsViewModel: CustomWordsViewModel
    private let textSnippetsViewModel: TextSnippetsViewModel
    private let vocabularyBackupViewModel: VocabularyBackupViewModel
    private let libraryViewModel: TranscriptionLibraryViewModel
    private let meetingsWorkspaceViewModel: MeetingsWorkspaceViewModel
    private let llmSettingsViewModel: LLMSettingsViewModel
    private let chatViewModel: TranscriptChatViewModel
    private let promptResultsViewModel: PromptResultsViewModel
    private let promptsViewModel: PromptsViewModel
    private let transformsViewModel: TransformsViewModel
    private let mainWindowState: MainWindowState
    private let meetingPillViewModel: MeetingRecordingPillViewModel
    private weak var liveMeetingCoordinator: MeetingRecordingFlowCoordinator?

    init(
        transcriptionViewModel: TranscriptionViewModel,
        historyViewModel: DictationHistoryViewModel,
        settingsViewModel: SettingsViewModel,
        customWordsViewModel: CustomWordsViewModel,
        textSnippetsViewModel: TextSnippetsViewModel,
        vocabularyBackupViewModel: VocabularyBackupViewModel,
        libraryViewModel: TranscriptionLibraryViewModel,
        meetingsWorkspaceViewModel: MeetingsWorkspaceViewModel,
        llmSettingsViewModel: LLMSettingsViewModel,
        chatViewModel: TranscriptChatViewModel,
        promptResultsViewModel: PromptResultsViewModel,
        promptsViewModel: PromptsViewModel,
        transformsViewModel: TransformsViewModel,
        mainWindowState: MainWindowState,
        meetingPillViewModel: MeetingRecordingPillViewModel
    ) {
        self.transcriptionViewModel = transcriptionViewModel
        self.historyViewModel = historyViewModel
        self.settingsViewModel = settingsViewModel
        self.customWordsViewModel = customWordsViewModel
        self.textSnippetsViewModel = textSnippetsViewModel
        self.vocabularyBackupViewModel = vocabularyBackupViewModel
        self.libraryViewModel = libraryViewModel
        self.meetingsWorkspaceViewModel = meetingsWorkspaceViewModel
        self.llmSettingsViewModel = llmSettingsViewModel
        self.chatViewModel = chatViewModel
        self.promptResultsViewModel = promptResultsViewModel
        self.promptsViewModel = promptsViewModel
        self.transformsViewModel = transformsViewModel
        self.mainWindowState = mainWindowState
        self.meetingPillViewModel = meetingPillViewModel
    }

    func configure(environment env: AppEnvironment, callbacks: Callbacks) -> Runtime {
        Task {
            // Only bootstrap trial if onboarding is already completed (returning user).
            // For new users, trial starts at onboarding completion, not during setup.
            let onboardingDone = UserDefaults.standard.string(forKey: OnboardingViewModel.onboardingCompletedKey) != nil
            if onboardingDone {
                await env.entitlementsService.bootstrapTrialIfNeeded()
            }
            await env.entitlementsService.refreshValidationIfNeeded()
        }

        let hasLLMConfig = (try? env.llmConfigStore.loadConfig()) != nil

        transcriptionViewModel.configure(
            transcriptionService: env.transcriptionService,
            transcriptionRepo: env.transcriptionRepo,
            llmService: hasLLMConfig ? env.llmService : nil,
            promptResultRepo: env.promptResultRepo,
            promptResultsViewModel: promptResultsViewModel
        )
        historyViewModel.configure(dictationRepo: env.dictationRepo)
        libraryViewModel.configure(
            transcriptionRepo: env.transcriptionRepo,
            llmService: hasLLMConfig ? env.llmService : nil
        )
        meetingsWorkspaceViewModel.configure(
            transcriptionRepo: env.transcriptionRepo,
            quickPromptRepo: env.quickPromptRepo
        )
        settingsViewModel.configure(
            permissionService: env.permissionService,
            dictationRepo: env.dictationRepo,
            transcriptionRepo: env.transcriptionRepo,
            transformHistoryRepo: env.transformHistoryRepo,
            entitlementsService: env.entitlementsService,
            launchAtLoginService: env.launchAtLoginService,
            checkoutURL: env.checkoutURL,
            customWordRepo: env.customWordRepo,
            snippetRepo: env.snippetRepo,
            sttClient: env.sttScheduler,
            speechEngineSwitcher: env.sttScheduler,
            speechEngineSwitchAvailabilityProvider: env.sttScheduler,
            meetingRecoveryService: env.meetingRecordingRecoveryService,
            sharedMicStream: env.sharedMicStream
        )
        settingsViewModel.onRecoverPendingMeetingRecordings = callbacks.onRecoverPendingMeetingRecordings
        customWordsViewModel.configure(repo: env.customWordRepo)
        textSnippetsViewModel.configure(repo: env.snippetRepo)
        let vocabularyBackupService = VocabularyImportExportService(
            customWordRepo: env.customWordRepo,
            snippetRepo: env.snippetRepo,
            dbQueue: env.databaseManager.dbQueue
        )
        vocabularyBackupViewModel.configure(service: vocabularyBackupService) { [weak self] in
            self?.customWordsViewModel.loadWords()
            self?.textSnippetsViewModel.loadSnippets()
            self?.settingsViewModel.refreshStats()
        }
        promptsViewModel.configure(repo: env.promptRepo)
        transformsViewModel.configure(
            repo: env.promptRepo,
            historyRepo: env.transformHistoryRepo,
            clipboardService: env.clipboardService,
            hasLLMProvider: hasLLMConfig
        )
        llmSettingsViewModel.configure(
            configStore: env.llmConfigStore,
            llmClient: env.llmClient
        )

        settingsViewModel.onDictationStateChanged = { [weak self] in
            self?.historyViewModel.loadDictations()
        }
        settingsViewModel.onTransformHistoryChanged = { [weak self] in
            Task {
                await self?.transformsViewModel.loadHistory()
            }
        }

        llmSettingsViewModel.onConfigurationChanged = { [weak self] in
            self?.refreshLLMAvailability(in: env)
        }

        chatViewModel.configure(
            llmService: hasLLMConfig ? env.llmService : nil,
            transcriptText: "",
            transcriptionRepo: env.transcriptionRepo,
            configStore: env.llmConfigStore,
            llmClient: env.llmClient,
            conversationRepo: env.chatConversationRepo
        )

        promptResultsViewModel.configure(
            llmService: hasLLMConfig ? env.llmService : nil,
            promptRepo: env.promptRepo,
            promptResultRepo: env.promptResultRepo,
            // Without this, `fetchUserNotes` short-circuits to `nil`, which
            // would silently render `{{userNotes}}` as an empty string in any
            // user-defined prompt that references it, and feed `nil` userNotes
            // into the chat path that ADR-020's 2026-05-02 amendment relies on.
            transcriptionRepo: env.transcriptionRepo,
            configStore: env.llmConfigStore,
            llmClient: env.llmClient
        )

        chatViewModel.onConversationsChanged = { [weak self] transcriptionID, hasConversations in
            self?.transcriptionViewModel.updateConversationStatus(
                id: transcriptionID,
                hasConversations: hasConversations
            )
        }

        chatViewModel.onModelChanged = { [weak self] in
            self?.promptResultsViewModel.refreshModelInfo()
        }

        promptResultsViewModel.onModelChanged = { [weak self] in
            self?.chatViewModel.refreshModelInfo()
        }

        promptResultsViewModel.onPromptResultsChanged = { [weak self] transcriptionID, hasPromptResults in
            guard self?.transcriptionViewModel.currentTranscription?.id == transcriptionID else { return }
            self?.transcriptionViewModel.hasPromptResultTabs = hasPromptResults
        }

        promptResultsViewModel.onGenerationCompleted = { [weak self] generationID, promptResultID in
            self?.transcriptionViewModel.handleGenerationCompleted(generationID, promptResultID: promptResultID)
        }

        promptResultsViewModel.onGenerationFailed = { [weak self] generationID, replacingPromptResultID in
            self?.transcriptionViewModel.handleGenerationFailed(
                generationID,
                replacingPromptResultID: replacingPromptResultID
            )
        }

        promptResultsViewModel.onDeletedPromptResult = { [weak self] promptResultID in
            self?.transcriptionViewModel.handlePromptResultDeleted(promptResultID)
        }

        promptResultsViewModel.shouldMarkPromptResultUnread = { [weak self] promptResultID in
            guard let self else { return true }
            if case .result(let id) = self.transcriptionViewModel.selectedTab,
               id == promptResultID {
                return false
            }
            return true
        }

        transcriptionViewModel.onTranscribingChanged = { _ in
            callbacks.onMenuBarIconUpdate()
        }

        let coordinatorRefs = CoordinatorRefs()
        let mediaPauseCoordinator = DictationMediaPauseCoordinator(
            settingsViewModel: settingsViewModel,
            mediaController: env.systemMediaController,
            isMeetingRecordingActive: {
                coordinatorRefs.meeting?.isMeetingRecordingActive == true
            }
        )

        let dictationCoordinator = DictationFlowCoordinator(
            dictationService: env.dictationService,
            clipboardService: env.clipboardService,
            entitlementsService: env.entitlementsService,
            dictationRepo: env.dictationRepo,
            settingsViewModel: settingsViewModel,
            sttRuntime: env.sttRuntime,
            runtimePreferences: env.runtimePreferences,
            permissionService: env.permissionService,
            mediaPauseCoordinator: mediaPauseCoordinator,
            shouldSuppressIdlePill: {
                coordinatorRefs.meeting?.isMeetingRecordingActive == true
                    || coordinatorRefs.voiceMemo?.isVoiceMemoActive == true
            },
            // Gate every dictation start (hotkey *and* idle-pill click) while
            // onboarding is up: the model isn't downloaded until a later step,
            // and the "Learn the Hotkey" step runs its own no-STT rehearsal.
            isStartSuppressed: { callbacks.isOnboardingVisible() },
            onMenuBarIconUpdate: { _ in callbacks.onMenuBarIconUpdate() },
            onHistoryReload: { [weak self] in self?.historyViewModel.loadDictations() },
            onPresentEntitlementsAlert: callbacks.onPresentEntitlementsAlert
        )
        coordinatorRefs.dictation = dictationCoordinator

        let meetingBackgroundProcessor = MeetingBackgroundProcessor(
            transcriptionService: env.transcriptionService,
            meetingRecordingService: env.meetingRecordingService,
            transcriptionRepo: env.transcriptionRepo,
            conversationRepo: env.chatConversationRepo,
            llmService: hasLLMConfig ? env.llmService : nil,
            onTranscriptionReady: { [weak self] transcription in
                guard let self else { return }
                self.transcriptionViewModel.presentCompletedTranscription(transcription, autoSave: true)
                self.libraryViewModel.loadTranscriptions()
                // Upstream's dedicated Meetings workspace (#378) keeps its own
                // recent-meetings list; refresh it so a backgrounded meeting
                // appears there too when its transcription completes.
                self.meetingsWorkspaceViewModel.refreshRecentMeetings()
                // A backgrounded meeting can finish while the user is recording
                // (or doing) something else. Don't yank focus to it — it just
                // appears in the Library. Only navigate when nothing is active.
                let recordingActive = coordinatorRefs.meeting?.isMeetingRecordingActive == true
                if !recordingActive {
                    self.mainWindowState.navigateToTranscription(from: .library)
                    callbacks.onOpenMainWindow()
                }
            },
            onProcessingCountChanged: { count in
                callbacks.onMeetingProcessingCountChanged(count)
            }
        )

        let meetingCoordinator = MeetingRecordingFlowCoordinator(
            meetingRecordingService: env.meetingRecordingService,
            transcriptionService: env.transcriptionService,
            permissionService: env.permissionService,
            transcriptionRepo: env.transcriptionRepo,
            conversationRepo: env.chatConversationRepo,
            quickPromptRepo: env.quickPromptRepo,
            configStore: env.llmConfigStore,
            sttManager: env.sttScheduler,
            meetingAudioSourceModeProvider: { env.runtimePreferences.meetingAudioSourceMode },
            llmService: hasLLMConfig ? env.llmService : nil,
            backgroundProcessor: meetingBackgroundProcessor,
            pillViewModel: meetingPillViewModel,
            onMenuBarIconUpdate: { _ in callbacks.onMenuBarIconUpdate() },
            onRecordingBegan: {
                coordinatorRefs.dictation?.hideIdlePill()
            },
            onFlowReturnedToIdle: {
                callbacks.onMenuBarIconUpdate()
                guard coordinatorRefs.dictation?.isDictationActive != true else { return }
                coordinatorRefs.dictation?.showIdlePill()
            }
        )
        coordinatorRefs.meeting = meetingCoordinator
        liveMeetingCoordinator = meetingCoordinator

        let voiceMemoCoordinator = VoiceMemoFlowCoordinator(
            meetingRecordingService: env.meetingRecordingService,
            transcriptionService: env.transcriptionService,
            permissionService: env.permissionService,
            libraryViewModel: libraryViewModel,
            quickPromptRepo: env.quickPromptRepo,
            configStore: env.llmConfigStore,
            llmService: env.llmService,
            isMeetingRecordingActive: { [weak meetingCoordinator] in
                meetingCoordinator?.isMeetingRecordingActive ?? false
            },
            onTranscriptionReady: { [weak self] transcription in
                guard let self else { return }
                self.transcriptionViewModel.presentCompletedTranscription(transcription, autoSave: true)
                self.libraryViewModel.loadTranscriptions()
                self.mainWindowState.navigateToTranscription(from: .library)
                callbacks.onOpenMainWindow()
            },
            onRecordingBegan: {
                coordinatorRefs.dictation?.hideIdlePill()
            },
            onFlowReturnedToIdle: {
                callbacks.onMenuBarIconUpdate()
                guard coordinatorRefs.dictation?.isDictationActive != true else { return }
                coordinatorRefs.dictation?.showIdlePill()
            }
        )
        coordinatorRefs.voiceMemo = voiceMemoCoordinator

        let hotkeyCoordinator = AppHotkeyCoordinator(
            settingsViewModel: settingsViewModel,
            onStartDictation: { mode in
                coordinatorRefs.dictation?.startDictation(mode: mode, trigger: .hotkey)
            },
            onStopDictation: {
                coordinatorRefs.dictation?.stopDictation()
            },
            onCancelDictation: {
                coordinatorRefs.dictation?.cancelDictation(reason: .escape)
            },
            onDiscardRecording: { showReadyPill in
                coordinatorRefs.dictation?.discardProvisionalRecording(showReadyPill: showReadyPill)
            },
            onReadyForSecondTap: {
                coordinatorRefs.dictation?.showReadyPill()
            },
            onEscapeWhileIdle: {
                coordinatorRefs.dictation?.dismissOverlayIfError()
            },
            onToggleMeetingRecording: callbacks.onToggleMeetingRecordingFromHotkey,
            onToggleVoiceMemo: { [weak voiceMemoCoordinator] in
                voiceMemoCoordinator?.toggleRecording()
            },
            onTriggerFileTranscription: callbacks.onTriggerFileTranscriptionFromHotkey,
            onTriggerYouTubeTranscription: callbacks.onTriggerYouTubeTranscriptionFromHotkey,
            onDictationHotkeyManagersChanged: { managers in
                coordinatorRefs.dictation?.hotkeyManagers = managers
            },
            onAnyHotkeyEnabled: callbacks.onHotkeyBecameAvailable,
            onHotkeyUnavailable: callbacks.onHotkeyUnavailable,
            onHotkeyConflict: callbacks.onHotkeyConflict,
            dictationRecordingModeProvider: {
                coordinatorRefs.dictation?.hotkeyRecordingMode
            }
        )

        if callbacks.isHotkeyRecordingActive() {
            hotkeyCoordinator.suspend()
        }
        hotkeyCoordinator.setupAllHotkeys()
        dictationCoordinator.showIdlePill()

        // Calendar auto-start (ADR-017 Phases 1 + 2 — reminders +
        // pre-meeting countdown toast). The coordinator is a no-op when
        // `calendarAutoStartMode == .off` so it's safe to start
        // unconditionally; we still gate creation on the meeting-recording
        // feature flag because calendar integration only makes sense when
        // the user can actually record meetings.
        let calendarCoordinator: MeetingAutoStartCoordinator?
        if AppFeatures.meetingRecordingEnabled {
            let coordinator = MeetingAutoStartCoordinator(
                calendarService: CalendarService.shared,
                settingsViewModel: settingsViewModel,
                isRecordingActive: { [weak meetingCoordinator] in
                    meetingCoordinator?.isMeetingRecordingActive ?? false
                },
                onAutoStartConfirmed: { [weak meetingCoordinator] title in
                    meetingCoordinator?.startFromCalendar(title: title)
                }
            )
            coordinator.start()
            calendarCoordinator = coordinator
        } else {
            calendarCoordinator = nil
        }

        // AI Assistant flow coordinator (PDX feature). Constructed after the
        // hotkey coordinator so it can share the dictation service; wired via
        // a dedicated GlobalShortcutManager that uses the config's hotkey
        // trigger (default Option+A). The coordinator is retained in Runtime
        // so AppDelegate can call dismissAny() on app termination.
        let aiAssistantCoordinator = AIAssistantFlowCoordinator(
            service: env.aiAssistantService,
            accessibilityService: env.accessibilityService,
            clipboardService: env.clipboardService,
            configStore: env.aiAssistantConfigStore,
            dictationService: env.dictationService
        )
        let aiConfig = env.aiAssistantConfigStore.load()
        let aiTrigger = aiConfig?.effectiveHotkeyTrigger
            ?? AIAssistantConfig.defaultHotkeyTrigger
        if !aiTrigger.isDisabled {
            let aiManager = GlobalShortcutManager(trigger: aiTrigger)
            // Tap-to-toggle: every press fires onTrigger → handleHotkeyPress,
            // which starts listening when idle and stops+submits when already
            // listening. onDoubleTap is intentionally NOT wired — setting it
            // would make GlobalShortcutManager suppress onTrigger for a fast
            // second press (treating it as a double-tap), which would swallow
            // the "tap again to stop" gesture.
            aiManager.onTrigger = {
                Task { @MainActor in aiAssistantCoordinator.handleHotkeyPress() }
            }
            _ = aiManager.start()
        }

        return Runtime(
            dictationFlowCoordinator: dictationCoordinator,
            meetingRecordingFlowCoordinator: meetingCoordinator,
            voiceMemoFlowCoordinator: voiceMemoCoordinator,
            hotkeyCoordinator: hotkeyCoordinator,
            meetingAutoStartCoordinator: calendarCoordinator,
            aiAssistantFlowCoordinator: aiAssistantCoordinator
        )
    }

    func refreshLLMAvailability(in env: AppEnvironment) {
        let hasConfig = (try? env.llmConfigStore.loadConfig()) != nil
        let service: LLMService? = hasConfig ? env.llmService : nil
        transcriptionViewModel.updateLLMAvailability(hasConfig, llmService: service)
        libraryViewModel.updateLLMAvailability(hasConfig, llmService: service)
        chatViewModel.updateLLMService(service)
        promptResultsViewModel.updateLLMService(service)
        transformsViewModel.setHasLLMProvider(hasConfig)
        liveMeetingCoordinator?.updateLLMService(service)
    }
}
