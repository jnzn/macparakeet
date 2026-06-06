import Foundation

/// How the Voice Return trigger phrase behaves at the end of a dictation.
///
/// - ``send``: nothing happens by default; speaking the trigger phrase at the
///   end presses Return (submits). This is the original Voice Return behavior.
/// - ``hold``: Return is pressed automatically after every dictation
///   (auto-submit); speaking the trigger phrase at the end *suppresses* the
///   submit and leaves the text in place for review.
///
/// `.send` fails safe — forget the phrase and the text simply waits for you to
/// press Return yourself. `.hold` fails toward an *irreversible* auto-submit —
/// forget the phrase and it sends — so `.send` is the default.
public enum VoiceReturnMode: String, CaseIterable, Hashable, Sendable, Equatable {
    case send
    case hold

    public var displayTitle: String {
        switch self {
        case .send: return "Send"
        case .hold: return "Hold for review"
        }
    }

    /// One-line explanation shown under the mode picker.
    public var detail: String {
        switch self {
        case .send:
            return "Say your trigger phrase at the end to press Return. Without it, nothing is sent."
        case .hold:
            return "Every dictation presses Return automatically. Say your trigger phrase at the end to hold it for review instead."
        }
    }

    public static func current(defaults: UserDefaults = .standard) -> VoiceReturnMode {
        guard let raw = defaults.string(forKey: UserDefaultsAppRuntimePreferences.voiceReturnModeKey),
              let mode = VoiceReturnMode(rawValue: raw) else {
            return .send
        }
        return mode
    }
}
