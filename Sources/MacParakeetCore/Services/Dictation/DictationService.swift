@preconcurrency import AVFoundation
import Foundation
import OSLog

public enum DictationState: Sendable {
    case idle
    case recording
    case processing
    case success(Dictation)
    case cancelled
    case error(String)
}

public struct DictationTelemetryContext: Sendable, Equatable {
    public var trigger: TelemetryDictationTrigger?
    public var mode: TelemetryDictationMode?
    /// Coarse category of the app expected to receive the dictation paste.
    /// The app layer refreshes this near stop/undo time so the value follows
    /// the finish-target paste model instead of locking to the app active at
    /// recording start. See `TelemetryAppCategory` for the privacy contract.
    public var appCategory: TelemetryAppCategory?

    public init(
        trigger: TelemetryDictationTrigger? = nil,
        mode: TelemetryDictationMode? = nil,
        appCategory: TelemetryAppCategory? = nil
    ) {
        self.trigger = trigger
        self.mode = mode
        self.appCategory = appCategory
    }
}

public protocol DictationServiceProtocol: Sendable {
    func startRecording(context: DictationTelemetryContext) async throws
    func stopRecording() async throws -> DictationResult
    func cancelRecording(reason: TelemetryDictationCancelReason?) async
    /// Confirm cancel immediately (discard any pending audio and reset to idle).
    func confirmCancel() async
    /// Undo a soft-cancel: transcribe the cancelled recording and return a DictationResult.
    func undoCancel() async throws -> DictationResult
    var state: DictationState { get async }
    var audioLevel: Float { get async }
}

private struct FormatterOutcome: Sendable {
    let text: String?
    let run: LLMRun?

    static let skipped = FormatterOutcome(text: nil, run: nil)
}

extension DictationServiceProtocol {
    public func startRecording() async throws {
        try await startRecording(context: DictationTelemetryContext())
    }

    public func cancelRecording() async {
        await cancelRecording(reason: nil)
    }
}

