import AppKit
import MacParakeetCore
import SwiftUI

/// NSPanel subclass that can become key AND main so the text field accepts
/// typing and the primary dictation hotkey's Cmd+V simulated paste lands
/// inside the bubble's text field. Non-activating would leave the previous
/// app frontmost and dictation would paste there instead.
private final class AIAssistantBubblePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Owns the AI Assistant bubble lifecycle for a single session — one bubble
/// per selection+question chain. Dismisses on Esc, click-outside (focus
/// resign), or explicit `dismiss()` call.
@MainActor
final class AIAssistantBubbleController {
    private let selection: String
    private let service: AIAssistantServiceProtocol
    private let onDismissed: () -> Void

    private let state = AIAssistantBubbleState()
    private var panel: AIAssistantBubblePanel?
    private var hostingView: NSHostingView<AIAssistantBubbleView>?
    private var resignObserver: NSObjectProtocol?
    private var activeTask: Task<Void, Never>?
    private var isDismissed = false

    init(
        selection: String,
        service: AIAssistantServiceProtocol,
        onDismissed: @escaping () -> Void
    ) {
        self.selection = selection
        self.service = service
        self.onDismissed = onDismissed
    }

    /// Convenience: open a bubble in error state without a usable selection.
    /// Used when AX selection grab failed and we still want to surface
    /// visible feedback to the user (instead of an inaudible beep).
    func showError(_ message: String) {
        state.errorMessage = message
        show()
    }

    /// Open the bubble in "Listening…" state. Called immediately on hotkey
    /// press (while the user is speaking) so they get visual feedback that
    /// voice capture is in progress.
    func showListening() {
        state.isListening = true
        state.errorMessage = nil
        show()
    }

    /// Called after voice capture completes. Transitions out of the
    /// listening state and submits the dictated transcript as the first
    /// (or next) question to the CLI. Empty transcripts clear the listening
    /// state but don't submit — matches the "no voice, no action" rule.
    func submitVoiceTranscript(_ transcript: String) {
        state.isListening = false
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        submit(question: trimmed)
    }

    /// Called when voice capture is cancelled or errors out without a
    /// transcript. Clears the listening state so the bubble doesn't hang.
    func clearListening() {
        state.isListening = false
    }

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    func show() {
        guard panel == nil else {
            panel?.makeKeyAndOrderFront(nil)
            return
        }

        let view = AIAssistantBubbleView(
            state: state,
            onSubmit: { [weak self] question in
                self?.submit(question: question)
            },
            onDismiss: { [weak self] in
                self?.dismiss()
            }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 420, height: 280)
        hosting.autoresizingMask = [.width, .height]
        self.hostingView = hosting

        // Non-activating panel: doesn't steal focus from the user's target
        // app, which keeps the text selection visible during the bubble
        // session and — critically — avoids an AVAudioEngine startup failure
        // that occurs when the app activates mid-audio-init. Trade-off:
        // follow-up dictation via the primary hotkey will paste into the
        // previously-focused app, not the bubble (chunk C will route that
        // via DictationFlowCoordinator instead of the system paste path).
        let newPanel = AIAssistantBubblePanel(
            contentRect: hosting.frame,
            styleMask: [.nonactivatingPanel, .borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = true
        newPanel.level = .floating
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.isReleasedWhenClosed = false
        newPanel.contentView = hosting
        newPanel.isMovableByWindowBackground = true

        positionCenter(newPanel)

        // Dismiss when the panel loses focus (click-outside). Filtered to this
        // panel specifically so unrelated resign notifications don't close us.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: newPanel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.dismiss()
            }
        }

        newPanel.makeKeyAndOrderFront(nil)
        self.panel = newPanel
    }

    func dismiss() {
        guard !isDismissed else { return }
        isDismissed = true
        activeTask?.cancel()
        activeTask = nil
        if let observer = resignObserver {
            NotificationCenter.default.removeObserver(observer)
            resignObserver = nil
        }
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
        onDismissed()
    }

    private func submit(question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !state.isThinking else { return }

        state.isThinking = true
        state.errorMessage = nil

        let history = state.history
        let request = AIAssistantRequest(
            selection: selection,
            question: trimmed,
            history: history
        )

        activeTask?.cancel()
        activeTask = Task { [service, weak self] in
            do {
                let response = try await service.ask(request)
                await MainActor.run {
                    guard let self else { return }
                    self.state.history.append(AIAssistantTurn(question: trimmed, response: response))
                    self.state.isThinking = false
                }
            } catch is CancellationError {
                await MainActor.run {
                    self?.state.isThinking = false
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.state.errorMessage = error.localizedDescription
                    self.state.isThinking = false
                }
            }
        }
    }

    private func positionCenter(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let panelSize = panel.frame.size
        let origin = NSPoint(
            x: frame.midX - panelSize.width / 2,
            y: frame.midY - panelSize.height / 2
        )
        panel.setFrameOrigin(origin)
    }
}
