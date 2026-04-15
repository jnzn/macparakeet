import AppKit
import MacParakeetCore
import OSLog

/// Orchestrates the AI Assistant hotkey flow. Hold-to-talk semantics:
///
///   press hotkey → grab AX selection → if error, show error bubble;
///                  else open bubble in "Listening…" state + start DictationService
///   hold         → user speaks
///   release      → stop DictationService → get transcript → if empty, dismiss
///                  listening bubble; else auto-submit transcript as first
///                  question to the CLI and render the response in the bubble
///
/// Once the bubble is visible with a response, it stays open until the user
/// clicks outside or hits Esc. Follow-ups can be typed in the text field or
/// dictated via the primary dictation hotkey — MacParakeet activates when the
/// bubble opens, so the dictation paste lands in the bubble's text field
/// rather than the previous app.
@MainActor
final class AIAssistantFlowCoordinator {
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "AIAssistantFlow")
    private let service: AIAssistantServiceProtocol
    private let accessibilityService: AccessibilityService
    private let selectionReader: SelectionReader
    private let configStore: AIAssistantConfigStore
    private let dictationService: DictationService

    private var activeBubble: AIAssistantBubbleController?
    /// Tracks whether the current bubble is actively recording voice via the
    /// hotkey. Nil when no recording is in flight.
    private var isCapturingVoice: Bool = false

    init(
        service: AIAssistantServiceProtocol,
        accessibilityService: AccessibilityService,
        configStore: AIAssistantConfigStore,
        dictationService: DictationService
    ) {
        self.service = service
        self.accessibilityService = accessibilityService
        self.selectionReader = SelectionReader(accessibility: accessibilityService)
        self.configStore = configStore
        self.dictationService = dictationService
    }

    // MARK: - Hotkey press / release

    /// Called on Control+Shift+A key-down. Grabs the current AX selection and
    /// either opens an error bubble (nothing selected / AX unavailable) or
    /// opens a listening bubble and begins voice capture.
    func handleHotkeyPress() {
        if activeBubble?.isVisible == true {
            // Guard against multi-press while bubble is up — ignore additional
            // press events until the current session ends.
            logger.info("hotkey_press ignored — bubble already open")
            return
        }

        // Selection grab: tries AX first, falls back to Cmd+C probe for
        // Electron / web apps that don't expose AX selection.
        let selection: String
        do {
            let result = try selectionReader.readSelection()
            selection = result.text
            logger.info("hotkey_press selection source=\(result.source.rawValue, privacy: .public) chars=\(selection.count)")
        } catch SelectionReader.Error.noSelection {
            logger.info("hotkey_press selection_error reason=no_selection")
            spawnErrorBubble(message: Self.selectionErrorMessage(for: .noSelection))
            return
        } catch SelectionReader.Error.accessibilityPermissionRequired {
            logger.info("hotkey_press selection_error reason=no_permission")
            spawnErrorBubble(message: Self.selectionErrorMessage(for: .notAuthorized))
            return
        } catch {
            logger.info("hotkey_press selection_error reason=probe_failed detail=\(error.localizedDescription, privacy: .public)")
            spawnErrorBubble(message: Self.selectionErrorMessage(for: .probeFailed(error.localizedDescription)))
            return
        }

        if configStore.load() == nil {
            logger.info("hotkey_press opening with no config; service will error on first ask")
        }

        logger.info("hotkey_press spawn listening bubble selectionChars=\(selection.count)")
        let bubble = AIAssistantBubbleController(
            selection: selection,
            service: service,
            onDismissed: { [weak self] in
                self?.activeBubble = nil
                self?.isCapturingVoice = false
            }
        )
        bubble.showListening()
        activeBubble = bubble

        // Start voice capture. DictationService returns the transcript from
        // its stopRecording call on release, so the paste/history side-effects
        // are avoided — we consume the result ourselves.
        //
        // First-start retry: AVAudioEngine.start() often fails the very first
        // time the process touches audio (CoreAudio HAL cold-start race,
        // observed as `com.apple.coreaudio.avfaudio error 2003329396`). A
        // short re-try after the first failure succeeds reliably. Matches the
        // behavior observed when a user invokes primary dictation first to
        // "warm up" and then uses the AI hotkey.
        isCapturingVoice = true
        Task { [dictationService, logger] in
            do {
                // Tell DictationService to bypass per-app profile polish
                // (terminal transliteration, email formality, etc.) for
                // this recording. The spoken input is a direct instruction
                // to the CLI agent — it should reach Claude/Codex as raw
                // Parakeet output, not mangled by the Terminal profile's
                // "see dee slash" → "cd /" rule.
                await dictationService.setSuppressLLMPolish(true)
                try await Self.startRecordingWithColdRetry(
                    service: dictationService,
                    logger: logger
                )
            } catch {
                logger.warning("hotkey_press startRecording failed error=\(error.localizedDescription, privacy: .private)")
                await dictationService.setSuppressLLMPolish(false)
                await MainActor.run { [weak self] in
                    self?.activeBubble?.clearListening()
                    self?.activeBubble?.showError("Couldn't start voice capture: \(error.localizedDescription)")
                    self?.isCapturingVoice = false
                }
            }
        }
    }

    private static func startRecordingWithColdRetry(
        service: DictationService,
        logger: Logger
    ) async throws {
        do {
            try await service.startRecording()
        } catch {
            let message = error.localizedDescription.lowercased()
            let looksLikeColdStart = message.contains("engine failed to start")
                || message.contains("2003329396")
            guard looksLikeColdStart else { throw error }
            logger.info("hotkey_press cold_start retry in 250ms")
            try? await Task.sleep(for: .milliseconds(250))
            try await service.startRecording()
        }
    }

    /// Called on Control+Shift+A key-up. Stops the voice capture, collects
    /// the transcript, and auto-submits it to the CLI via the bubble.
    func handleHotkeyRelease() {
        guard isCapturingVoice else {
            // Key-up for a press we never acted on (error bubble path, or
            // pre-existing visible bubble). Nothing to do.
            return
        }
        isCapturingVoice = false

        guard let bubble = activeBubble else {
            Task { [dictationService] in
                await dictationService.cancelRecording(reason: nil)
                await dictationService.confirmCancel()
            }
            return
        }

        logger.info("hotkey_release stopping voice capture")
        Task { [dictationService, logger, weak self] in
            do {
                let result = try await dictationService.stopRecording()
                await dictationService.setSuppressLLMPolish(false)
                // Always prefer rawTranscript here. With suppressLLMPolish
                // set, cleanTranscript is just the deterministic-pipeline
                // output (custom words + snippets + filler removal) — fine
                // — but rawTranscript matches what the user actually spoke
                // more closely and there's nothing to gain from running
                // Parakeet output through the pipeline for a CLI prompt.
                let transcript = result.dictation.rawTranscript
                logger.info("hotkey_release transcript chars=\(transcript.count)")
                await MainActor.run {
                    bubble.submitVoiceTranscript(transcript)
                }
            } catch {
                await dictationService.setSuppressLLMPolish(false)
                logger.info("hotkey_release stop failed (likely empty) error=\(error.localizedDescription, privacy: .private)")
                await MainActor.run { [weak self] in
                    // Empty transcript / short recording → just clear the
                    // listening state. Bubble stays open so user can type.
                    bubble.clearListening()
                    // If the error is something other than "no speech",
                    // surface it for visibility.
                    if !Self.isNoSpeech(error) {
                        bubble.showError("Voice capture failed: \(error.localizedDescription)")
                    }
                }
                _ = self
            }
        }
    }

    // MARK: - Lifecycle

    /// Called from the app shutdown path so the bubble doesn't linger past
    /// termination.
    func dismissAny() {
        if isCapturingVoice {
            Task { [dictationService] in
                await dictationService.cancelRecording(reason: nil)
                await dictationService.confirmCancel()
            }
            isCapturingVoice = false
        }
        activeBubble?.dismiss()
        activeBubble = nil
    }

    // MARK: - Private

    private func spawnErrorBubble(message: String) {
        let bubble = AIAssistantBubbleController(
            selection: "",
            service: service,
            onDismissed: { [weak self] in
                self?.activeBubble = nil
                self?.isCapturingVoice = false
            }
        )
        bubble.showError(message)
        activeBubble = bubble
    }

    private static func isNoSpeech(_ error: Error) -> Bool {
        if let e = error as? DictationServiceError, e == .emptyTranscript { return true }
        return false
    }

    /// Failure categories used to generate the user-facing error bubble
    /// after `SelectionReader` has already tried AX + Cmd+C probe.
    private enum SelectionFailure {
        case noSelection
        case notAuthorized
        case probeFailed(String)
    }

    private static func selectionErrorMessage(for failure: SelectionFailure) -> String {
        switch failure {
        case .noSelection:
            return "No text is selected.\n\nHighlight (don't just click) the text you want to ask about, then press the hotkey again."
        case .notAuthorized:
            return "Accessibility permission is required to read selected text. Grant it to MacParakeet in System Settings → Privacy & Security → Accessibility, then press the hotkey again."
        case .probeFailed(let detail):
            return "Couldn't read the selected text:\n\(detail)\n\nTry selecting the text again and pressing the hotkey."
        }
    }
}
