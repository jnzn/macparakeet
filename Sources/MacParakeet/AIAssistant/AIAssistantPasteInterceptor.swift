import AppKit
import Foundation
import MacParakeetCore

/// Routes primary-dictation transcripts to the AI Assistant bubble when it's
/// the key window, instead of letting `DictationFlowCoordinator` paste into
/// the user's previous app. Singleton by design — only one bubble can be key
/// at a time, and the flow coordinator doesn't need to know about assistant
/// internals.
///
/// Contract:
///   - `AIAssistantBubbleController.show()` registers itself via `register`
///   - `AIAssistantBubbleController.dismiss()` clears via `unregister`
///   - `DictationFlowCoordinator` calls `tryConsume` before its normal paste;
///     a `true` return means "the bubble ate the transcript, skip the paste"
@MainActor
final class AIAssistantPasteInterceptor {
    static let shared = AIAssistantPasteInterceptor()

    private weak var activeBubble: AIAssistantBubbleController?

    private init() {}

    func register(controller: AIAssistantBubbleController) {
        activeBubble = controller
    }

    func unregister(controller: AIAssistantBubbleController) {
        if activeBubble === controller {
            activeBubble = nil
        }
    }

    /// Called from the primary dictation paste path. Returns `true` iff the
    /// transcript was consumed by an AI bubble that's currently key
    /// (user-focused). Returns `false` for all other cases — the flow
    /// coordinator should paste normally then.
    ///
    /// `postPasteAction` carries the Voice Return signal from the
    /// deterministic pipeline — when the user ended their dictation with
    /// the configured return trigger (default "press return", user's is
    /// "go"), we auto-submit the bubble instead of just parking the text
    /// in the input field.
    func tryConsume(transcript: String, postPasteAction: KeyAction?) -> Bool {
        guard let bubble = activeBubble, bubble.isKey else { return false }
        let shouldSubmit = (postPasteAction == .returnKey)
        bubble.appendDictationFollowUp(transcript, submitAfter: shouldSubmit)
        return true
    }
}
