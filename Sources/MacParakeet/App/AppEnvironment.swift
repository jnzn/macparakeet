import Foundation
import MacParakeetCore

/// Service container: creates and wires up all dependencies.
@MainActor
final class AppEnvironment {
    let databaseManager: DatabaseManager
    let dictationRepo: DictationRepository
    let transcriptionRepo: TranscriptionRepository
    let customWordRepo: CustomWordRepository
    let snippetRepo: TextSnippetRepository
    let chatConversationRepo: ChatConversationRepository
    let promptRepo: PromptRepository
    let promptResultRepo: PromptResultRepository
    let sttRuntime: STTRuntime
    let sttScheduler: STTScheduler
    let streamingDictationTranscriber: StreamingEouDictationTranscriber
    private var modelKeepAliveTask: Task<Void, Never>?
    let audioProcessor: AudioProcessor
    let meetingRecordingService: MeetingRecordingService
    let meetingRecordingRecoveryService: MeetingRecordingRecoveryService
    let dictationService: DictationService
    let transcriptionService: TranscriptionService
    let youtubeDownloader: YouTubeDownloader
    let diarizationService: DiarizationService
    let clipboardService: ClipboardService
    let exportService: ExportService
    let permissionService: PermissionService
    let accessibilityService: AccessibilityService
    let entitlementsService: EntitlementsService
    let launchAtLoginService: LaunchAtLoginService
    let checkoutURL: URL?
    let telemetryService: TelemetryService
    let llmClient: RoutingLLMClient
    let llmConfigStore: LLMConfigStore
    let llmService: LLMService
    let runtimePreferences: AppRuntimePreferencesProtocol
    let aiAssistantConfigStore: AIAssistantConfigStore
    let aiAssistantService: AIAssistantService
    let derivedFieldsBackfill: DerivedFieldsBackfillService

