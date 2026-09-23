import FluidAudio
import XCTest

@testable import MacParakeetCore

final class Nemotron3SegmentBuilderTests: XCTestCase {
    /// Builds a probability grid: `frames[i]` lists (slot, probability) pairs active at frame i.
    private func grid(_ frames: [[(Int, Float)]], numSpeakers: Int = 8) -> [Float] {
        var probabilities = [Float](repeating: 0, count: frames.count * numSpeakers)
        for (frame, active) in frames.enumerated() {
            for (slot, probability) in active { probabilities[frame * numSpeakers + slot] = probability }
        }
        return probabilities
    }

    private func frames(_ count: Int, _ active: [(Int, Float)]) -> [[(Int, Float)]] {
        Array(repeating: active, count: count)
    }

    func testSingleSpeakerTurnBecomesOneSegmentInMilliseconds() {
        let probabilities = grid(frames(10, []) + frames(100, [(2, 0.9)]) + frames(10, []))

        let turns = Nemotron3SegmentBuilder.exclusiveTurns(probabilities: probabilities, frameCount: 120)

        XCTAssertEqual(turns, [Nemotron3Turn(slot: 2, startMs: 100, endMs: 1_100)])
    }

    /// The reason this builder exists: FluidAudio's per-slot thresholding yields
    /// overlapping segments, but the app's contract is exclusive segments.
    func testOverlappingSpeechGoesToTheStrongerSpeaker() {
        let probabilities = grid(
            frames(50, [(0, 0.9)])
                + frames(50, [(0, 0.95), (1, 0.6)])  // both above threshold; slot 0 stronger
                + frames(50, [(1, 0.9)])
        )

        let turns = Nemotron3SegmentBuilder.exclusiveTurns(probabilities: probabilities, frameCount: 150)

        XCTAssertEqual(
            turns,
            [
                Nemotron3Turn(slot: 0, startMs: 0, endMs: 1_000),
                Nemotron3Turn(slot: 1, startMs: 1_000, endMs: 1_500),
            ])
        // Exclusive: no segment starts before the previous one ends.
        for pair in zip(turns, turns.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.0.endMs, pair.1.startMs)
        }
    }

    func testProbabilityAtOrBelowThresholdIsSilence() {
        let probabilities = grid(frames(100, [(0, 0.5)]))  // == threshold, not above it

        XCTAssertTrue(Nemotron3SegmentBuilder.exclusiveTurns(probabilities: probabilities, frameCount: 100).isEmpty)
    }

    func testBlipsShorterThanTheMinimumTurnAreDropped() {
        // 150 ms of speech (below the 200 ms minimum) between silence.
        let probabilities = grid(frames(20, []) + frames(15, [(3, 0.9)]) + frames(20, []))

        XCTAssertTrue(Nemotron3SegmentBuilder.exclusiveTurns(probabilities: probabilities, frameCount: 55).isEmpty)
    }

    func testSameSpeakerTurnsAcrossAShortGapMerge() {
        // 200 ms gap (under the 300 ms merge gap) inside one speaker's turn.
        let probabilities = grid(frames(50, [(1, 0.9)]) + frames(20, []) + frames(50, [(1, 0.9)]))

        let turns = Nemotron3SegmentBuilder.exclusiveTurns(probabilities: probabilities, frameCount: 120)

        XCTAssertEqual(turns, [Nemotron3Turn(slot: 1, startMs: 0, endMs: 1_200)])
    }

    func testSameSpeakerTurnsAcrossALongGapStaySeparate() {
        let probabilities = grid(frames(50, [(1, 0.9)]) + frames(50, []) + frames(50, [(1, 0.9)]))

        let turns = Nemotron3SegmentBuilder.exclusiveTurns(probabilities: probabilities, frameCount: 150)

        XCTAssertEqual(
            turns,
            [
                Nemotron3Turn(slot: 1, startMs: 0, endMs: 500),
                Nemotron3Turn(slot: 1, startMs: 1_000, endMs: 1_500),
            ])
    }

    func testAnInterjectionBetweenTwoTurnsOfOneSpeakerIsNotSwallowed() {
        // A long-enough other speaker between them: they must not merge across it.
        let probabilities = grid(frames(50, [(0, 0.9)]) + frames(30, [(1, 0.9)]) + frames(50, [(0, 0.9)]))

        let turns = Nemotron3SegmentBuilder.exclusiveTurns(probabilities: probabilities, frameCount: 130)

        XCTAssertEqual(turns.map(\.slot), [0, 1, 0])
    }

    func testMalformedInputYieldsNoTurns() {
        XCTAssertTrue(Nemotron3SegmentBuilder.exclusiveTurns(probabilities: [], frameCount: 0).isEmpty)
        // Fewer probabilities than frameCount * numSpeakers claims.
        XCTAssertTrue(Nemotron3SegmentBuilder.exclusiveTurns(probabilities: [0.9, 0.9], frameCount: 10).isEmpty)
    }
}

