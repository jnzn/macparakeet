import Foundation

/// A keystroke action that can be simulated after dictation paste.
public enum KeyAction: String, Codable, Sendable, CaseIterable, Equatable {
    case returnKey = "return"
    case tab = "tab"
    case escape = "escape"

    /// The CGKeyCode for this action.
    public var keyCode: UInt16 {
        switch self {
        case .returnKey: return 0x24
        case .tab:       return 0x30
        case .escape:    return 0x35
        }
    }

    /// Human-readable label for the UI.
    public var label: String {
        switch self {
        case .returnKey: return "⏎ Return"
        case .tab:       return "⇥ Tab"
        case .escape:    return "⎋ Escape"
        }
    }
}