    init(databaseManager: DatabaseManager) throws {
        self.databaseManager = databaseManager

        // Repositories
        dictationRepo = DictationRepository(dbQueue: databaseManager.dbQueue)
        transcriptionRepo = TranscriptionRepository(dbQueue: databaseManager.dbQueue)
        customWordRepo = CustomWordRepository(dbQueue: databaseManager.dbQueue)
        snippetRepo = TextSnippetRepository(dbQueue: databaseManager.dbQueue)
        chatConversationRepo = ChatConversationRepository(dbQueue: databaseManager.dbQueue)
        promptRepo = PromptRepository(dbQueue: databaseManager.dbQueue)
        promptResultRepo = PromptResultRepository(dbQueue: databaseManager.dbQueue)

        // Services
        let runtimePreferences = UserDefaultsAppRuntimePreferences()
        self.runtimePreferences = runtimePreferences
        let selectedInputDeviceUIDProvider: @Sendable () -> String? = { [runtimePreferences] in
            runtimePreferences.selectedMicrophoneDeviceUID
        }
        let meetingAudioSourceModeProvider: @Sendable () -> MeetingAudioSourceMode = { [runtimePreferences] in
            runtimePreferences.meetingAudioSourceMode
        }

        sttRuntime = STTRuntime(
            speechEngine: SpeechEnginePreference.current(),
            whisperModelVariant: SpeechEnginePreference.whisperModelVariant()
        )
        sttScheduler = STTScheduler(runtime: sttRuntime)
        audioProcessor = AudioProcessor(
            selectedInputDeviceUIDProvider: selectedInputDeviceUIDProvider
        )
        meetingRecordingService = MeetingRecordingService(
            audioCaptureService: MeetingAudioCaptureService(
                selectedInputDeviceUIDProvider: selectedInputDeviceUIDProvider,
                sourceModeProvider: meetingAudioSourceModeProvider
            ),
            sttTranscriber: sttScheduler
        )
        clipboardService = ClipboardService()
        exportService = ExportService()
        permissionService = PermissionService()
        accessibilityService = AccessibilityService()
        launchAtLoginService = LaunchAtLoginService()

        // Retained purchase activation / entitlements. Current free/GPL builds
        // always report unlocked, but the old activation plumbing is preserved
        // as future-option support for official paid distribution/support.
        //
        // Production builds should embed these values in Info.plist via the dist script.
        // We still support env vars for local development.
        let checkoutURLString =
            (Bundle.main.object(forInfoDictionaryKey: "MacParakeetCheckoutURL") as? String)
            ?? ProcessInfo.processInfo.environment["MACPARAKEET_CHECKOUT_URL"]
        checkoutURL = checkoutURLString
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
            .flatMap(URL.init(string:))

        let expectedVariantID: Int? = {
            if let n = Bundle.main.object(forInfoDictionaryKey: "MacParakeetLemonSqueezyVariantID") as? NSNumber {
                return n.intValue
            }
            let s =
                (Bundle.main.object(forInfoDictionaryKey: "MacParakeetLemonSqueezyVariantID") as? String)
                ?? ProcessInfo.processInfo.environment["MACPARAKEET_LS_VARIANT_ID"]
            guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
        }()

        let licensingConfig = LicensingConfig(checkoutURL: checkoutURL, expectedVariantID: expectedVariantID)
        let serviceName = Bundle.main.bundleIdentifier ?? "com.macparakeet"
        let keychain = KeychainKeyValueStore(service: serviceName)
        entitlementsService = EntitlementsService(
            config: licensingConfig,
            store: keychain,
            api: LemonSqueezyLicenseAPI()
        )

        let processingModeClosure: @Sendable () -> Dictation.ProcessingMode = { [runtimePreferences] in
            runtimePreferences.processingMode
        }

        youtubeDownloader = YouTubeDownloader()
        diarizationService = DiarizationService()

        let voiceReturnTriggerClosure: @Sendable () -> String? = { [runtimePreferences] in
            runtimePreferences.voiceReturnTrigger
        }

        let aiFormatterEnabledClosure: @Sendable () -> Bool = { [runtimePreferences] in
            runtimePreferences.aiFormatterEnabled
        }

        let aiFormatterPromptClosure: @Sendable () -> String = { [runtimePreferences] in
            runtimePreferences.aiFormatterPrompt
        }

        llmClient = RoutingLLMClient()
        llmConfigStore = LLMConfigStore()
        llmService = LLMService(
            client: llmClient,
            contextResolver: StoredLLMExecutionContextResolver(
                configStore: llmConfigStore,
                cliConfigStore: LocalCLIConfigStore()
            )
        )

        // AI Assistant (Item 6) — separate agentic-CLI service driven by the
        // assistant hotkey. Config lives in its own UserDefaults blob so it's
        // orthogonal to the LLM formatter config. Until a Settings UI exists
        // (chunk C), fall back to the default Claude config when nothing is
        // stored so the hotkey works out of the box as long as the `claude`
        // CLI is on the user's PATH.
        let aiAssistantConfigStore = AIAssistantConfigStore()
        self.aiAssistantConfigStore = aiAssistantConfigStore
        self.aiAssistantService = AIAssistantService(
            configProvider: { [aiAssistantConfigStore] in
                aiAssistantConfigStore.load() ?? AIAssistantConfig.defaultClaude
            }
        )

        let streamingDictationTranscriber = StreamingEouDictationTranscriber()

        dictationService = DictationService(
            audioProcessor: audioProcessor,
            sttTranscriber: sttScheduler,
            dictationRepo: dictationRepo,
            shouldSaveAudio: { [runtimePreferences] in runtimePreferences.shouldSaveAudioRecordings },
            shouldSaveDictationHistory: { [runtimePreferences] in runtimePreferences.shouldSaveDictationHistory },
            entitlements: entitlementsService,
            customWordRepo: customWordRepo,
            snippetRepo: snippetRepo,
            voiceReturnTrigger: voiceReturnTriggerClosure,
            processingMode: processingModeClosure,
            llmService: llmService,
            shouldUseAIFormatter: aiFormatterEnabledClosure,
            shouldFormatPasteWithAI: { [runtimePreferences] in runtimePreferences.formatPasteWithAI },
            aiFormatterPromptTemplate: aiFormatterPromptClosure,
            resolveActiveProfile: {
                AppProfile.resolve(bundleID: AppContextService.frontmostBundleID())
            },
            resolveAppContext: { [accessibilityService] in
                let ctx = await AppContextService.captureContext(accessibility: accessibilityService)
                return ctx.isEmpty ? nil : ctx
            },
            streamingBroadcaster: audioProcessor,
            streamingTranscriber: streamingDictationTranscriber,
            streamingOverlayEnabled: { [runtimePreferences] in runtimePreferences.streamingOverlayEnabled },
            streamingPartialHandler: { partial in
                NotificationCenter.default.post(
                    name: .macParakeetStreamingPartial,
                    object: nil,
                    userInfo: ["text": partial]
                )
            }
        )
        self.streamingDictationTranscriber = streamingDictationTranscriber

        // Periodic keep-alive pings so CoreML doesn't page out the ANE context
        // after idle periods. Fires every 2 min, skipping while dictation is
        // actively in progress. Pings both the batch TDT model (via scheduler)
        // and the streaming EOU model (if enabled).
        modelKeepAliveTask = Task { [sttScheduler, streamingDictationTranscriber, dictationService, runtimePreferences, llmConfigStore] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(120))
                if Task.isCancelled { break }
                let state = await dictationService.state
                switch state {
                case .recording, .processing:
                    continue
                default:
                    break
                }
                await sttScheduler.keepAlive()
                if runtimePreferences.streamingOverlayEnabled {
                    await streamingDictationTranscriber.keepAlive()
                }
                // Ollama defaults to unloading idle models after 5 min. If the
                // user has configured an Ollama provider for AI Formatter
                // cleanup, send a trivial request with keep_alive=5m to keep
                // the model resident. Best-effort; errors are silently dropped.
                if runtimePreferences.aiFormatterEnabled,
                   let config = (try? llmConfigStore.loadConfig()) ?? nil,
                   config.id == .ollama {
                    await Self.pingOllamaKeepAlive(config: config)
                }
            }
        }

        let telemetry = TelemetryService()
        telemetryService = telemetry
        Telemetry.configure(telemetry)
        Telemetry.send(.appLaunched)
        Task {
            await CrashReporter.sendPendingReport(via: telemetry)
        }

        transcriptionService = TranscriptionService(
            audioProcessor: audioProcessor,
            sttTranscriber: sttScheduler,
            transcriptionRepo: transcriptionRepo,
            entitlements: entitlementsService,
            customWordRepo: customWordRepo,
            snippetRepo: snippetRepo,
            processingMode: processingModeClosure,
            llmService: llmService,
            shouldUseAIFormatter: aiFormatterEnabledClosure,
            aiFormatterPromptTemplate: aiFormatterPromptClosure,
            shouldKeepDownloadedAudio: { [runtimePreferences] in runtimePreferences.shouldSaveTranscriptionAudio },
            shouldDiarize: { [runtimePreferences] in runtimePreferences.shouldDiarize },
            youtubeDownloader: youtubeDownloader,
            diarizationService: diarizationService
        )

        meetingRecordingRecoveryService = MeetingRecordingRecoveryService(
            transcriptionService: transcriptionService,
            transcriptionRepo: transcriptionRepo
        )

        derivedFieldsBackfill = DerivedFieldsBackfillService(dbQueue: databaseManager.dbQueue)
        derivedFieldsBackfill.runInBackground()
    }

    /// Send a trivial 1-token request to the configured Ollama endpoint with
    /// `keep_alive=5m` so the active model stays resident in memory. Ollama
    /// resets the idle unload timer on every request. Silently swallows
    /// errors — this is best-effort warming.
    private static func pingOllamaKeepAlive(config: LLMProviderConfig) async {
        var baseStr = config.baseURL.absoluteString
        if baseStr.hasSuffix("/v1") { baseStr = String(baseStr.dropLast(3)) }
        else if baseStr.hasSuffix("/v1/") { baseStr = String(baseStr.dropLast(4)) }
        guard let base = URL(string: baseStr) else { return }
        let url = base.appendingPathComponent("api/chat")
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": config.modelName,
            "messages": [["role": "user", "content": "hi"]],
            "think": false,
            "stream": false,
            "keep_alive": "5m",
            "options": ["num_predict": 1]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: request)
    }
}
