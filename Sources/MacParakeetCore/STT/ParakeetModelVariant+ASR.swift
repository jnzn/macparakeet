import FluidAudio

/// Bridges the Foundation-only ``ParakeetModelVariant`` preference to the
/// FluidAudio `AsrModelVersion` the runtime actually loads. Kept in the STT
/// layer so `SpeechEnginePreference.swift` never has to import CoreML/FluidAudio.
extension ParakeetModelVariant {
    public var asrModelVersion: AsrModelVersion {
        switch self {
        case .v3: .v3
        case .v2: .v2
        }
    }

    /// Maps a loaded FluidAudio version back to the user-facing variant.
    /// Any non-`v2` version collapses to `.v3` — MacParakeet only exposes the
    /// v2/v3 pair, so the specialized CJK builds (if ever loaded) read as the
    /// multilingual default rather than crashing an exhaustive switch.
    public init(asrModelVersion: AsrModelVersion) {
        switch asrModelVersion {
        case .v2: self = .v2
        default: self = .v3
        }
    }
}
