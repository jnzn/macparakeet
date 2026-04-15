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
    private let configStore: AIAssistantConfigStore
    private let onDismissed: () -> Void

    private let state = AIAssistantBubbleState()
    private var panel: AIAssistantBubblePanel?
    private var hostingView: NSHostingView<AIAssistantBubbleView>?
    private var resignObserver: NSObjectProtocol?
    private var partialObserver: NSObjectProtocol?
    private var activeTask: Task<Void, Never>?
    private var isDismissed = false

    init(
        selection: String,
        service: AIAssistantServiceProtocol,
        configStore: AIAssistantConfigStore,
        onDismissed: @escaping () -> Void
    ) {
        self.selection = selection
        self.service = service
        self.configStore = configStore
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
        state.listeningPartialText = ""
        state.errorMessage = nil
        subscribeToStreamingPartials()
        show()
    }

    /// Called after voice capture completes. Transitions out of the
    /// listening state and submits the dictated transcript as the first
    /// (or next) question to the CLI. Empty transcripts clear the listening
    /// state but don't submit — matches the "no voice, no action" rule.
    func submitVoiceTranscript(_ transcript: String) {
        state.isListening = false
        state.listeningPartialText = ""
        unsubscribeFromStreamingPartials()
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        submit(question: trimmed)
    }

    /// Called when voice capture is cancelled or errors out without a
    /// transcript. Clears the listening state so the bubble doesn't hang.
    func clearListening() {
        state.isListening = false
        state.listeningPartialText = ""
        unsubscribeFromStreamingPartials()
    }

    /// Subscribe to `.macParakeetStreamingPartial` notifications so the
    /// user sees live ASR text as they speak. Only flows when "Live
    /// transcript overlay" is enabled in Settings (that's the gate on the
    /// streaming EOU model being loaded). When disabled, the bubble stays
    /// at just "Listening…" — no-op fallback.
    private func subscribeToStreamingPartials() {
        guard partialObserver == nil else { return }
        partialObserver = NotificationCenter.default.addObserver(
            forName: .macParakeetStreamingPartial,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let text = note.userInfo?["text"] as? String else { return }
            Task { @MainActor in
                guard let self, self.state.isListening else { return }
                self.state.listeningPartialText = text
            }
        }
    }

    private func unsubscribeFromStreamingPartials() {
        if let observer = partialObserver {
            NotificationCenter.default.removeObserver(observer)
            partialObserver = nil
        }
    }

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    /// True when the panel is currently key (user just clicked it or it just
    /// opened). The paste interceptor uses this to decide whether an
    /// incoming primary-dictation transcript should feed the bubble's input
    /// field or fall through to the user's previous app.
    var isKey: Bool {
        panel?.isKeyWindow ?? false
    }

    /// Append a dictated transcript into the bubble's text input. Called by
    /// `AIAssistantPasteInterceptor` when primary dictation fires while this
    /// bubble is key. Auto-submits iff `submitAfter` is true — set when the
    /// dictation ended with the user's Voice Return trigger (e.g. "press
    /// return", "go") so speaking a submit cue acts like hitting Enter.
    func appendDictationFollowUp(_ text: String, submitAfter: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if submitAfter, !state.currentInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Edge case: empty transcript but the action signal fired
                // (user said only the return trigger) — submit what's
                // already in the input field.
                submitCurrentInput()
            }
            return
        }
        if state.currentInput.isEmpty {
            state.currentInput = trimmed
        } else {
            state.currentInput += " " + trimmed
        }
        if submitAfter {
            submitCurrentInput()
        }
    }

    private func submitCurrentInput() {
        let q = state.currentInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !state.isThinking else { return }
        state.currentInput = ""
        submit(question: q)
    }

    func show() {
        guard panel == nil else {
            panel?.makeKeyAndOrderFront(nil)
            return
        }

        // Load the config once at show time. Color changes from Settings
        // take effect on the next bubble open — no live updates while a
        // bubble is already on screen, by design.
        let backgroundColor = (configStore.load()?.effectiveBubbleBackgroundColor
            ?? AIAssistantConfig.defaultBubbleBackgroundColor)
            .toSwiftUIColor()

        let view = AIAssistantBubbleView(
            state: state,
            backgroundColor: backgroundColor,
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

        // Initial position: screen center so the panel has somewhere safe
        // to live while we compute a better anchor. Doing the AX-based
        // smart placement synchronously here blocks the main thread for
        // however long AX takes on the target app — which on Electron /
        // web apps can be 100ms+. That's long enough for the global
        // CGEventTap that drives the AI hotkey to hit its handler
        // timeout, causing macOS to drop the subsequent keyUp event and
        // leaving the mic stuck open. Defer positioning to the next run
        // loop tick so the press handler returns fast.
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

        // Register so the primary dictation hotkey routes its transcript
        // into this bubble's input field while the bubble is key, instead
        // of pasting into the user's previous app.
        AIAssistantPasteInterceptor.shared.register(controller: self)

        // Deferred smart-positioning pass: runs off the event tap handler
        // thread so AX latency can't cause the hotkey's keyUp to be dropped.
        DispatchQueue.main.async { [weak self, weak newPanel] in
            guard let self, let newPanel, self.panel === newPanel else { return }
            self.positionNearSelection(newPanel)
        }
    }

    private func positionCenter(_ panel: NSPanel) {
        let panelSize = panel.frame.size
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(
            x: visible.midX - panelSize.width / 2,
            y: visible.midY - panelSize.height / 2
        )
        panel.setFrameOrigin(Self.clampOrigin(origin, size: panelSize, visible: visible))
    }

    func dismiss() {
        guard !isDismissed else { return }
        isDismissed = true
        AIAssistantPasteInterceptor.shared.unregister(controller: self)
        activeTask?.cancel()
        activeTask = nil
        if let observer = resignObserver {
            NotificationCenter.default.removeObserver(observer)
            resignObserver = nil
        }
        unsubscribeFromStreamingPartials()
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

    /// Smart placement: anchor to the AX selection rect (or focused element /
    /// window as fallbacks). Preference order: above → below → right → left
    /// → center. Always clamped to the active screen's visible frame so the
    /// bubble never renders partly off-screen.
    private func positionNearSelection(_ panel: NSPanel) {
        let panelSize = panel.frame.size
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        guard let anchor = AppContextService.frontmostSelectionScreenRect() else {
            // No usable anchor — center on the active screen, no tail.
            let origin = NSPoint(
                x: visible.midX - panelSize.width / 2,
                y: visible.midY - panelSize.height / 2
            )
            panel.setFrameOrigin(Self.clampOrigin(origin, size: panelSize, visible: visible))
            state.tailDirection = .none
            return
        }

        let gap: CGFloat = 12
        let candidates = Self.positioningCandidatesWithTail(
            anchor: anchor,
            panelSize: panelSize,
            visible: visible,
            gap: gap
        )
        // Take the first candidate that fits within the visible frame
        // without needing to be clamped. Falls back to the clamped version
        // of the first candidate if none fit cleanly.
        let picked: (origin: NSPoint, tail: BubbleTailDirection)
        if let hit = candidates.first(where: { Self.fits(origin: $0.origin, size: panelSize, visible: visible) }) {
            picked = hit
        } else {
            picked = (Self.clampOrigin(candidates[0].origin, size: panelSize, visible: visible), candidates[0].tail)
        }
        panel.setFrameOrigin(picked.origin)
        state.tailDirection = picked.tail
        state.tailOffsetFraction = Self.tailOffsetFraction(
            for: picked.tail,
            origin: picked.origin,
            panelSize: panelSize,
            anchor: anchor
        )
    }

    /// Ordered placement candidates in Cocoa screen coords. Above the
    /// anchor first (most readable), then below, then to the right (useful
    /// when the anchor hugs the top edge), then to the left, then centered
    /// over the anchor as last-resort. Each candidate is paired with the
    /// tail direction that should point from the bubble back toward the
    /// selection.
    static func positioningCandidatesWithTail(
        anchor: CGRect,
        panelSize: CGSize,
        visible: CGRect,
        gap: CGFloat
    ) -> [(origin: NSPoint, tail: BubbleTailDirection)] {
        let centerAlignedX = max(
            visible.minX,
            min(anchor.midX - panelSize.width / 2, visible.maxX - panelSize.width)
        )
        let centerAlignedY = max(
            visible.minY,
            min(anchor.midY - panelSize.height / 2, visible.maxY - panelSize.height)
        )

        // Cocoa coord system: Y grows upward. "Above the anchor" means the
        // bubble sits at a HIGHER y than the anchor. For a speech bubble
        // above the selection, the tail points down toward the selection.
        let above = NSPoint(x: centerAlignedX, y: anchor.maxY + gap)
        let below = NSPoint(x: centerAlignedX, y: anchor.minY - panelSize.height - gap)
        let right = NSPoint(x: anchor.maxX + gap, y: centerAlignedY)
        let left = NSPoint(x: anchor.minX - panelSize.width - gap, y: centerAlignedY)
        let centered = NSPoint(x: centerAlignedX, y: centerAlignedY)

        return [
            (above, .down),
            (below, .up),
            (right, .left),
            (left, .right),
            (centered, .none),
        ]
    }

    /// Calculate where along the tail's edge the tip should point,
    /// expressed as a fraction from 0 (left/top) to 1 (right/bottom) of the
    /// panel's edge. The tip should align with the selection center on the
    /// axis parallel to the tail edge.
    static func tailOffsetFraction(
        for tail: BubbleTailDirection,
        origin: NSPoint,
        panelSize: CGSize,
        anchor: CGRect
    ) -> CGFloat {
        switch tail {
        case .down, .up:
            let relative = anchor.midX - origin.x
            // SwiftUI renders in top-left origin space, so horizontal
            // fractions translate 1:1 between Cocoa origin and the view.
            return max(0, min(1, relative / panelSize.width))
        case .left, .right:
            // Cocoa Y grows upward, SwiftUI Y grows downward — flip.
            let relativeFromTop = (origin.y + panelSize.height) - anchor.midY
            return max(0, min(1, relativeFromTop / panelSize.height))
        case .none:
            return 0.5
        }
    }

    static func fits(origin: NSPoint, size: CGSize, visible: CGRect) -> Bool {
        origin.x >= visible.minX
            && origin.y >= visible.minY
            && origin.x + size.width <= visible.maxX
            && origin.y + size.height <= visible.maxY
    }

    static func clampOrigin(_ origin: NSPoint, size: CGSize, visible: CGRect) -> NSPoint {
        NSPoint(
            x: max(visible.minX, min(origin.x, visible.maxX - size.width)),
            y: max(visible.minY, min(origin.y, visible.maxY - size.height))
        )
    }
}
