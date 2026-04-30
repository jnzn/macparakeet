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
    /// `SharedMicrophoneStream` instead of each owning an `AVAudioEngine` —
    /// fixes the dictation-during-meeting silence bug that PR #186 documented.
    /// Default flipped to `true` on 2026-04-30 after step-3 + step-5
    /// real-hardware verification; the legacy private-engine paths are kept
    /// in source for one DMG release as a rollback option, then removed in
    /// step 7 of the plan.
    public static let useSharedMicEngine: Bool = true
}
