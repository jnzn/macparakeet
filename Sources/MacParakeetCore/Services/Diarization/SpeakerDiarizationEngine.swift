import Foundation
import OSLog

/// Which model answers "who spoke when". A global preference: it applies to
/// meetings and to file/URL transcription alike.
public enum SpeakerDiarizationEngine: String, CaseIterable, Sendable, Identifiable {
    /// pyannote segmentation + WeSpeaker embeddings + VBx clustering. Produces a
    /// voice vector per speaker, so saved voices can be recognized across
    /// meetings, and honors exact/range speaker counts.
    case standard
    /// NVIDIA Nemotron 3 Diarization (8-speaker streaming Sortformer). Fast and
    /// strong on speaker counting in NVIDIA's benchmark, but it has no voice
    /// vectors and takes no speaker count. Experimental.
    case nemotron3

    public static let `default`: SpeakerDiarizationEngine = .standard

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .standard: return "Standard"
        case .nemotron3: return "NVIDIA Nemotron 3 (experimental)"
        }
    }

    public var summary: String {
        switch self {
        case .standard:
            return "Recognizes saved voices across meetings and honors speaker counts."
        case .nemotron3:
            return "Up to 8 speakers, fast. Can't recognize saved voices or use a speaker count. "
                + "Downloads about 190 MB the first time. Falls back to Standard if it can't load."
        }
    }
}

/// Routes each request to the engine the user picked, read at call time so a
/// change in Settings applies to the next run without a restart.
///
/// The experimental engine is never allowed to break speaker detection: if it
/// fails to load (first use while offline) or to run, the request falls back to
/// the standard engine and the reason is logged. Cancellation is not a failure
/// and propagates.
///
/// Services built with an explicit speaker constraint (CLI `--speaker-*` flags,
/// retranscription with an exact count) are standard-engine instances made by
/// `DiarizationServiceFactory`, so a constraint never meets an engine that
/// can't honor it.
public struct EngineSelectingDiarizationService: DiarizationServiceProtocol {
    private let standard: any DiarizationServiceProtocol
    private let nemotron3: any DiarizationServiceProtocol
    private let selectedEngine: @Sendable () -> SpeakerDiarizationEngine
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "DiarizationEngine")

    public init(
        standard: any DiarizationServiceProtocol,
        nemotron3: any DiarizationServiceProtocol,
        selectedEngine: @escaping @Sendable () -> SpeakerDiarizationEngine
    ) {
        self.standard = standard
        self.nemotron3 = nemotron3
        self.selectedEngine = selectedEngine
    }

    private var active: any DiarizationServiceProtocol {
        selectedEngine() == .nemotron3 ? nemotron3 : standard
    }

    public func diarize(
        audioURL: URL,
        speakerConstraint: SpeakerDiarizationConstraint?
    ) async throws -> MacParakeetDiarizationResult {
        guard selectedEngine() == .nemotron3 else {
            return try await standard.diarize(audioURL: audioURL, speakerConstraint: speakerConstraint)
        }
        do {
            return try await nemotron3.diarize(audioURL: audioURL, speakerConstraint: speakerConstraint)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.error(
                "nemotron3_diarization_fallback error=\(String(describing: error), privacy: .public)")
            try Task.checkCancellation()
            return try await standard.diarize(audioURL: audioURL, speakerConstraint: speakerConstraint)
        }
    }

    public func prepareModels(onProgress: (@Sendable (String) -> Void)?) async throws {
        try await active.prepareModels(onProgress: onProgress)
    }

    public func isReady() async -> Bool {
        await active.isReady()
    }

    public func hasCachedModels() async -> Bool {
        await active.hasCachedModels()
    }

    public func explicitSpeakerConstraint() async -> SpeakerDiarizationConstraint? {
        await standard.explicitSpeakerConstraint()
    }
}