final class Nemotron3DiarizationServiceTests: XCTestCase {
    private struct FakeInference: Nemotron3Inferring {
        let probabilities: [Float]
        let frameCount: Int
        func infer(samples: [Float]) async throws -> (probabilities: [Float], frameCount: Int) {
            (probabilities, frameCount)
        }
    }

    private actor LoadCounter {
        var loads = 0
        func bump() { loads += 1 }
    }

    /// 1 s of silence, then slot `first` for 1 s, then slot `second` for 1 s.
    private func twoSpeakerGrid(first: Int, second: Int) -> (probabilities: [Float], frameCount: Int) {
        let numSpeakers = 8
        let frames = 300
        var probabilities = [Float](repeating: 0, count: frames * numSpeakers)
        for frame in 100..<200 { probabilities[frame * numSpeakers + first] = 0.9 }
        for frame in 200..<300 { probabilities[frame * numSpeakers + second] = 0.9 }
        return (probabilities, frames)
    }

    private func makeService(
        inference: FakeInference,
        counter: LoadCounter = LoadCounter(),
        samples: [Float] = [0.1, 0.2],
        directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    ) -> Nemotron3DiarizationService {
        Nemotron3DiarizationService(
            loadInference: { _, _ in
                await counter.bump()
                return inference
            },
            loadSamples: { _ in samples },
            modelsDirectory: directory
        )
    }

    func testNamesSpeakersByWhoTalksFirstNotByModelSlot() async throws {
        // The model's slots are 5 then 2; ids must still be S1 then S2.
        let output = twoSpeakerGrid(first: 5, second: 2)
        let service = makeService(inference: FakeInference(probabilities: output.probabilities, frameCount: output.frameCount))

        let result = try await service.diarize(audioURL: URL(fileURLWithPath: "/tmp/x.wav"), speakerConstraint: nil)

        XCTAssertEqual(result.segments.map(\.speakerId), ["S1", "S2"])
        XCTAssertEqual(result.segments.map(\.startMs), [1_000, 2_000])
        XCTAssertEqual(result.speakerCount, 2)
        XCTAssertEqual(result.speakers, [SpeakerInfo(id: "S1", label: "Speaker 1"), SpeakerInfo(id: "S2", label: "Speaker 2")])
        XCTAssertEqual(result.speechMsBySpeaker, ["S1": 1_000, "S2": 1_000])
    }

    /// Activity models have no voice vectors; the shape the voiceprint code
    /// tolerates is "segments and labels, no embeddings".
    func testProducesNoSpeakerEmbeddings() async throws {
        let output = twoSpeakerGrid(first: 0, second: 1)
        let service = makeService(inference: FakeInference(probabilities: output.probabilities, frameCount: output.frameCount))

        let result = try await service.diarize(audioURL: URL(fileURLWithPath: "/tmp/x.wav"), speakerConstraint: nil)

        XCTAssertTrue(result.speakerEmbeddings.isEmpty)
    }

    func testSpeakerCapHintIsIgnored() async throws {
        let output = twoSpeakerGrid(first: 0, second: 1)
        let service = makeService(inference: FakeInference(probabilities: output.probabilities, frameCount: output.frameCount))

        // A cap of 1 would collapse two speakers in the standard engine; this one can't honor it.
        let result = try await service.diarize(
            audioURL: URL(fileURLWithPath: "/tmp/x.wav"), speakerConstraint: .range(min: 1, max: 1))

        XCTAssertEqual(result.speakerCount, 2)
    }

    func testEmptyAudioYieldsAnEmptyResultWithoutRunningTheModel() async throws {
        let service = makeService(inference: FakeInference(probabilities: [], frameCount: 0), samples: [])

        let result = try await service.diarize(audioURL: URL(fileURLWithPath: "/tmp/x.wav"), speakerConstraint: nil)

        XCTAssertTrue(result.segments.isEmpty)
        XCTAssertEqual(result.speakerCount, 0)
    }

    func testSilentAudioYieldsAnEmptyResult() async throws {
        let service = makeService(
            inference: FakeInference(probabilities: [Float](repeating: 0, count: 8 * 100), frameCount: 100))

        let result = try await service.diarize(audioURL: URL(fileURLWithPath: "/tmp/x.wav"), speakerConstraint: nil)

        XCTAssertTrue(result.segments.isEmpty)
        XCTAssertEqual(result.speakerCount, 0)
    }

