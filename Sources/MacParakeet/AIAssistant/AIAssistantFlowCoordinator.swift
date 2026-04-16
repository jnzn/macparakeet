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
    private let selectionReplacer: SelectionReplacer
    private let configStore: AIAssistantConfigStore
    private let dictationService: DictationService

    private var activeBubble: AIAssistantBubbleController?
    /// Tracks whether the current bubble is actively recording voice via the
    /// hotkey. Nil when no recording is in flight.
    private var isCapturingVoice: Bool = false

    /// Gesture state machine, matching primary dictation's two-gesture model:
    ///   hold-to-talk: press → record while held → release submits
    ///   double-tap-to-lock: quick tap + quick tap → lock recording → single
    ///                       tap again stops + submits
    ///
    /// `awaitingDoubleTap` is the bridge state between "user released quickly"
    /// and "this was a one-shot quick tap" — we don't stop recording yet
    /// because a second press within `doubleTapWindow` would upgrade the
    /// gesture to a lock.
    private enum Mode {
        case idle
        case holding
        case awaitingDoubleTap
        case locked
    }
    private var mode: Mode = .idle
    private var pressStartedAt: Date?
    private var pendingSubmitTask: Task<Void, Never>?
    private static let holdThreshold: TimeInterval = 0.3
    private static let doubleTapWindow: TimeInterval = 0.35

    init(
        service: AIAssistantServiceProtocol,
        accessibilityService: AccessibilityService,
        clipboardService: ClipboardService,
        configStore: AIAssistantConfigStore,
        dictationService: DictationService
    ) {
        self.service = service
        self.accessibilityService = accessibilityService
        self.selectionReader = SelectionReader(accessibility: accessibilityService)
        self.selectionReplacer = SelectionReplacer(clipboardService: clipboardService)
        self.configStore = configStore
        self.dictationService = dictationService
    }

    // MARK: - Hotkey press / release / doubleTap

    /// Called on hotkey key-down. Dispatches through the gesture state
    /// machine so that holds enter hold-to-talk and quick taps wait for a
    /// possible double-tap upgrade.
    func handleHotkeyPress() {
        switch mode {
        case .locked:
            // Single tap while recording is locked → stop + submit.
            logger.info("hotkey_press in locked mode → stop + submit")
            mode = .idle
            stopAndFinalize(submit: true)
            return
        case .awaitingDoubleTap:
            // Press arrived during the tap window but `onDoubleTap` already
            // handled it — this is the onTrigger companion that
            // GlobalShortcutManager no longer emits for the second press of
            // a double-tap, so this branch should be unreachable. Guard
            // anyway.
            return
        case .holding:
            // Already holding (shouldn't see a second press without a
            // release first). Ignore.
            return
        case .idle:
            break
        }

        if activeBubble?.isVisible == true {
            // Defensive: an error bubble is visible from a prior failed
            // selection grab. Re-pressing should close it and start fresh.
            logger.info("hotkey_press with error bubble open — dismissing first")
            activeBubble?.dismiss()
            activeBubble = nil
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

        // Capture source-app pid BEFORE we spawn the bubble so the
        // SelectionReplacer can refocus the right window when the user
        // triggers an inline-replace later.
        let sourcePID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        logger.info("hotkey_press spawn listening bubble selectionChars=\(selection.count)")
        let bubble = AIAssistantBubbleController(
            selection: selection,
            service: service,
            configStore: configStore,
            selectionReplacer: selectionReplacer,
            sourceAppPID: sourcePID,
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
        mode = .holding
        pressStartedAt = Date()
        pendingSubmitTask?.cancel()
        pendingSubmitTask = nil
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
                    self?.mode = .idle
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

    /// Called on hotkey key-up. Distinguishes hold-to-talk (long press →
    /// submit now) from quick tap (maybe the first half of a double-tap →
    /// wait and see).
    func handleHotkeyRelease() {
        guard mode == .holding else {
            // Release arrived in a non-holding mode: either the locked-mode
            // press already transitioned us to .idle (and we're seeing the
            // key-up of a tap that stopped the lock), or startRecording
            // failed and mode is already .idle. Either way, nothing to do.
            return
        }

        let duration = pressStartedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        pressStartedAt = nil

        if duration >= Self.holdThreshold {
            // Long hold → classic hold-to-talk. Stop + submit immediately.
            logger.info("hotkey_release hold gesture duration=\(String(format: "%.2f", duration)) → submit")
            mode = .idle
            stopAndFinalize(submit: true)
        } else {
            // Quick tap → wait `doubleTapWindow` for a possible second press
            // that'd upgrade this to a locked-recording gesture. Leave the
            // bubble in listening state for now.
            logger.info("hotkey_release quick tap duration=\(String(format: "%.2f", duration)) → awaiting double-tap")
            mode = .awaitingDoubleTap
            pendingSubmitTask = Task { [weak self] in
                let windowMs = Int(Self.doubleTapWindow * 1000)
                try? await Task.sleep(for: .milliseconds(windowMs))
                await MainActor.run {
                    guard let self, !Task.isCancelled else { return }
                    guard self.mode == .awaitingDoubleTap else { return }
                    self.logger.info("hotkey_release double-tap window expired → submit as single tap")
                    self.mode = .idle
                    self.stopAndFinalize(submit: true)
                }
            }
        }
    }

    /// Called when GlobalShortcutManager detects two rapid presses within
    /// `doubleTapWindowSeconds`. Upgrades the gesture to locked recording —
    /// mic stays open until the user taps the hotkey once more (which routes
    /// through `handleHotkeyPress` while `mode == .locked`).
    func handleHotkeyDoubleTap() {
        guard mode == .awaitingDoubleTap else {
            logger.info("hotkey_doubleTap ignored — mode=\(String(describing: self.mode), privacy: .public)")
            return
        }
        logger.info("hotkey_doubleTap → locked recording")
        pendingSubmitTask?.cancel()
        pendingSubmitTask = nil
        mode = .locked
        // Recording continues from the first press. Bubble keeps showing
        // the listening indicator. User does a single tap to stop.
    }

    /// Shared stop path. If `submit == false`, cancels the recording and
    /// dismisses the bubble (used for explicit cancel flows). If true,
    /// submits the transcript via the bubble and leaves the bubble open
    /// for the CLI response.
    private func stopAndFinalize(submit: Bool) {
        guard isCapturingVoice else { return }
        isCapturingVoice = false
        pendingSubmitTask?.cancel()
        pendingSubmitTask = nil

        guard let bubble = activeBubble, submit else {
            Task { [dictationService] in
                await dictationService.cancelRecording(reason: nil)
                await dictationService.confirmCancel()
                await dictationService.setSuppressLLMPolish(false)
            }
            return
        }

        logger.info("stop_and_finalize submit=\(submit, privacy: .public)")
        Task { [dictationService, logger] in
            do {
                let result = try await dictationService.stopRecording()
                await dictationService.setSuppressLLMPolish(false)
                let transcript = result.dictation.rawTranscript
                logger.info("stop_and_finalize transcript chars=\(transcript.count)")
                await MainActor.run {
                    bubble.submitVoiceTranscript(transcript)
                }
            } catch {
                await dictationService.setSuppressLLMPolish(false)
                logger.info("stop_and_finalize stop failed error=\(error.localizedDescription, privacy: .private)")
                await MainActor.run {
                    bubble.clearListening()
                    if !Self.isNoSpeech(error) {
                        bubble.showError("Voice capture failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    // MARK: - Lifecycle

    /// Called from the app shutdown path so the bubble doesn't linger past
    /// termination.
    func dismissAny() {
        pendingSubmitTask?.cancel()
        pendingSubmitTask = nil
        if isCapturingVoice {
            Task { [dictationService] in
                await dictationService.cancelRecording(reason: nil)
                await dictationService.confirmCancel()
                await dictationService.setSuppressLLMPolish(false)
            }
            isCapturingVoice = false
        }
        mode = .idle
        pressStartedAt = nil
        activeBubble?.dismiss()
        activeBubble = nil
    }

    // MARK: - Private

    private func spawnErrorBubble(message: String) {
        // Error bubbles have no source selection to replace; pass nil PID
        // so the bubble suppresses the "Replace selection" button.
        let bubble = AIAssistantBubbleController(
            selection: "",
            service: service,
            configStore: configStore,
            selectionReplacer: selectionReplacer,
            sourceAppPID: nil,
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
