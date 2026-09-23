import FluidAudio
import Foundation
import OSLog

// NVIDIA Nemotron 3 Diarization: an 8-speaker streaming Sortformer that reports
// per-frame speaker activity. It is an opt-in alternative to the standard
// (pyannote segmentation + WeSpeaker embeddings + VBx) offline pipeline.
//
// What it does not do, and why the standard engine stays the default:
// - No speaker embeddings. Voiceprint recognition across meetings needs a
//   per-speaker vector, which an activity model doesn't produce, so speakers
//   from this engine keep their segments and labels but can't be matched or
//   enrolled (`MacParakeetDiarizationResult.speakerEmbeddings` is empty, a shape
//   the voiceprint code already tolerates).
// - No speaker-count constraints. Runs that carry an explicit exact/range
//   constraint are built on the standard service and never reach this one, and
//   the soft attendee cap hint is ignored here.

/// One speaker turn on Nemotron's activity grid: `slot` is the model's speaker
/// slot (0...7), not a stable id.
struct Nemotron3Turn: Equatable, Sendable {
    let slot: Int
    let startMs: Int
    let endMs: Int
}

/// Turns Nemotron's per-frame probabilities into exclusive speaker turns.
///
/// FluidAudio's own `Nemotron3Diarizer.segments` thresholds each slot
/// independently, so two speakers talking over each other yield overlapping
/// segments. The app's diarization contract is exclusive segments ("Offline
/// segments are exclusive, so these are plain sums"), and speech-time totals,
/// word attribution and the voiceprint duration gates all lean on that. So each
/// frame goes to its strongest speaker instead.
enum Nemotron3SegmentBuilder {
    /// Model output resolution.
    static let frameMs = 10
    /// A slot counts as speaking above this probability (FluidAudio's default).
    static let activityThreshold: Float = 0.5
    /// Turns shorter than this are blips, not speech (FluidAudio's default).
    static let minTurnMs = 200
    /// Same-speaker turns closer than this merge into one.
    static let mergeGapMs = 300

    static func exclusiveTurns(
        probabilities: [Float],
        frameCount: Int,
        numSpeakers: Int = 8
    ) -> [Nemotron3Turn] {
        guard frameCount > 0, numSpeakers > 0, probabilities.count >= frameCount * numSpeakers else {
            return []
        }

        // 1. Strongest speaker per frame, or none below the threshold; run-length encode.
        var runs: [(slot: Int, start: Int, end: Int)] = []
        var currentSlot = -1
        var runStart = 0
        for frame in 0...frameCount {
            var slot = -1
            if frame < frameCount {
                var best = activityThreshold
                let base = frame * numSpeakers
                for candidate in 0..<numSpeakers where probabilities[base + candidate] > best {
                    best = probabilities[base + candidate]
                    slot = candidate
                }
            }
            if slot != currentSlot {
                if currentSlot >= 0 { runs.append((currentSlot, runStart, frame)) }
                currentSlot = slot
                runStart = frame
            }
        }

        // 2. Drop blips.
        let minFrames = Int((Double(minTurnMs) / Double(frameMs)).rounded(.up))
        let kept = runs.filter { $0.end - $0.start >= minFrames }

        // 3. Merge a speaker's turns that a short gap (or a dropped blip) split.
        let maxGapFrames = mergeGapMs / frameMs
        var merged: [(slot: Int, start: Int, end: Int)] = []
        for run in kept {
            if let last = merged.last, last.slot == run.slot, run.start - last.end <= maxGapFrames {
                merged[merged.count - 1].end = run.end
            } else {
                merged.append(run)
            }
        }

        return merged.map { Nemotron3Turn(slot: $0.slot, startMs: $0.start * frameMs, endMs: $0.end * frameMs) }
    }
}

/// Runs the model over a whole 16 kHz mono buffer.
protocol Nemotron3Inferring: Sendable {
    func infer(samples: [Float]) async throws -> (probabilities: [Float], frameCount: Int)
}

