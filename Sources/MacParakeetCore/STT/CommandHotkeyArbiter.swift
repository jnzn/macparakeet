import Foundation

public enum CommandHotkeyAction: Equatable {
    case none
    case startCommandMode
    case cancelCommandMode
}

public struct CommandHotkeyDecision: Equatable {
    public let action: CommandHotkeyAction
    public let suppressDictation: Bool

    public init(action: CommandHotkeyAction, suppressDictation: Bool) {
        self.action = action
        self.suppressDictation = suppressDictation
    }
}

/// Resolves command chord (`Fn+Control`) precedence over dictation gestures.
/// This is intentionally pure/testable and independent of CGEvent details.
public final class CommandHotkeyArbiter {
    private var chordWasPressed = false
    private var suppressUntilRelease = false

    public init() {}

    public func reset() {
        chordWasPressed = false
        suppressUntilRelease = false
    }

    public func process(
        isFnPressed: Bool,
        isControlPressed: Bool,
        isCommandModeActive: Bool,
        isCommandModeAvailable: Bool
    ) -> CommandHotkeyDecision {
        guard isCommandModeAvailable || isCommandModeActive else {
            // Feature not wired at app level; do not alter dictation behavior.
            chordWasPressed = false
            suppressUntilRelease = false
            return CommandHotkeyDecision(action: .none, suppressDictation: false)
        }

        let chordPressed = isFnPressed && isControlPressed

        if suppressUntilRelease {
            if !isFnPressed && !isControlPressed {
                suppressUntilRelease = false
                chordWasPressed = false
            }
            return CommandHotkeyDecision(action: .none, suppressDictation: true)
        }

        if chordPressed && !chordWasPressed {
            chordWasPressed = true
            suppressUntilRelease = true
            let action: CommandHotkeyAction = isCommandModeActive ? .cancelCommandMode : .startCommandMode
            return CommandHotkeyDecision(action: action, suppressDictation: true)
        }

        chordWasPressed = chordPressed

        if chordPressed || isCommandModeActive {
            return CommandHotkeyDecision(action: .none, suppressDictation: true)
        }

        return CommandHotkeyDecision(action: .none, suppressDictation: false)
    }
}
