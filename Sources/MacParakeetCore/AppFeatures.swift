import Foundation

/// Compile-time feature gates. Flip a single literal to expose or hide a feature
/// without touching every call site. Release builds should set these to the
/// shipping configuration before tagging a version.
public enum AppFeatures {
    /// Meeting Recording (ADR-014). When `false`, all meeting recording entry
    /// points are hidden: sidebar item, menu-bar "Record Meeting", global meeting
    /// hotkey, settings card, library filter, onboarding step, and the screen
    /// recording permission row. Data model, services, and tests remain intact.
    public static let meetingRecordingEnabled: Bool = true

    /// Shared microphone engine (plans/active/shared-mic-engine.md). When
    /// `true`, dictation and meeting-mic capture both subscribe to a single
    /// `SharedMicrophoneStream` instead of each owning an `AVAudioEngine`.
    /// Default `false` until the consumer migration completes; the stream
    /// type itself ships behind this flag so the state machine and tests are
    /// exercised independently of wiring.
    public static let useSharedMicEngine: Bool = false
}