/// The loaded CoreML model. `Nemotron3Models` reuses output buffers between
/// predictions, so every request is funneled through one serial queue: the
/// buffers are never shared between two in-flight requests, and the blocking
/// inference stays off the cooperative thread pool.
private final class LiveNemotron3Inference: Nemotron3Inferring, @unchecked Sendable {
    private let models: Nemotron3Models
    private let config: Nemotron3Config
    private let queue = DispatchQueue(label: "com.macparakeet.nemotron3-diarization", qos: .userInitiated)

    init(models: Nemotron3Models, config: Nemotron3Config) {
        self.models = models
        self.config = config
    }

    func infer(samples: [Float]) async throws -> (probabilities: [Float], frameCount: Int) {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [models, config] in
                do {
                    // Fresh streaming state per request; the loaded model is shared.
                    let diarizer = Nemotron3Diarizer(config: config, models: models)
                    continuation.resume(returning: try diarizer.processComplete(samples))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

public actor Nemotron3DiarizationService: DiarizationServiceProtocol {
    typealias InferenceLoader = @Sendable (URL, (@Sendable (String) -> Void)?) async throws -> any Nemotron3Inferring
    typealias SampleLoader = @Sendable (URL) throws -> [Float]

    /// The preset Nemotron's card names the accuracy pick for batch use: the
    /// best DER and speaker counting of the published set (9.36 DER, 16/16
    /// meetings counted, ~546x real time on M5 Pro), at ~190 MB. Diarization
    /// here always runs after the fact, so its 10.5 s latency doesn't matter.
    /// `fast32` is the card's low-latency default; nothing here is live.
    nonisolated static let preset = Nemotron3Config.fast128

    private let logger = Logger(subsystem: "com.macparakeet.core", category: "Nemotron3Diarization")
    private let loadInference: InferenceLoader
    private let loadSamples: SampleLoader
    private let modelsDirectory: URL
    private let inferenceGate: ANEInferenceGate
    private var inference: (any Nemotron3Inferring)?
    private var preparation: Task<any Nemotron3Inferring, Error>?

    public init(modelsDirectory: URL? = nil) {
        self.init(
            loadInference: Self.liveInferenceLoader,
            loadSamples: { try AudioConverter().resampleAudioFile($0) },
            modelsDirectory: modelsDirectory ?? AppPaths.fluidAudioModelsDirURL
        )
    }

    init(
        loadInference: @escaping InferenceLoader,
        loadSamples: @escaping SampleLoader,
        modelsDirectory: URL,
        inferenceGate: ANEInferenceGate = .shared
    ) {
        self.loadInference = loadInference
        self.loadSamples = loadSamples
        self.modelsDirectory = modelsDirectory.standardizedFileURL
        self.inferenceGate = inferenceGate
    }

    // MARK: - DiarizationServiceProtocol

    public func diarize(
        audioURL: URL,
        speakerConstraint: SpeakerDiarizationConstraint?
    ) async throws -> MacParakeetDiarizationResult {
        // A soft cap hint (attendee count) can't steer an activity model, and an
        // explicit constraint never routes here; see the file header.
        let inference = try await ensureLoaded(onProgress: nil)
        try Task.checkCancellation()

        let samples = try loadSamples(audioURL)
        guard !samples.isEmpty else {
            return MacParakeetDiarizationResult(segments: [], speakerCount: 0, speakers: [])
        }

        // macOS 14 only: serialize Neural Engine inference against the STT
        // scheduler. See `ANEInferenceGate`.
        let output = try await inferenceGate.withExclusiveAccess {
            try await inference.infer(samples: samples)
        }
        try Task.checkCancellation()

        let turns = Nemotron3SegmentBuilder.exclusiveTurns(
            probabilities: output.probabilities,
            frameCount: output.frameCount
        )
        return Self.result(from: turns)
    }

    public func prepareModels(onProgress: (@Sendable (String) -> Void)? = nil) async throws {
        onProgress?("Downloading Nemotron 3 speaker model...")
        _ = try await ensureLoaded(onProgress: onProgress)
        onProgress?("Nemotron 3 speaker model ready")
    }

    public func isReady() async -> Bool {
        inference != nil
    }

    public func hasCachedModels() async -> Bool {
        Self.isModelCached(directory: modelsDirectory)
    }

    // MARK: - Result mapping

    /// Names speakers by who talks first ("S1", "S2", ...), the same convention as
    /// the standard engine, so consumers see one id scheme.
    static func result(from turns: [Nemotron3Turn]) -> MacParakeetDiarizationResult {
        var idBySlot: [Int: String] = [:]
        var segments: [SpeakerSegment] = []
        for turn in turns.sorted(by: { $0.startMs < $1.startMs }) {
            let id = idBySlot[turn.slot] ?? {
                let next = "S\(idBySlot.count + 1)"
                idBySlot[turn.slot] = next
                return next
            }()
            segments.append(SpeakerSegment(speakerId: id, startMs: turn.startMs, endMs: turn.endMs))
        }

        let speakers = idBySlot.values
            .sorted { (Int($0.dropFirst()) ?? 0) < (Int($1.dropFirst()) ?? 0) }
            .map { SpeakerInfo(id: $0, label: "Speaker \($0.dropFirst())") }

        var speechMsBySpeaker: [String: Int] = [:]
        for segment in segments {
            speechMsBySpeaker[segment.speakerId, default: 0] += max(0, segment.endMs - segment.startMs)
        }

        return MacParakeetDiarizationResult(
            segments: segments,
            speakerCount: speakers.count,
            speakers: speakers,
            speakerEmbeddings: [:],
            speechMsBySpeaker: speechMsBySpeaker
        )
    }

    // MARK: - Model loading and cache

    private func ensureLoaded(onProgress: (@Sendable (String) -> Void)?) async throws -> any Nemotron3Inferring {
        try Task.checkCancellation()
        if let inference { return inference }

        let task: Task<any Nemotron3Inferring, Error>
        if let preparation {
            task = preparation
        } else {
            let directory = modelsDirectory
            let loader = loadInference
            task = Task { try await loader(directory, onProgress) }
            preparation = task
        }
        // Completion owns cleanup so a failed load isn't cached forever.
        defer { preparation = nil }
        let loaded = try await task.value
        inference = loaded
        return loaded
    }

    private nonisolated static let liveInferenceLoader: InferenceLoader = { directory, onProgress in
        let models = try await Nemotron3Models.loadFromHuggingFace(
            config: preset,
            cacheDirectory: directory,
            computeUnits: .all,
            progressHandler: onProgress.map { report in
                { progress in
                    report("Downloading Nemotron 3 speaker model... \(Int(progress.fractionCompleted * 100))%")
                }
            }
        )
        return LiveNemotron3Inference(models: models, config: preset)
    }

    public nonisolated static func isModelCached(directory: URL? = nil) -> Bool {
        let repoDirectory = modelCacheDirectory(directory: directory)
        let bundle = repoDirectory
            .appendingPathComponent(preset.hubSubdirectory, isDirectory: true)
            .appendingPathComponent(preset.modelFileName, isDirectory: true)
            .appendingPathComponent("coremldata.bin", isDirectory: false)
        let assets = repoDirectory.appendingPathComponent(ModelNames.Nemotron3.silenceEmbeddingFile, isDirectory: false)
        return FileManager.default.fileExists(atPath: bundle.path)
            && FileManager.default.fileExists(atPath: assets.path)
    }

    public nonisolated static func clearModelCache(directory: URL? = nil) {
        try? FileManager.default.removeItem(at: modelCacheDirectory(directory: directory))
    }

    nonisolated static func modelCacheDirectory(directory: URL? = nil) -> URL {
        let baseDirectory = (directory ?? AppPaths.fluidAudioModelsDirURL).standardizedFileURL
        return baseDirectory.appendingPathComponent(Repo.nemotron3Diarization.folderName, isDirectory: true)
    }
}