public actor DictationService: DictationServiceProtocol {
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "DictationService")
    private let audioProcessor: AudioProcessorProtocol
    private let sttTranscriber: STTTranscribing
    private let dictationRepo: DictationRepositoryProtocol
    private let shouldSaveAudio: (@Sendable () -> Bool)?
    private let shouldSaveDictationHistory: (@Sendable () -> Bool)?
    private let smartFormatting: (@Sendable () -> Bool)?
    private let entitlements: EntitlementsChecking?
    private let customWordRepo: CustomWordRepositoryProtocol?
    private let snippetRepo: TextSnippetRepositoryProtocol?
    private let voiceReturnTrigger: @Sendable () -> String?
    private let voiceReturnMode: @Sendable () -> VoiceReturnMode
    private let processingMode: @Sendable () -> Dictation.ProcessingMode
    private let textRefinementService: TextRefinementService
    private let llmService: LLMServiceProtocol?
    private let llmRunRecorder: LLMRunRecorder
    private let shouldUseAIFormatter: @Sendable () -> Bool
    private let aiFormatterPromptTemplate: @Sendable () -> String
    private let markFirstDictationCompleted: (@Sendable () -> Void)?
    private let cancelWindow: Duration
    /// Resolves the active `AppProfile` based on the frontmost app at the time
    /// of dictation start. Called once per `startRecording`; the result is
    /// captured in `activeProfile` and reused throughout the dictation.
    private let resolveActiveProfile: @Sendable () -> AppProfile?
    /// Captures an AX snapshot of the frontmost app (window title, focused
    /// field value, selected text) at dictation start. Best-effort: returns
    /// nil when AX is unavailable, the app is blocklisted, or nothing useful
    /// came back. Injected into the cleanup LLM prompt so the model can
    /// disambiguate ambiguous transcriptions using real context.
    private let resolveAppContext: @Sendable () async -> AppContext?

    // MARK: - Streaming overlay (fork-only)
    private let streamingBroadcaster: StreamingAudioBroadcaster?
    private let streamingTranscriber: StreamingDictationTranscriber?
    private let streamingOverlayEnabled: @Sendable () -> Bool
    private let streamingPartialHandler: (@Sendable (String) -> Void)?
    /// Active background task feeding audio into the streaming transcriber.
    private var activeStreamingTask: Task<Void, Never>?
    /// Most recent streaming partial keyed by session ID. Guards against stale
    /// callback delivery from a replaced session overwriting fresh text.
    private var lastStreamingPartialBySession: [Int: String] = [:]

    private var _state: DictationState = .idle
    private var cancelResetTask: Task<Void, Never>?
    private var cancelGeneration: Int = 0
    private var pendingCancelledAudioURL: URL?
    private var currentTelemetryContext = DictationTelemetryContext()
    private var recordingStartedAt: Date?
    private var currentOperationID: String?
    private var currentOperationTelemetryContext = DictationTelemetryContext()
    private var currentObservabilityOperationContext: ObservabilityOperationContext?
    private var activeSessionID: Int = 0
    private var cancellationRequestedDuringStartSessionID: Int?
    private var pendingCancelReason: TelemetryDictationCancelReason?
    /// Profile resolved at the start of the current dictation, or nil if no
    /// profile matched the frontmost app. Overrides the formatter prompt for
    /// the paste-path polish. Cleared by the next `startRecording` (overwritten).
    private var activeProfile: AppProfile?
    /// AX snapshot captured at dictation start. Nil when context capture is
    /// disabled, the app is blocklisted, or no useful signals came back. Used
    /// to prepend a context block to the paste-polish LLM prompt.
    private var activeAppContext: AppContext?

    /// When true, skip all LLM polish paths for the current recording. Set via
    /// `setSuppressLLMPolish(true)` before `startRecording` by the AI Assistant
    /// flow coordinator, which consumes the raw Parakeet transcript directly —
    /// the spoken input is an instruction TO Claude/Codex, not text that should
    /// be rewritten by a per-app formatter prompt. Auto-reset in `confirmCancel`.
    private var suppressLLMPolish: Bool = false

    public var state: DictationState {
        _state
    }

    public var audioLevel: Float {
        get async { await audioProcessor.audioLevel }
    }

    /// Called before `startRecording` by consumers (AI Assistant hotkey) that
    /// want raw Parakeet output without profile-aware LLM polish. The flag
    /// auto-clears in `confirmCancel`.
    public func setSuppressLLMPolish(_ suppressed: Bool) {
        self.suppressLLMPolish = suppressed
    }

    public init(
        audioProcessor: AudioProcessorProtocol,
        sttTranscriber: STTTranscribing,
        dictationRepo: DictationRepositoryProtocol,
        shouldSaveAudio: (@Sendable () -> Bool)? = nil,
        shouldSaveDictationHistory: (@Sendable () -> Bool)? = nil,
        smartFormatting: (@Sendable () -> Bool)? = nil,
        entitlements: EntitlementsChecking? = nil,
        customWordRepo: CustomWordRepositoryProtocol? = nil,
        snippetRepo: TextSnippetRepositoryProtocol? = nil,
        voiceReturnTrigger: (@Sendable () -> String?)? = nil,
        voiceReturnMode: (@Sendable () -> VoiceReturnMode)? = nil,
        processingMode: (@Sendable () -> Dictation.ProcessingMode)? = nil,
        llmService: LLMServiceProtocol? = nil,
        llmRunRepo: LLMRunRepositoryProtocol? = nil,
        shouldUseAIFormatter: (@Sendable () -> Bool)? = nil,
        aiFormatterPromptTemplate: (@Sendable () -> String)? = nil,
        markFirstDictationCompleted: (@Sendable () -> Void)? = nil,
        cancelWindow: Duration = .seconds(5),
        resolveActiveProfile: (@Sendable () -> AppProfile?)? = nil,
        resolveAppContext: (@Sendable () async -> AppContext?)? = nil,
        streamingBroadcaster: StreamingAudioBroadcaster? = nil,
        streamingTranscriber: StreamingDictationTranscriber? = nil,
        streamingOverlayEnabled: (@Sendable () -> Bool)? = nil,
        streamingPartialHandler: (@Sendable (String) -> Void)? = nil
    ) {
        self.audioProcessor = audioProcessor
        self.sttTranscriber = sttTranscriber
        self.dictationRepo = dictationRepo
        self.shouldSaveAudio = shouldSaveAudio
        self.shouldSaveDictationHistory = shouldSaveDictationHistory
        self.smartFormatting = smartFormatting
        self.entitlements = entitlements
        self.customWordRepo = customWordRepo
        self.snippetRepo = snippetRepo
        self.voiceReturnTrigger = voiceReturnTrigger ?? { nil }
        self.voiceReturnMode = voiceReturnMode ?? { .send }
        self.processingMode = processingMode ?? { .raw }
        self.textRefinementService = TextRefinementService()
        self.llmService = llmService
        self.llmRunRecorder = LLMRunRecorder(repository: llmRunRepo)
        self.shouldUseAIFormatter = shouldUseAIFormatter ?? { false }
        self.aiFormatterPromptTemplate = aiFormatterPromptTemplate ?? { AIFormatter.defaultPromptTemplate }
        self.markFirstDictationCompleted = markFirstDictationCompleted
        self.cancelWindow = cancelWindow
        self.resolveActiveProfile = resolveActiveProfile ?? { nil }
        self.resolveAppContext = resolveAppContext ?? { nil }
        self.streamingBroadcaster = streamingBroadcaster
        self.streamingTranscriber = streamingTranscriber
        self.streamingOverlayEnabled = streamingOverlayEnabled ?? { false }
        self.streamingPartialHandler = streamingPartialHandler
    }

    public func startRecording(context: DictationTelemetryContext = DictationTelemetryContext()) async throws {
        try await startRecording(context: context, sessionID: nil)
    }

    public func updateTelemetryAppCategory(
        _ appCategory: TelemetryAppCategory?,
        sessionID: Int? = nil
    ) {
        if let sessionID, sessionID != activeSessionID { return }
        switch _state {
        case .recording, .cancelled, .processing:
            currentTelemetryContext.appCategory = appCategory
            currentOperationTelemetryContext.appCategory = appCategory
        case .idle, .success, .error:
            return
        }
    }

    public func startRecording(
        context: DictationTelemetryContext = DictationTelemetryContext(),
        sessionID: Int?
    ) async throws {
        logger.debug("dictation_start_requested state=\(self.debugStateLabel(self._state), privacy: .public)")
        let operationContext = ObservabilityOperationContext()
        if let entitlements {
            do {
                try await entitlements.assertCanTranscribe(now: Date())
            } catch {
                let device = await audioProcessor.recordingDeviceInfo
                sendDictationOperation(
                    operationID: operationContext.operationID,
                    operationContext: operationContext,
                    telemetryContext: context,
                    outcome: .unavailable,
                    errorType: Self.errorType(for: error),
                    device: device
                )
                throw error
            }
        }

        switch _state {
        case .idle, .cancelled:
            break
        case .recording where sessionID != nil && sessionID != activeSessionID:
            // New session replacing a stale provisional recording whose
            // confirmCancel hasn't arrived yet. Clean up the old capture.
            logger.notice(
                "startRecording replacing stale recording old=\(self.activeSessionID) new=\(sessionID!, privacy: .public)"
            )
            if await audioProcessor.isRecording,
               let url = try? await audioProcessor.stopCapture() {
                try? FileManager.default.removeItem(at: url)
            }
        case .processing where sessionID != nil && sessionID != activeSessionID,
             .success where sessionID != nil && sessionID != activeSessionID:
            // Previous transcription still in flight. The reentrancy guards in
            // stopRecording prevent the old call from overwriting this session's state.
            logger.notice(
                "startRecording overriding busy service old=\(self.activeSessionID) new=\(sessionID!, privacy: .public) state=\(self.debugStateLabel(self._state), privacy: .public)"
            )
        default:
            return
        }

        discardPendingCancelledAudio()

        cancelResetTask?.cancel()
        cancelResetTask = nil

        let requestedSessionID = sessionID ?? activeSessionID + 1
        activeSessionID = requestedSessionID
        cancellationRequestedDuringStartSessionID = nil
        pendingCancelReason = nil
        currentOperationID = operationContext.operationID
        currentOperationTelemetryContext = context
        currentObservabilityOperationContext = operationContext
        _state = .recording
        do {
            try await audioProcessor.startCapture()
            // Guard against reentrancy: cancel or replacement may have run during the await above.
            if cancellationRequestedDuringStartSessionID == requestedSessionID {
                cancellationRequestedDuringStartSessionID = nil
            }
            let activeAtStartCompletion = activeSessionID
            guard activeAtStartCompletion == requestedSessionID, case .recording = _state else {
                let processorIsRecording: Bool
                if activeAtStartCompletion == requestedSessionID {
                    processorIsRecording = await audioProcessor.isRecording
                } else {
                    processorIsRecording = false
                }
                if activeSessionID == requestedSessionID,
                   processorIsRecording,
                   let audioURL = try? await audioProcessor.stopCapture() {
                    try? FileManager.default.removeItem(at: audioURL)
                }
                if activeSessionID == requestedSessionID {
                    recordingStartedAt = nil
                }
                logger.notice(
                    "dictation_start_aborted session=\(requestedSessionID, privacy: .public) active_session=\(activeAtStartCompletion, privacy: .public) state=\(self.debugStateLabel(self._state), privacy: .public)"
                )
                return
            }
            currentTelemetryContext = context
            recordingStartedAt = Date()
            activeProfile = resolveActiveProfile()
            if let profile = activeProfile {
                logger.info(
                    "active_profile session=\(requestedSessionID) id=\(profile.id, privacy: .public) name=\(profile.displayName, privacy: .public)"
                )
            }
            // Capture app context asynchronously — AX calls can block briefly
            // on a busy target app. The resolver wraps them in Task.detached
            // with a per-call AX timeout, so this await returns quickly and
            // never blocks the actor beyond the timeout budget.
            activeAppContext = await resolveAppContext()
            if let ctx = activeAppContext {
                logger.info(
                    "app_context_captured session=\(requestedSessionID) hasTitle=\(ctx.windowTitle != nil) hasField=\(ctx.focusedFieldValue != nil) hasSelection=\(ctx.selectedText != nil)"
                )
            }
            Telemetry.send(.dictationStarted(trigger: context.trigger, mode: context.mode))
            logger.debug("dictation_capture_started session=\(requestedSessionID, privacy: .public)")
            startStreamingSessionIfEnabled(sessionID: requestedSessionID)
        } catch {
            let activeAtFailure = activeSessionID
            guard activeAtFailure == requestedSessionID else {
                logger.notice(
                    "startRecording stale failure ignored session=\(requestedSessionID) active=\(activeAtFailure) error=\(error.localizedDescription, privacy: .public)"
                )
                throw error
            }
            let cancellationRequestedDuringStart = cancellationRequestedDuringStartSessionID == requestedSessionID
            if cancellationRequestedDuringStart {
                cancellationRequestedDuringStartSessionID = nil
            }
            if Self.isInterruptedDuringSubscribe(error), cancellationRequestedDuringStart {
                if cancellationRequestedDuringStart, case .recording = _state {
                    _state = .cancelled
                }
                recordingStartedAt = nil
                logger.notice(
                    "startRecording interrupted after cancellation session=\(requestedSessionID) state=\(self.debugStateLabel(self._state), privacy: .public)"
                )
                return
            }
            let device = await audioProcessor.recordingDeviceInfo
            guard activeSessionID == requestedSessionID else {
                logger.notice(
                    "startRecording stale failure ignored session=\(requestedSessionID) active=\(self.activeSessionID) error=\(error.localizedDescription, privacy: .public)"
                )
                throw error
            }
            let operationID = currentOperationID
            let telemetryContext = currentOperationTelemetryContext
            let observabilityOperationContext = currentObservabilityOperationContext
            _state = .idle
            recordingStartedAt = nil
            sendDictationOperation(
                operationID: operationID,
                operationContext: observabilityOperationContext,
                telemetryContext: telemetryContext,
                outcome: .failure,
                errorType: Self.errorType(for: error),
                device: device
            )
            clearCurrentOperation()
            Telemetry.send(.dictationFailed(errorType: Self.errorType(for: error), errorDetail: TelemetryErrorClassifier.errorDetail(error), device: device))
            logger.error(
                "startRecording failed session=\(requestedSessionID) error=\(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }

    public func stopRecording() async throws -> DictationResult {
        try await stopRecording(sessionID: nil)
    }

    public func stopRecording(sessionID: Int?) async throws -> DictationResult {
        if let sessionID, sessionID != activeSessionID {
            logger.notice(
                "stopRecording ignored stale session requested=\(sessionID) active=\(self.activeSessionID)"
            )
            throw DictationServiceError.notRecording
        }
        guard case .recording = _state else {
            logger.warning(
                "stopRecording rejected session=\(sessionID ?? self.activeSessionID) state=\(self.debugStateLabel(self._state), privacy: .public)"
            )
            throw DictationServiceError.notRecording
        }

        let currentSession = activeSessionID
        _state = .processing
        logger.debug("dictation_stop_processing_started session=\(currentSession, privacy: .public)")

        do {
            let audioURL = try await audioProcessor.stopCapture()
            let device = await audioProcessor.recordingDeviceInfo
            logger.debug(
                "dictation_capture_stopped session=\(currentSession, privacy: .public) path=\(audioURL.path, privacy: .private)"
            )
            let result = try await withCurrentObservabilityContextIfAny {
                try await processCapturedAudio(audioURL: audioURL)
            }
            // Guard against reentrancy: a new session may have started during
            // transcription, replacing this session. Don't overwrite its state.
            guard activeSessionID == currentSession else {
                logger.notice(
                    "stopRecording result discarded session=\(currentSession) replaced by=\(self.activeSessionID)"
                )
                return result
            }
            _state = .success(result.dictation)
            sendDictationOperation(
                outcome: .success,
                durationSeconds: Double(result.dictation.durationMs) / 1000.0,
                wordCount: result.dictation.wordCount,
                speechEngine: result.dictation.engine,
                engineVariant: result.dictation.engineVariant,
                language: result.dictation.language,
                device: device
            )
            Telemetry.send(.dictationCompleted(
                durationSeconds: Double(result.dictation.durationMs) / 1000.0,
                wordCount: result.dictation.wordCount,
                mode: currentTelemetryContext.mode,
                speechEngine: result.dictation.engine,
                engineVariant: result.dictation.engineVariant,
                language: result.dictation.language,
                appCategory: currentTelemetryContext.appCategory,
                device: device
            ))
            logger.debug(
                "stopRecording success session=\(currentSession) rawChars=\(result.dictation.rawTranscript.count) cleanChars=\(result.dictation.cleanTranscript?.count ?? 0)"
            )
            try? await Task.sleep(for: .milliseconds(500))
            guard activeSessionID == currentSession else { return result }
            _state = .idle
            recordingStartedAt = nil
            clearCurrentOperation()
            return result
        } catch {
            // Snapshot device before setting state to .idle — prevents reentrancy
            // window where a new startRecording() could overwrite the device info.
            let device = await audioProcessor.recordingDeviceInfo
            guard activeSessionID == currentSession else {
                logger.notice(
                    "stopRecording error discarded session=\(currentSession) replaced by=\(self.activeSessionID)"
                )
                throw error
            }
            _state = .idle
            if Self.isNoSpeechError(error) {
                sendDictationOperation(
                    outcome: .empty,
                    durationSeconds: currentRecordingDurationSeconds(),
                    errorType: Self.errorType(for: error),
                    device: device
                )
                Telemetry.send(.dictationEmpty(durationSeconds: currentRecordingDurationSeconds(), device: device))
            } else {
                sendDictationOperation(
                    outcome: .failure,
                    durationSeconds: currentRecordingDurationSeconds(),
                    errorType: Self.errorType(for: error),
                    device: device
                )
                Telemetry.send(.dictationFailed(errorType: Self.errorType(for: error), errorDetail: TelemetryErrorClassifier.errorDetail(error), device: device))
            }
            recordingStartedAt = nil
            clearCurrentOperation()
            logger.error(
                "stopRecording failed session=\(currentSession) error=\(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }

    public func cancelRecording(reason: TelemetryDictationCancelReason? = nil) async {
        await cancelRecording(reason: reason, sessionID: nil)
    }

    public func cancelRecording(
        reason: TelemetryDictationCancelReason? = nil,
        sessionID: Int?
    ) async {
        if let sessionID, sessionID != activeSessionID {
            logger.notice(
                "cancelRecording ignored stale session requested=\(sessionID) active=\(self.activeSessionID)"
            )
            return
        }
        guard case .recording = _state else { return }

        cancelGeneration += 1
        let generation = cancelGeneration

        pendingCancelReason = reason
        cancellationRequestedDuringStartSessionID = activeSessionID
        let audioURL = try? await audioProcessor.stopCapture()
        let device = await audioProcessor.recordingDeviceInfo
        pendingCancelledAudioURL = audioURL
        _state = .cancelled
        Telemetry.send(.dictationCancelled(
            durationSeconds: currentRecordingDurationSeconds(),
            reason: reason,
            device: device
        ))

        cancelResetTask?.cancel()
        cancelResetTask = Task { [generation] in
            try? await Task.sleep(for: cancelWindow)
            resetAfterCancelIfStillCurrent(generation: generation)
        }
    }

    public func confirmCancel() async {
        await confirmCancel(sessionID: nil)
    }

    public func confirmCancel(sessionID: Int?) async {
        if let sessionID, sessionID != activeSessionID {
            logger.notice(
                "confirmCancel ignored stale session requested=\(sessionID) active=\(self.activeSessionID)"
            )
            return
        }
        cancelGeneration += 1
        cancelResetTask?.cancel()
        cancelResetTask = nil
        discardPendingCancelledAudio()

        if case .recording = _state {
            cancellationRequestedDuringStartSessionID = activeSessionID
            if let url = try? await audioProcessor.stopCapture() {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let device = await audioProcessor.recordingDeviceInfo
        sendDictationOperation(
            outcome: .cancelled,
            durationSeconds: currentRecordingDurationSeconds(),
            cancelReason: pendingCancelReason,
            device: device
        )
        recordingStartedAt = nil
        suppressLLMPolish = false
        clearCurrentOperation()
        _state = .idle
    }

    public func undoCancel() async throws -> DictationResult {
        guard case .cancelled = _state else {
            throw DictationServiceError.notCancelled
        }
        guard let audioURL = pendingCancelledAudioURL else {
            _state = .idle
            throw DictationServiceError.noPendingCancelledAudio
        }

        cancelGeneration += 1
        cancelResetTask?.cancel()
        cancelResetTask = nil
        pendingCancelledAudioURL = nil

        let currentSession = activeSessionID
        _state = .processing
        do {
            let result = try await withCurrentObservabilityContextIfAny {
                try await processCapturedAudio(audioURL: audioURL)
            }
            let device = await audioProcessor.recordingDeviceInfo
            // Guard against reentrancy: a new session may have started while we
            // transcribed the undone audio, replacing this one. Don't overwrite
            // its state. Mirrors stopRecording(sessionID:).
            guard activeSessionID == currentSession else {
                logger.notice(
                    "undoCancel result discarded session=\(currentSession) replaced by=\(self.activeSessionID)"
                )
                return result
            }
            _state = .success(result.dictation)
            sendDictationOperation(
                outcome: .success,
                durationSeconds: Double(result.dictation.durationMs) / 1000.0,
                wordCount: result.dictation.wordCount,
                speechEngine: result.dictation.engine,
                engineVariant: result.dictation.engineVariant,
                language: result.dictation.language,
                device: device
            )
            Telemetry.send(.dictationCompleted(
                durationSeconds: Double(result.dictation.durationMs) / 1000.0,
                wordCount: result.dictation.wordCount,
                mode: currentTelemetryContext.mode,
                speechEngine: result.dictation.engine,
                engineVariant: result.dictation.engineVariant,
                language: result.dictation.language,
                appCategory: currentTelemetryContext.appCategory,
                device: device
            ))
            try? await Task.sleep(for: .milliseconds(500))
            guard activeSessionID == currentSession else { return result }
            _state = .idle
            recordingStartedAt = nil
            clearCurrentOperation()
            return result
        } catch {
            let device = await audioProcessor.recordingDeviceInfo
            guard activeSessionID == currentSession else {
                logger.notice(
                    "undoCancel error discarded session=\(currentSession) replaced by=\(self.activeSessionID)"
                )
                throw error
            }
            _state = .idle
            if Self.isNoSpeechError(error) {
                sendDictationOperation(
                    outcome: .empty,
                    durationSeconds: currentRecordingDurationSeconds(),
                    errorType: Self.errorType(for: error),
                    device: device
                )
                Telemetry.send(.dictationEmpty(durationSeconds: currentRecordingDurationSeconds(), device: device))
            } else {
                sendDictationOperation(
                    outcome: .failure,
                    durationSeconds: currentRecordingDurationSeconds(),
                    errorType: Self.errorType(for: error),
                    device: device
                )
                Telemetry.send(.dictationFailed(errorType: Self.errorType(for: error), errorDetail: TelemetryErrorClassifier.errorDetail(error), device: device))
            }
            recordingStartedAt = nil
            clearCurrentOperation()
            throw error
        }
    }

    // MARK: - Streaming overlay (fork-only)

    /// Spin up a background task that feeds audio buffers from the broadcaster into
    /// the streaming transcriber and logs partial transcripts. Best-effort: errors
    /// here never affect the authoritative batch dictation path.
    private func startStreamingSessionIfEnabled(sessionID: Int) {
        guard streamingOverlayEnabled(),
              let broadcaster = streamingBroadcaster,
              let transcriber = streamingTranscriber
        else { return }

        activeStreamingTask?.cancel()
        // Subscribe to the broadcaster synchronously so buffers produced while the
        // streaming model loads (worst case ~70 s on first-ever dictation) are
        // dropped into the AsyncStream's bufferingNewest(200) window instead of
        // missed entirely. Subsequent dictations load instantly from cache.
        let audioStream = Task<AsyncStream<AVAudioPCMBuffer>, Never> {
            await broadcaster.subscribeToAudioBuffers()
        }
        activeStreamingTask = Task { [weak self, logger = self.logger] in
            let stream = await audioStream.value
            do {
                if await transcriber.isReady() == false {
                    try await transcriber.loadModels()
                }
                let partialStream = try await transcriber.startSession()
                logger.debug("streaming_session_started session=\(sessionID)")

                let partialTask = Task { [weak self] in
                    for await partial in partialStream {
                        logger.info(
                            "streaming_partial session=\(sessionID) chars=\(partial.count)"
                        )
                        #if DEBUG
                        logger.debug(
                            "streaming_partial_text session=\(sessionID) text=\(partial, privacy: .public)"
                        )
                        #endif
                        await self?.reportStreamingPartial(partial, sessionID: sessionID)
                    }
                }

                for await buffer in stream {
                    if Task.isCancelled { break }
                    do {
                        try await transcriber.appendAudio(buffer)
                    } catch {
                        logger.warning(
                            "streaming_append_error session=\(sessionID) error=\(error.localizedDescription, privacy: .private)"
                        )
                        break
                    }
                }

                if Task.isCancelled {
                    partialTask.cancel()
                } else {
                    _ = try? await transcriber.finish()
                    _ = await partialTask.value
                }
                logger.debug("streaming_session_ended session=\(sessionID)")
            } catch is CancellationError {
                // Don't touch transcriber state on cancellation; let the next
                // startSession clean up.
            } catch {
                logger.warning(
                    "streaming_session_error session=\(sessionID) error=\(error.localizedDescription, privacy: .private)"
                )
            }
        }
    }

    /// Deliver a streaming partial transcript to the overlay UI, guarded so stale
    /// callbacks from a replaced session never overwrite the current session's text.
    private func reportStreamingPartial(_ partial: String, sessionID: Int) {
        guard sessionID == activeSessionID else { return }
        lastStreamingPartialBySession[sessionID] = partial
        streamingPartialHandler?(partial)
    }

    /// Returns the most recent streaming partial text seen for the given session,
    /// or nil if none yet (or if the session has been replaced). Used by the
    /// dictation flow coordinator's watchdog as a fallback when batch transcribe stalls.
    public func currentStreamingPartial(sessionID: Int) -> String? {
        guard sessionID == activeSessionID else { return nil }
        return lastStreamingPartialBySession[sessionID]
    }

    private func endStreamingSession() {
        activeStreamingTask?.cancel()
        activeStreamingTask = nil
    }

    /// Run a live LLM cleanup pass on `text` using the same formatter prompt as
    /// end-of-dictation polish. Returns the cleaned string, or nil when the formatter
    /// is unavailable, suppressed, or the LLM call fails.
    public func cleanupTextLive(_ text: String) async -> String? {
        guard shouldUseAIFormatter(), let llmService else {
            logger.info("live_cleanup_skipped reason=formatter_or_service_unavailable")
            return nil
        }
        guard !suppressLLMPolish else {
            logger.info("live_cleanup_skipped reason=suppressed_for_assistant")
            return nil
        }
        let userTemplate = aiFormatterPromptTemplate()
        let baseTemplate = activeProfile?.promptOverride ?? userTemplate
        let template = AIFormatter.injectContextIntoPrompt(template: baseTemplate, context: activeAppContext)
        let defaultPromptUsed = activeProfile?.promptOverride == nil
            && AIFormatter.normalizedPromptTemplate(userTemplate) == AIFormatter.defaultPromptTemplate
        logger.info("live_cleanup_start inputChars=\(text.count) profile=\(self.activeProfile?.id ?? "none", privacy: .public) hasContext=\(self.activeAppContext != nil)")
        do {
            let formatted = try await llmService.formatTranscript(
                transcript: text,
                promptTemplate: template,
                source: .dictation,
                defaultPromptUsed: defaultPromptUsed
            )
            let trimmed = formatted.trimmingCharacters(in: .whitespacesAndNewlines)
            logger.info("live_cleanup_done outputChars=\(trimmed.count)")
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            logger.warning("live_cleanup_failed error=\(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    // MARK: - Private

    /// Whether the error represents "no speech" (empty transcript or recording too short).
    private static func isNoSpeechError(_ error: Error) -> Bool {
        if let e = error as? DictationServiceError, e == .emptyTranscript { return true }
        if let e = error as? AudioProcessorError, case .insufficientSamples = e { return true }
        return false
    }

    private static func isInterruptedDuringSubscribe(_ error: Error) -> Bool {
        guard let e = error as? AudioProcessorError,
              case .recordingFailed(let reason) = e else {
            return false
        }
        return reason == "interrupted during subscribe"
    }

    private func discardPendingCancelledAudio() {
        if let url = pendingCancelledAudioURL {
            try? FileManager.default.removeItem(at: url)
        }
        pendingCancelledAudioURL = nil
    }

    private func withCurrentObservabilityContextIfAny<T: Sendable>(
        _ operation: () async throws -> T
    ) async rethrows -> T {
        guard let operationContext = currentObservabilityOperationContext else {
            return try await operation()
        }
        return try await Observability.withOperationContext(operationContext) {
            try await operation()
        }
    }

    private func processCapturedAudio(audioURL: URL) async throws -> DictationResult {
        // Track whether the audio file is consumed (moved or explicitly deleted).
        // If an error occurs before that point, clean up the temp file.
        var audioConsumed = false
        defer {
            if !audioConsumed {
                try? FileManager.default.removeItem(at: audioURL)
            }
        }

        AudioCaptureDiagnostics.append(
            "dictation_transcribe_begin file_bytes=\(Self.fileSizeBytes(at: audioURL).map(String.init) ?? "unknown")"
        )
        let result = try await sttTranscriber.transcribe(audioPath: audioURL.path, job: .dictation)
        logger.debug("dictation_transcription_complete chars=\(result.text.count, privacy: .public)")
        AudioCaptureDiagnostics.append(
            "dictation_transcribe_complete chars=\(result.text.count) words=\(result.words.count) engine=\(result.engine.rawValue) variant=\(result.engineVariant ?? "none")"
        )

        let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // defer will clean up audioURL
            logger.warning("dictation_transcription_empty")
            AudioCaptureDiagnostics.append("dictation_transcribe_empty")
            throw DictationServiceError.emptyTranscript
        }

        let mode = processingMode()
        var words: [CustomWord] = []
        var snippets: [TextSnippet] = []
        if mode.usesDeterministicPipeline {
            do { words = try customWordRepo?.fetchEnabled() ?? [] }
            catch { logger.error("dictation_custom_words_fetch_failed error_type=\(Self.errorType(for: error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)") }
            do { snippets = try snippetRepo?.fetchEnabled() ?? [] }
            catch { logger.error("dictation_snippets_fetch_failed error_type=\(Self.errorType(for: error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)") }
        }

        // Voice Return: inject a synthetic action snippet regardless of processing
        // mode (raw mode extracts the trailing action without running the full
        // pipeline). The snippet matches the trigger phrase at the END of the
        // dictation and strips it. Whether that match means "submit" (.send) or
        // "hold" (.hold) is resolved after refinement by resolveVoiceReturnAction.
        let voiceReturnTriggerPhrase = voiceReturnTrigger()
        let voiceReturnActive = !(voiceReturnTriggerPhrase ?? "").isEmpty
        if let trigger = voiceReturnTriggerPhrase, !trigger.isEmpty {
            snippets.append(TextSnippet(
                trigger: trigger,
                expansion: KeyAction.returnKey.label,
                action: .returnKey
            ))
        }
        let refinement = await textRefinementService.refine(
            rawText: result.text,
            mode: mode,
            customWords: words,
            snippets: snippets,
            profile: activeProfile,
            smartFormatting: smartFormatting?() ?? false
        )
        let cleanTranscript = refinement.text
        let expandedSnippetIDs = refinement.expandedSnippetIDs
        let baseText = cleanTranscript ?? result.text
        let saveHistory = shouldSaveDictationHistory?() ?? true
        let dictationID = UUID()
        let formatterOutcome = try await formatTranscriptIfNeeded(
            baseText,
            runSource: saveHistory ? LLMRunSource(dictationId: dictationID) : nil
        )
        let formattedTranscript = formatterOutcome.text
        let finalText = formattedTranscript ?? baseText
        let wc = finalText.split(whereSeparator: \.isWhitespace).count

        var dictation = Dictation(
            id: dictationID,
            durationMs: computeDurationMs(from: result),
            rawTranscript: result.text,
            cleanTranscript: formattedTranscript ?? cleanTranscript,
            processingMode: mode,
            status: .completed,
            hidden: !saveHistory,
            wordCount: wc,
            engine: result.engine.rawValue,
            engineVariant: result.engineVariant,
            language: SpeechEnginePreference.normalizeKnownLanguage(result.language)
        )

        if saveHistory, shouldSaveAudio?() ?? false {
            do { try AppPaths.ensureDirectories() }
            catch { logger.error("dictation_directory_create_failed error_type=\(Self.errorType(for: error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)") }
            let destURL = URL(fileURLWithPath: AppPaths.dictationsDir, isDirectory: true)
                .appendingPathComponent("\(dictation.id.uuidString).wav")

            if (try? FileManager.default.moveItem(at: audioURL, to: destURL)) != nil {
                dictation.audioPath = destURL.path
                audioConsumed = true  // moved to permanent storage
            }
            // If move failed, defer will clean up the temp file
        }
        // If not saving audio, defer will clean up the temp file

        if saveHistory {
            try dictationRepo.save(dictation)
            await llmRunRecorder.record(formatterOutcome.run)
        } else {
            var privateCopy = dictation
            privateCopy.rawTranscript = ""
            privateCopy.cleanTranscript = nil
            try dictationRepo.save(privateCopy)
        }
        markFirstDictationCompleted?()

        if !expandedSnippetIDs.isEmpty {
            try? snippetRepo?.incrementUseCount(ids: refinement.expandedSnippetIDs)
        }

        let postPasteAction = Self.resolveVoiceReturnAction(
            refinedAction: refinement.postPasteAction,
            mode: voiceReturnMode(),
            voiceReturnActive: voiceReturnActive
        )
        return DictationResult(dictation: dictation, postPasteAction: postPasteAction)
    }

    private func formatTranscriptIfNeeded(
        _ text: String,
        runSource: LLMRunSource?
    ) async throws -> FormatterOutcome {
        guard !suppressLLMPolish, shouldUseAIFormatter(), let llmService else {
            return .skipped
        }

        // Notify observers (e.g. the dictation flow coordinator) that the
        // LLM formatter is about to run so the overlay pill can switch to
        // its `.formatting` beat. We only post this *after* the guards
        // above so "formatter disabled" dictations never flicker into the
        // formatting visual.
        NotificationCenter.default.post(
            name: .macParakeetAIFormatterDidStart,
            object: nil,
            userInfo: ["source": "dictation"]
        )
        defer {
            NotificationCenter.default.post(
                name: .macParakeetAIFormatterDidFinish,
                object: nil,
                userInfo: ["source": "dictation"]
            )
        }

        let userTemplate = aiFormatterPromptTemplate()
        // Profile override wins over user template; context injection is then
        // layered on top of whichever base template is selected.
        let baseTemplate = activeProfile?.promptOverride ?? userTemplate
        let promptTemplate = AIFormatter.injectContextIntoPrompt(template: baseTemplate, context: activeAppContext)
        // Normalize before comparing: `AIFormatter.renderPrompt` passes the
        // template through `normalizedPromptTemplate` before sending, which
        // trims whitespace and folds legacy-v1 prompts back onto the current
        // default. Raw comparison would report those cases as custom prompts
        // even though the LLM sees the shipped default. Profile overrides and
        // context injection don't flip the bit — context is a per-dictation
        // prefix, not a user-configured change to the base prompt.
        let defaultPromptUsed = activeProfile?.promptOverride == nil
            && AIFormatter.normalizedPromptTemplate(userTemplate) == AIFormatter.defaultPromptTemplate
        let startedAt = Date()
        do {
            let result = try await llmService.formatTranscriptDetailed(
                transcript: text,
                promptTemplate: promptTemplate,
                source: .dictation,
                defaultPromptUsed: defaultPromptUsed
            )
            let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let run = runSource.map {
                LLMRun(formatterResult: result, source: $0, feature: .formatterDictation)
            }
            return FormatterOutcome(text: trimmed.isEmpty ? nil : trimmed, run: run)
        } catch {
            if error is CancellationError {
                throw error
            }
            logger.warning("dictation_ai_formatter_failed fallback=standard_cleanup error_type=\(Self.errorType(for: error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)")
            let message = "\(error.localizedDescription) Used standard cleanup."
            NotificationCenter.default.post(
                name: .macParakeetAIFormatterWarning,
                object: nil,
                userInfo: [
                    "source": "dictation",
                    "message": message,
                ]
            )
            let run = runSource.map {
                LLMRun.failedFormatterRun(
                    source: $0,
                    feature: .formatterDictation,
                    errorType: Self.errorType(for: error),
                    inputChars: text.count,
                    defaultPromptUsed: defaultPromptUsed,
                    startedAt: startedAt
                )
            }
            return FormatterOutcome(text: nil, run: run)
        }
    }

    private func computeDurationMs(from result: STTResult) -> Int {
        if let lastWord = result.words.last {
            return lastWord.endMs
        }
        return result.text.split(separator: " ").count * 150
    }

    private func resetAfterCancelIfStillCurrent(generation: Int) {
        guard generation == cancelGeneration else { return }
        if case .cancelled = _state {
            sendDictationOperation(
                outcome: .cancelled,
                durationSeconds: currentRecordingDurationSeconds(),
                cancelReason: pendingCancelReason
            )
            discardPendingCancelledAudio()
            recordingStartedAt = nil
            clearCurrentOperation()
            _state = .idle
        }
        cancelResetTask = nil
    }

    private func currentRecordingDurationSeconds() -> Double? {
        guard let recordingStartedAt else { return nil }
        return max(0, Date().timeIntervalSince(recordingStartedAt))
    }

    private static func fileSizeBytes(at url: URL) -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? UInt64 else {
            return nil
        }
        return size
    }

    /// Resolve the effective post-paste action for Voice Return, honoring the mode.
    ///
    /// The refinement engine sets `refinedAction == .returnKey` exactly when the
    /// trigger phrase was spoken at the end of the dictation (and has already
    /// stripped it from the text); otherwise it is `nil`. `KeyAction` has only
    /// `.returnKey`, so this signal is strictly nil-or-return.
    ///
    /// - `.send`: pass the signal through — phrase spoken ⇒ submit, else nothing.
    ///   This is the original behavior.
    /// - `.hold`: invert it — phrase spoken ⇒ hold (`nil`), else auto-submit
    ///   (`.returnKey`).
    ///
    /// When Voice Return is inactive (feature off / empty phrase) the signal is
    /// passed through unchanged so a disabled feature never auto-submits.
    static func resolveVoiceReturnAction(
        refinedAction: KeyAction?,
        mode: VoiceReturnMode,
        voiceReturnActive: Bool
    ) -> KeyAction? {
        guard voiceReturnActive else { return refinedAction }
        switch mode {
        case .send:
            return refinedAction
        case .hold:
            return refinedAction == .returnKey ? nil : .returnKey
        }
    }

    private func debugStateLabel(_ state: DictationState) -> String {
        switch state {
        case .idle:
            return "idle"
        case .recording:
            return "recording"
        case .processing:
            return "processing"
        case .success:
            return "success"
        case .cancelled:
            return "cancelled"
        case .error:
            return "error"
        }
    }

    private static func errorType(for error: Error) -> String {
        TelemetryErrorClassifier.classify(error)
    }

    private func clearCurrentOperation() {
        currentOperationID = nil
        currentOperationTelemetryContext = DictationTelemetryContext()
        currentObservabilityOperationContext = nil
        pendingCancelReason = nil
    }

    private func sendDictationOperation(
        operationID: String? = nil,
        operationContext: ObservabilityOperationContext? = nil,
        telemetryContext: DictationTelemetryContext? = nil,
        outcome: ObservabilityOutcome,
        durationSeconds: Double? = nil,
        wordCount: Int? = nil,
        errorType: String? = nil,
        cancelReason: TelemetryDictationCancelReason? = nil,
        speechEngine: String? = nil,
        engineVariant: String? = nil,
        language: String? = nil,
        device: RecordingDeviceInfo? = nil
    ) {
        guard let id = operationID ?? currentOperationID else { return }
        let context = telemetryContext ?? currentOperationTelemetryContext
        let observabilityContext = operationContext ?? currentObservabilityOperationContext
        Telemetry.send(.dictationOperation(
            operationID: id,
            operationContext: observabilityContext,
            outcome: outcome,
            trigger: context.trigger,
            mode: context.mode,
            durationSeconds: durationSeconds,
            wordCount: wordCount,
            errorType: errorType,
            cancelReason: cancelReason,
            speechEngine: speechEngine,
            engineVariant: engineVariant,
            language: language,
            appCategory: context.appCategory,
            device: device
        ))
    }
}

public enum DictationServiceError: Error, LocalizedError {
    case notRecording
    case notCancelled
    case noPendingCancelledAudio
    case emptyTranscript

    public var errorDescription: String? {
        switch self {
        case .notRecording: return "Not currently recording"
        case .notCancelled: return "Not currently in the cancel window"
        case .noPendingCancelledAudio: return "No cancelled recording to process"
        case .emptyTranscript: return "Couldn't hear you — try speaking closer to the microphone."
        }
    }
}
