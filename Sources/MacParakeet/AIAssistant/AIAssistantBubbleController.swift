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
    private static let unfocusedAutoDismissDelay: Duration = .seconds(20)

    private let selection: String
    private let service: AIAssistantServiceProtocol
    private let configStore: AIAssistantConfigStore
    private let selectionReplacer: SelectionReplacer
    private let selectionAnchorRect: CGRect?
    /// PID of the app that was frontmost when the user pressed the hotkey
    /// — captured at session start so "Replace selection" can activate the
    /// right window even if the user has since clicked to other apps.
    /// Nil when the bubble was spawned outside a normal press flow (error
    /// bubbles) — in that case the replace UI is suppressed.
    private let sourceAppPID: pid_t?
    private let onDismissed: () -> Void

    private let state = AIAssistantBubbleState()
    private var panel: AIAssistantBubblePanel?
    private var hostingView: NSHostingView<AIAssistantBubbleView>?
    private var resignObserver: NSObjectProtocol?
    private var becomeObserver: NSObjectProtocol?
    private var partialObserver: NSObjectProtocol?
    private var activeTask: Task<Void, Never>?
    private var unfocusedAutoDismissTask: Task<Void, Never>?
    private var isDismissed = false
    /// True after the first auto-replace has fired. Prevents subsequent
    /// responses from auto-replacing — only the initial "Claude, rewrite
    /// my selection" turn gets auto-replaced.
    private var hasAutoReplaced: Bool = false

    init(
        selection: String,
        service: AIAssistantServiceProtocol,
        configStore: AIAssistantConfigStore,
        selectionReplacer: SelectionReplacer,
        selectionAnchorRect: CGRect?,
        sourceAppPID: pid_t?,
        onDismissed: @escaping () -> Void
    ) {
        self.selection = selection
        self.service = service
        self.configStore = configStore
        self.selectionReplacer = selectionReplacer
        self.selectionAnchorRect = selectionAnchorRect
        self.sourceAppPID = sourceAppPID
        self.onDismissed = onDismissed
        self.state.canReplaceSelection = (sourceAppPID != nil)

        // Seed provider-switcher state from the current config so the
        // bubble opens with the user's default active. Enabled set
        // honors the Settings toggle (falls back to "all providers" when
        // unset).
        let loaded = configStore.load() ?? AIAssistantConfig.defaultClaude
        self.state.enabledProviders = loaded.effectiveEnabledProviders
        self.state.activeProvider = loaded.provider
    }

    /// Convenience: open a bubble in error state without a usable selection.
    /// Used when AX selection grab failed and we still want to surface
    /// visible feedback to the user (instead of an inaudible beep).
    func showError(_ message: String) {
        state.errorMessage = message
        show()
        refreshUnfocusedAutoDismissTimer()
    }

    /// Open the bubble in "Listening…" state. Called immediately on hotkey
    /// press (while the user is speaking) so they get visual feedback that
    /// voice capture is in progress.
    func showListening() {
        state.isListening = true
        state.listeningPartialText = ""
        state.errorMessage = nil
        show()
        refreshUnfocusedAutoDismissTimer()
    }

    /// Called after voice capture completes. Transitions out of the
    /// listening state and submits the dictated transcript as the first
    /// (or next) question to the CLI. Empty transcripts clear the listening
    /// state but don't submit — matches the "no voice, no action" rule.
    /// Partial observer stays subscribed so follow-up primary dictation
    /// can feed the live preview.
    func submitVoiceTranscript(_ transcript: String) {
        state.isListening = false
        state.listeningPartialText = ""
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            refreshUnfocusedAutoDismissTimer()
            return
        }
        submit(question: trimmed)
    }

    /// Called when voice capture is cancelled or errors out without a
    /// transcript. Clears the listening state so the bubble doesn't hang.
    /// Partial observer stays alive — it routes future partials to the
    /// dictation live preview when the user does a follow-up via the
    /// primary hotkey.
    func clearListening() {
        state.isListening = false
        state.listeningPartialText = ""
        refreshUnfocusedAutoDismissTimer()
    }

    /// Subscribe to `.macParakeetStreamingPartial` notifications so the
    /// user sees live ASR text as they speak. Routes partials to:
    ///   - `listeningPartialText` while the AI hotkey is actively
    ///     listening (under the "Listening…" label)
    ///   - `dictationLivePreview` when the bubble is key and the user is
    ///     using the primary dictation hotkey for a follow-up
    /// Only flows when "Live transcript overlay" is enabled in Settings —
    /// otherwise no partials fire and both previews stay empty.
    private func subscribeToStreamingPartials() {
        guard partialObserver == nil else { return }
        partialObserver = NotificationCenter.default.addObserver(
            forName: .macParakeetStreamingPartial,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let text = note.userInfo?["text"] as? String else { return }
            Task { @MainActor in
                guard let self else { return }
                if self.state.isListening {
                    self.state.listeningPartialText = text
                } else if self.isKey {
                    self.state.dictationLivePreview = text
                }
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

    private var shouldAutoDismissWhenUnfocused: Bool {
        !state.isListening && !state.isThinking
    }

    /// Append a dictated transcript into the bubble's text input. Called by
    /// `AIAssistantPasteInterceptor` when primary dictation fires while this
    /// bubble is key. Auto-submits iff `submitAfter` is true — set when the
    /// dictation ended with the user's Voice Return trigger (e.g. "press
    /// return", "go") so speaking a submit cue acts like hitting Enter.
    func appendDictationFollowUp(_ text: String, submitAfter: Bool = false) {
        // Clear the live preview; the final (TDT) transcript replaces it.
        state.dictationLivePreview = ""
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

    /// Switch the active provider for the rest of this bubble session AND
    /// persist it as the new default so future bubbles start on the same
    /// provider. Preserves per-provider command template + model
    /// overrides by stashing the currently-default provider's values into
    /// the overrides dict before promoting the new one.
    private func selectProvider(_ provider: AIAssistantConfig.Provider) {
        guard provider != state.activeProvider else { return }
        state.activeProvider = provider

        // If the user never explicitly saved an AI Assistant config (skipped
        // the onboarding step), `load()` returns nil and the service falls
        // back to `defaultClaude` at runtime. Build the same fallback here
        // so the provider switch still persists — otherwise the next bubble
        // open re-reads the empty store, falls back to Claude again, and
        // every provider switch is forgotten between bubble sessions.
        let current = configStore.load() ?? AIAssistantConfig.defaultClaude
        guard provider != current.provider else {
            // Switching back to the persisted default — no store rewrite.
            return
        }

        var templates = current.providerCommandTemplates ?? [:]
        var models = current.providerModelNames ?? [:]
        templates[current.provider.rawValue] = current.commandTemplate
        models[current.provider.rawValue] = current.modelName
        let newTemplate = templates[provider.rawValue] ?? provider.defaultCommandTemplate
        let newModel = models[provider.rawValue] ?? provider.defaultModel
        templates.removeValue(forKey: provider.rawValue)
        models.removeValue(forKey: provider.rawValue)

        let updated = AIAssistantConfig(
            provider: provider,
            commandTemplate: newTemplate,
            modelName: newModel,
            timeoutSeconds: current.timeoutSeconds,
            hotkeyTrigger: current.hotkeyTrigger,
            bubbleBackgroundColor: current.bubbleBackgroundColor,
            autoReplaceSelection: current.autoReplaceSelection,
            enabledProviders: current.enabledProviders,
            providerCommandTemplates: templates.isEmpty ? nil : templates,
            providerModelNames: models.isEmpty ? nil : models
        )
        try? configStore.save(updated)
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
            },
            onReplaceSelection: { [weak self] turnIndex in
                self?.replaceSelection(with: turnIndex)
            },
            onSelectProvider: { [weak self] provider in
                self?.selectProvider(provider)
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
        // Keep only the bubble view's own SwiftUI shadow. The panel-level
        // shadow draws around the transparent window bounds and reads as a
        // dark border/ring around the glass bubble.
        newPanel.hasShadow = false
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
                self?.refreshUnfocusedAutoDismissTimer()
            }
        }
        becomeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: newPanel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.cancelUnfocusedAutoDismissTimer()
            }
        }

        // Fade in: keep the panel transparent until orderFront, then animate
        // alphaValue 0 -> 1 so the bubble eases in instead of snapping into
        // place. ~180ms feels responsive without feeling sluggish.
        newPanel.alphaValue = 0
        newPanel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            newPanel.animator().alphaValue = 1
        }
        self.panel = newPanel

        // Register so the primary dictation hotkey routes its transcript
        // into this bubble's input field while the bubble is key, instead
        // of pasting into the user's previous app.
        AIAssistantPasteInterceptor.shared.register(controller: self)

        // Subscribe once for the bubble's entire lifetime. The callback
        // routes partials to whichever preview is active: the AI-hotkey
        // "Listening…" block while isListening, or the primary-dictation
        // live preview otherwise. Avoids a re-subscribe race when the
        // bubble transitions from AI-hotkey listening to the response
        // display while the user's still holding the hotkey.
        subscribeToStreamingPartials()

        // Deferred smart-positioning pass so the panel exists before we move
        // it. Position from the source-app anchor captured before the bubble
        // opened instead of issuing another live AX query after focus shifts.
        DispatchQueue.main.async { [weak self, weak newPanel] in
            guard let self, let newPanel, self.panel === newPanel else { return }
            self.positionNearSelection(newPanel, anchor: self.selectionAnchorRect)
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
        cancelUnfocusedAutoDismissTimer()
        activeTask?.cancel()
        activeTask = nil
        if let observer = resignObserver {
            NotificationCenter.default.removeObserver(observer)
            resignObserver = nil
        }
        if let observer = becomeObserver {
            NotificationCenter.default.removeObserver(observer)
            becomeObserver = nil
        }
        unsubscribeFromStreamingPartials()

        // Fade out: animate alphaValue 1 -> 0, then orderOut. ~150ms eases
        // the disappearance without feeling laggy. Keep a strong reference
        // to the panel inside the completion handler so it survives the
        // ARC-released `self.panel = nil` below.
        if let panelRef = panel {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panelRef.animator().alphaValue = 0
            }, completionHandler: {
                panelRef.orderOut(nil)
                panelRef.alphaValue = 1  // reset for any future show
            })
        }
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
        let activeProvider = state.activeProvider
        let request = AIAssistantRequest(
            selection: selection,
            question: trimmed,
            history: history,
            providerOverride: activeProvider
        )
        // Check auto-replace intent before awaiting the LLM. Captured here
        // so a mid-flight config edit in Settings doesn't change behavior
        // for this turn — and so we only auto-replace the VERY FIRST turn
        // of a session, not every follow-up.
        let shouldAutoReplace = !hasAutoReplaced
            && sourceAppPID != nil
            && (configStore.load()?.effectiveAutoReplaceSelection ?? false)

        activeTask?.cancel()
        activeTask = Task { [service, weak self] in
            do {
                let response = try await service.ask(request)
                await MainActor.run {
                    guard let self else { return }
                    self.state.history.append(AIAssistantTurn(question: trimmed, response: response))
                    self.state.isThinking = false
                    self.refreshUnfocusedAutoDismissTimer()
                    if shouldAutoReplace {
                        self.hasAutoReplaced = true
                        self.replaceSelection(with: self.state.history.count - 1)
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    self?.state.isThinking = false
                    self?.refreshUnfocusedAutoDismissTimer()
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.state.errorMessage = error.localizedDescription
                    self.state.isThinking = false
                    self.refreshUnfocusedAutoDismissTimer()
                }
            }
        }
    }

    private func refreshUnfocusedAutoDismissTimer() {
        guard let panel else { return }
        guard !panel.isKeyWindow else {
            cancelUnfocusedAutoDismissTimer()
            return
        }
        guard shouldAutoDismissWhenUnfocused else {
            cancelUnfocusedAutoDismissTimer()
            return
        }
        startUnfocusedAutoDismissTimer()
    }

    private func startUnfocusedAutoDismissTimer() {
        cancelUnfocusedAutoDismissTimer()
        unfocusedAutoDismissTask = Task { [weak self] in
            try? await Task.sleep(for: Self.unfocusedAutoDismissDelay)
            await MainActor.run {
                guard let self, let panel = self.panel else { return }
                guard !panel.isKeyWindow, self.shouldAutoDismissWhenUnfocused else { return }
                self.dismiss()
            }
        }
    }

    private func cancelUnfocusedAutoDismissTimer() {
        unfocusedAutoDismissTask?.cancel()
        unfocusedAutoDismissTask = nil
    }

    /// Kick off the paste-to-source-app flow for the turn at `turnIndex`.
    /// Dismisses the bubble first so its key-window doesn't swallow Cmd+V,
    /// then activates the source app and pastes. Any failure is logged
    /// silently — if the source app isn't reachable the user can copy the
    /// response by hand (textSelection is enabled).
    private func replaceSelection(with turnIndex: Int) {
        guard let pid = sourceAppPID else { return }
        guard state.history.indices.contains(turnIndex) else { return }
        let responseText = state.history[turnIndex].response
        let replacer = selectionReplacer

        dismiss()

        Task { [replacer] in
            do {
                try await replacer.replaceSelection(in: pid, with: responseText)
            } catch {
                // Silent failure — bubble is already dismissed, so there's
                // no good surface to show the error beyond an NSAlert
                // (which we don't want for a non-critical path). The
                // unified log captures the failure via SelectionReplacer.
            }
        }
    }

    /// Smart placement: anchor to the AX selection rect (or focused element /
    /// window as fallbacks). Preference order: above → below → right → left
    /// → center. Always clamped to the active screen's visible frame so the
    /// bubble never renders partly off-screen.
    private func positionNearSelection(_ panel: NSPanel, anchor: CGRect?) {
        let panelSize = panel.frame.size
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        guard let anchor else {
            // No usable anchor — center on the active screen, no tail.
            let origin = NSPoint(
                x: visible.midX - panelSize.width / 2,
                y: visible.midY - panelSize.height / 2
            )
            panel.setFrameOrigin(Self.clampOrigin(origin, size: panelSize, visible: visible))
            state.tailDirection = .none
            return
        }

        // Gap between the bubble's tail tip and the selection's nearest
        // edge. 28pt reads as "comfortably above" for arrow-above-line
        // style tails without the bubble hovering over adjacent text.
        let gap: CGFloat = 28
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

        // Bracket connector retired — SpeechBubbleShape now integrates
        // the tail into the bubble body as one continuous cartoon shape.
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