    func testModelLoadsOnceAcrossRequests() async throws {
        let output = twoSpeakerGrid(first: 0, second: 1)
        let counter = LoadCounter()
        let service = makeService(
            inference: FakeInference(probabilities: output.probabilities, frameCount: output.frameCount),
            counter: counter)

        let readyBefore = await service.isReady()
        XCTAssertFalse(readyBefore)
        _ = try await service.diarize(audioURL: URL(fileURLWithPath: "/tmp/x.wav"), speakerConstraint: nil)
        _ = try await service.diarize(audioURL: URL(fileURLWithPath: "/tmp/x.wav"), speakerConstraint: nil)

        let loads = await counter.loads
        XCTAssertEqual(loads, 1)
        let readyAfter = await service.isReady()
        XCTAssertTrue(readyAfter)
    }

    func testLoadFailureIsThrownAndNotCachedForever() async throws {
        actor Flaky {
            var calls = 0
            func next() throws { calls += 1; if calls == 1 { throw Nemotron3Error.modelLoadFailed("offline") } }
        }
        let flaky = Flaky()
        let output = twoSpeakerGrid(first: 0, second: 1)
        let service = Nemotron3DiarizationService(
            loadInference: { _, _ in
                try await flaky.next()
                return FakeInference(probabilities: output.probabilities, frameCount: output.frameCount)
            },
            loadSamples: { _ in [0.1] },
            modelsDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )

        do {
            _ = try await service.diarize(audioURL: URL(fileURLWithPath: "/tmp/x.wav"), speakerConstraint: nil)
            XCTFail("expected the first load to fail")
        } catch {}

        // A later request retries instead of replaying the failure.
        let result = try await service.diarize(audioURL: URL(fileURLWithPath: "/tmp/x.wav"), speakerConstraint: nil)
        XCTAssertEqual(result.speakerCount, 2)
    }

    // MARK: - Cache

    func testModelIsCachedOnlyWhenBundleAndSilenceAssetArePresent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(Nemotron3DiarizationService.isModelCached(directory: root))

        let repo = Nemotron3DiarizationService.modelCacheDirectory(directory: root)
        let bundle = repo
            .appendingPathComponent(Nemotron3DiarizationService.preset.hubSubdirectory)
            .appendingPathComponent(Nemotron3DiarizationService.preset.modelFileName)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data().write(to: bundle.appendingPathComponent("coremldata.bin"))
        XCTAssertFalse(Nemotron3DiarizationService.isModelCached(directory: root), "bundle alone is not enough")

        try Data().write(to: repo.appendingPathComponent("learnable_sil_emb.bin"))
        XCTAssertTrue(Nemotron3DiarizationService.isModelCached(directory: root))

        Nemotron3DiarizationService.clearModelCache(directory: root)
        XCTAssertFalse(Nemotron3DiarizationService.isModelCached(directory: root))
    }

    /// The experimental engine lives in its own folder, so switching engines
    /// never disturbs the standard engine's models.
    func testCacheDirectoryIsSeparateFromTheStandardEngines() {
        let root = FileManager.default.temporaryDirectory
        XCTAssertNotEqual(
            Nemotron3DiarizationService.modelCacheDirectory(directory: root),
            DiarizationService.modelCacheDirectory(directory: root))
    }
}

final class EngineSelectingDiarizationServiceTests: XCTestCase {
    private func result(_ tag: String) -> MacParakeetDiarizationResult {
        MacParakeetDiarizationResult(
            segments: [SpeakerSegment(speakerId: tag, startMs: 0, endMs: 1_000)],
            speakerCount: 1,
            speakers: [SpeakerInfo(id: tag, label: tag)])
    }

    private final class Selection: @unchecked Sendable {
        var engine: SpeakerDiarizationEngine
        init(_ engine: SpeakerDiarizationEngine) { self.engine = engine }
    }

    private func make(
        _ selection: Selection
    ) async -> (EngineSelectingDiarizationService, standard: MockDiarizationService, nemotron: MockDiarizationService) {
        let standard = MockDiarizationService()
        let nemotron = MockDiarizationService()
        await standard.configure(result: result("standard"))
        await nemotron.configure(result: result("nemotron"))
        let service = EngineSelectingDiarizationService(
            standard: standard, nemotron3: nemotron, selectedEngine: { selection.engine })
        return (service, standard, nemotron)
    }

    private let audio = URL(fileURLWithPath: "/tmp/x.wav")

    func testStandardIsTheDefaultAndNemotronIsUntouched() async throws {
        let (service, _, nemotron) = await make(Selection(.standard))

        let out = try await service.diarize(audioURL: audio, speakerConstraint: nil)

        XCTAssertEqual(out.segments.first?.speakerId, "standard")
        let called = await nemotron.diarizeCalled
        XCTAssertFalse(called)
    }

    func testSelectingNemotronRoutesToIt() async throws {
        let (service, standard, _) = await make(Selection(.nemotron3))

        let out = try await service.diarize(audioURL: audio, speakerConstraint: nil)

        XCTAssertEqual(out.segments.first?.speakerId, "nemotron")
        let called = await standard.diarizeCalled
        XCTAssertFalse(called)
    }

    func testTheChoiceIsReadPerCallSoSettingsApplyWithoutARestart() async throws {
        let selection = Selection(.standard)
        let (service, _, _) = await make(selection)

        let first = try await service.diarize(audioURL: audio, speakerConstraint: nil)
        selection.engine = .nemotron3
        let second = try await service.diarize(audioURL: audio, speakerConstraint: nil)

        XCTAssertEqual(first.segments.first?.speakerId, "standard")
        XCTAssertEqual(second.segments.first?.speakerId, "nemotron")
    }

    /// Speaker detection must not break because the experimental engine can't
    /// load (for example first use while offline).
    func testNemotronFailureFallsBackToStandard() async throws {
        let (service, standard, nemotron) = await make(Selection(.nemotron3))
        await nemotron.configure(error: Nemotron3Error.modelLoadFailed("offline"))

        let out = try await service.diarize(audioURL: audio, speakerConstraint: nil)

        XCTAssertEqual(out.segments.first?.speakerId, "standard")
        let standardCalled = await standard.diarizeCalled
        XCTAssertTrue(standardCalled)
    }

    func testCancellationIsNotTreatedAsAFailureToFallBackFrom() async throws {
        let (service, standard, nemotron) = await make(Selection(.nemotron3))
        await nemotron.configure(error: CancellationError())

        do {
            _ = try await service.diarize(audioURL: audio, speakerConstraint: nil)
            XCTFail("expected cancellation to propagate")
        } catch is CancellationError {
        }
        let standardCalled = await standard.diarizeCalled
        XCTAssertFalse(standardCalled)
    }

    /// There is no fallback *from* the standard engine: its errors surface as before.
    func testStandardFailuresAreNotHidden() async throws {
        let standard = MockDiarizationService()
        await standard.configure(error: StandardEngineStubError.boom)
        let service = EngineSelectingDiarizationService(
            standard: standard, nemotron3: MockDiarizationService(), selectedEngine: { .standard })

        do {
            _ = try await service.diarize(audioURL: audio, speakerConstraint: nil)
            XCTFail("expected the standard engine's error")
        } catch is StandardEngineStubError {}
    }

    func testReadinessAndCacheFollowTheSelectedEngine() async {
        let selection = Selection(.standard)
        let (service, standard, nemotron) = await make(selection)
        await standard.configureReady(true)
        await standard.configureCachedModels(true)
        await nemotron.configureReady(false)
        await nemotron.configureCachedModels(false)

        var ready = await service.isReady()
        var cached = await service.hasCachedModels()
        XCTAssertTrue(ready)
        XCTAssertTrue(cached)

        selection.engine = .nemotron3
        ready = await service.isReady()
        cached = await service.hasCachedModels()
        XCTAssertFalse(ready)
        XCTAssertFalse(cached)
    }

    func testPrepareModelsPreparesTheSelectedEngineOnly() async throws {
        let (service, standard, nemotron) = await make(Selection(.nemotron3))

        try await service.prepareModels(onProgress: nil)

        let nemotronPrepared = await nemotron.prepareModelsCalled
        let standardPrepared = await standard.prepareModelsCalled
        XCTAssertTrue(nemotronPrepared)
        XCTAssertFalse(standardPrepared)
    }

    func testExplicitConstraintComesFromTheStandardEngine() async {
        let (service, standard, _) = await make(Selection(.nemotron3))
        await standard.configureExplicitConstraint(.exact(3))

        let constraint = await service.explicitSpeakerConstraint()

        XCTAssertEqual(constraint, .exact(3))
    }

    // MARK: - Preference

    func testEnginePreferenceDefaultsToStandardAndRoundTrips() throws {
        let suite = "diar-engine-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(UserDefaultsAppRuntimePreferences.speakerDiarizationEngine(defaults: defaults), .standard)

        defaults.set(SpeakerDiarizationEngine.nemotron3.rawValue, forKey: UserDefaultsAppRuntimePreferences.speakerDiarizationEngineKey)
        XCTAssertEqual(UserDefaultsAppRuntimePreferences.speakerDiarizationEngine(defaults: defaults), .nemotron3)

        // An unknown value (a future engine, a corrupted default) must not crash or select the experiment.
        defaults.set("someFutureEngine", forKey: UserDefaultsAppRuntimePreferences.speakerDiarizationEngineKey)
        XCTAssertEqual(UserDefaultsAppRuntimePreferences.speakerDiarizationEngine(defaults: defaults), .standard)
    }
}

private enum StandardEngineStubError: Error { case boom }
