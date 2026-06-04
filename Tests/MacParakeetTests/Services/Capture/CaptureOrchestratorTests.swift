import AVFAudio
import XCTest
@testable import MacParakeetCore

final class CaptureOrchestratorTests: XCTestCase {
    // The pair joiner emits paired (mic+system) drains when both queues stay
    // below its 1-second lag threshold (16 000 samples at 16 kHz). 8 k per
    // cycle gives a clean paired drain on each push without tripping the
    // solo-source fallback. 10 cycles = 80 000 samples = one 5-second chunk
    // out of each chunker.
    private let cycleFrames = 8_000
    private let cyclesForOneChunk = 10

    /// Chunk timestamps come from each chunker's `totalSamplesProcessed`,
    /// which the pair joiner keeps in lockstep with wallclock via silence
    /// padding. Per-source `AVAudioTime.hostTime` plays no role in chunk
    /// timestamping — so even pathological mixes (mic nil, system valid mach
    /// uptime) can't leak absolute uptime into chunk startMs.
    func testMicNilHostTime_systemValidUptime_keepsBothChunksAtZero() async {
        let orchestrator = CaptureOrchestrator()
        let conditioner = PassthroughMicConditioner()

        let chunks = await driveCycles(
            orchestrator: orchestrator,
            conditioner: conditioner,
            cycles: cyclesForOneChunk,
            micHostTimeBaseSeconds: nil,
            systemHostTimeBaseSeconds: 92_721.0
        )

        guard let micStart = chunks.first(where: { $0.source == .microphone })?.chunk.startMs,
              let systemStart = chunks.first(where: { $0.source == .system })?.chunk.startMs else {
            XCTFail("expected one chunk per source, got \(chunks.map { ($0.source, $0.chunk.startMs) })")
            return
        }

        XCTAssertEqual(micStart, 0, "mic first chunk should start at 0; got \(micStart)ms")
        XCTAssertEqual(systemStart, 0, "system first chunk should start at 0; got \(systemStart)ms")
    }

    /// When both sources deliver valid hostTimes with a small startup delta
    /// (e.g. system capture arrived 200ms after mic), the chunk timestamps still
    /// come from the lockstep chunker counters — not from the hostTime delta.
    /// Both first chunks should land at startMs=0 because both chunkers
    /// processed their first chunkSize worth of samples in parallel
    /// (the gap is absorbed by silence padding).
    func testBothValidHostTimes_chunksAreLockstepNotHostTimeOffset() async {
        let orchestrator = CaptureOrchestrator()
        let conditioner = PassthroughMicConditioner()

        let chunks = await driveCycles(
            orchestrator: orchestrator,
            conditioner: conditioner,
            cycles: cyclesForOneChunk,
            micHostTimeBaseSeconds: 92_721.0,
            // System started 200 ms after mic.
            systemHostTimeBaseSeconds: 92_721.200
        )

        guard let micStart = chunks.first(where: { $0.source == .microphone })?.chunk.startMs,
              let systemStart = chunks.first(where: { $0.source == .system })?.chunk.startMs else {
            XCTFail("expected one chunk per source")
            return
        }

        XCTAssertEqual(micStart, 0, "mic first chunk leaked hostTime: \(micStart)ms")
        XCTAssertEqual(systemStart, 0, "system first chunk leaked hostTime: \(systemStart)ms")
        XCTAssertEqual(
            systemStart - micStart,
            0,
            "cross-stream delta must be zero — chunkers are kept lockstep with wallclock via silence padding, not offset by hostTime gap"
        )
    }

    /// Long-recording drift bug: when system capture goes quiet for an
    /// extended stretch, the pair joiner emits "solo mic" pairs (mic samples +
    /// silence-padded system samples). Pre-fix, only the mic chunker was fed —
    /// the system chunker's `totalSamplesProcessed` stayed frozen while mic's
    /// kept tracking wallclock. Mic chunk timestamps drifted into the future
    /// relative to system; in a real recording, this rendered as
    /// "Me 17:24" inside a 9:20 elapsed session.
    ///
    /// Fix: feed both chunkers on every pair, using the silence-padded samples
    /// from the absent source so the two `totalSamplesProcessed` counters
    /// remain in lockstep with wallclock.
    func testMicOnlyStretchKeepsSystemChunkerAlignedWithMic() async {
        let orchestrator = CaptureOrchestrator()
        let conditioner = PassthroughMicConditioner()

        // Drive 30 cycles of mic-only ingests (no system pushes). At 8k samples
        // per cycle (0.5 s), the joiner enters solo-mic mode after the first
        // couple of cycles and stays there — exactly the pattern that produced
        // the observed drift in real recordings.
        var allChunks: [CaptureOrchestratorChunk] = []
        let cycleSeconds = Double(cycleFrames) / 16_000.0
        for cycle in 0..<30 {
            let micBatch = [Float](repeating: 0.1, count: cycleFrames)
            let micHostTime = AVAudioTime.hostTime(forSeconds: 100.0 + Double(cycle) * cycleSeconds)
            let out = await orchestrator.ingest(
                samples: micBatch,
                source: .microphone,
                hostTime: micHostTime,
                micConditioner: conditioner
            )
            allChunks.append(contentsOf: out.chunks)
        }

        let micChunks = allChunks.filter { $0.source == .microphone }
        let systemChunks = allChunks.filter { $0.source == .system }

        XCTAssertFalse(micChunks.isEmpty, "expected mic chunks during mic-only stretch")
        XCTAssertFalse(
            systemChunks.isEmpty,
            "system chunker emitted nothing during a mic-only stretch — its sample counter froze while mic's tracked wallclock, which is exactly the drift that produced 'Me 17:24' inside a 9:20 recording"
        )
        // Both chunkers should have processed the same amount of audio, so
        // they should emit the same number of chunks.
        XCTAssertEqual(
            micChunks.count,
            systemChunks.count,
            "mic and system chunkers diverged during mic-only stretch (mic=\(micChunks.count), system=\(systemChunks.count))"
        )
        // First-chunk startMs values should match — both saw the same wallclock.
        if let firstMic = micChunks.first?.chunk.startMs,
           let firstSystem = systemChunks.first?.chunk.startMs {
            XCTAssertEqual(
                firstMic,
                firstSystem,
                "first mic and system chunks misaligned: mic=\(firstMic)ms system=\(firstSystem)ms"
            )
        }
    }

    /// Defensive case: if neither source ever publishes a valid hostTime
    /// (both taps stay `isHostTimeValid == false` for the whole recording),
    /// chunk timestamps still anchor at 0 because they're derived from the
    /// chunkers' sample counters, not from hostTime.
    func testBothSourcesNilHostTimeForever_keepsBothAtZeroOffset() async {
        let orchestrator = CaptureOrchestrator()
        let conditioner = PassthroughMicConditioner()

        let chunks = await driveCycles(
            orchestrator: orchestrator,
            conditioner: conditioner,
            cycles: cyclesForOneChunk,
            micHostTimeBaseSeconds: nil,
            systemHostTimeBaseSeconds: nil
        )

        guard let micStart = chunks.first(where: { $0.source == .microphone })?.chunk.startMs,
              let systemStart = chunks.first(where: { $0.source == .system })?.chunk.startMs else {
            XCTFail("expected one chunk per source even with no hostTimes")
            return
        }
        XCTAssertEqual(micStart, 0, "mic startMs should fall back to 0 when no hostTime ever arrives")
        XCTAssertEqual(systemStart, 0, "system startMs should fall back to 0 when no hostTime ever arrives")
    }

    /// `reset()` must clear chunker state so a fresh recording starts at
    /// t=0 instead of carrying the previous session's sample counters.
    func testResetClearsTimelineOriginAcrossRecordings() async {
        let orchestrator = CaptureOrchestrator()
        let conditioner = PassthroughMicConditioner()

        // First recording at uptime ~92 721 s — discard chunks.
        _ = await driveCycles(
            orchestrator: orchestrator,
            conditioner: conditioner,
            cycles: cyclesForOneChunk,
            micHostTimeBaseSeconds: 92_721.0,
            systemHostTimeBaseSeconds: 92_721.0
        )

        await orchestrator.reset()

        // Second recording at uptime ~92 900 s — should restart relative to itself.
        let chunks = await driveCycles(
            orchestrator: orchestrator,
            conditioner: conditioner,
            cycles: cyclesForOneChunk,
            micHostTimeBaseSeconds: 92_900.0,
            systemHostTimeBaseSeconds: 92_900.0
        )

        guard let micStart = chunks.first(where: { $0.source == .microphone })?.chunk.startMs,
              let systemStart = chunks.first(where: { $0.source == .system })?.chunk.startMs else {
            XCTFail("expected one chunk per source after reset")
            return
        }
        XCTAssertLessThan(
            micStart,
            5_000,
            "second recording's mic chunk leaked previous-session origin: \(micStart)ms"
        )
        XCTAssertLessThan(
            systemStart,
            5_000,
            "second recording's system chunk leaked previous-session origin: \(systemStart)ms"
        )
    }

    func testProcessedMicrophoneSamplesFeedMicrophoneChunker() async {
        // Disable the echo gate (no coherence can reach a threshold above 1) so
        // this test isolates the conditioner→chunker plumbing; the degenerate
        // constant signals it drives would otherwise read as pure echo and mute.
        let orchestrator = CaptureOrchestrator(
            microphoneEchoGate: MicrophoneEchoGate(echoDominanceThreshold: 2)
        )
        let conditioner = ConstantMicConditioner(sampleValue: 0.125)

        let chunks = await driveCycles(
            orchestrator: orchestrator,
            conditioner: conditioner,
            cycles: cyclesForOneChunk,
            micHostTimeBaseSeconds: 92_721.0,
            systemHostTimeBaseSeconds: 92_721.0
        )

        let micChunk = try? XCTUnwrap(chunks.first(where: { $0.source == .microphone })?.chunk)
        guard let micChunk else { return }
        XCTAssertTrue(
            micChunk.samples.allSatisfy { abs($0 - 0.125) < 0.0001 },
            "microphone chunker must receive conditioned mic samples, not raw mic samples"
        )
        XCTAssertEqual(conditioner.callCount, cyclesForOneChunk)
    }

    /// Once the echo delay is locked, the reference handed to the conditioner is
    /// the system stream time-shifted by the estimated delay — not the
    /// same-instant system samples — so the suppressor finally sees the far-end
    /// aligned with the echo in the mic.
    func testConditionerReferenceIsDelayAlignedOnceLocked() async {
        let aligner = EchoReferenceAligner(
            sampleRate: 16_000,
            maxDelayMs: 50,
            correlationWindow: 1_000,
            minConfidence: 0.5
        )
        let orchestrator = CaptureOrchestrator(referenceAligner: aligner)
        let conditioner = RecordingMicConditioner()

        let delay = 320
        let blockSize = 2_048
        let blocks = 6
        let total = blockSize * blocks
        let system = whiteNoise(count: total, seed: 7)
        var microphone = [Float](repeating: 0, count: total)
        for index in delay..<total {
            microphone[index] = 0.5 * system[index - delay]
        }

        for block in 0..<blocks {
            let lower = block * blockSize
            let upper = lower + blockSize
            _ = await orchestrator.ingest(
                samples: Array(microphone[lower..<upper]),
                source: .microphone,
                hostTime: nil,
                micConditioner: conditioner
            )
            _ = await orchestrator.ingest(
                samples: Array(system[lower..<upper]),
                source: .system,
                hostTime: nil,
                micConditioner: conditioner
            )
        }

        XCTAssertFalse(conditioner.references.isEmpty, "conditioner should be called for paired drains")
        XCTAssertNotEqual(
            conditioner.references.last,
            Array(system[(total - blockSize)..<total]),
            "reference must be delay-aligned, not the same-instant system block"
        )
    }

    /// Once the delay is locked, microphone windows that are just the far-end
    /// echoing back are muted before they reach the chunker — so the mic chunk
    /// shipped to STT is far quieter than the system chunk, even though the raw
    /// mic was a loud copy of the system.
    func testGatesEchoOutOfMicrophoneChunkOnceLocked() async {
        let aligner = EchoReferenceAligner(
            sampleRate: 16_000,
            maxDelayMs: 50,
            correlationWindow: 1_000,
            minConfidence: 0.5
        )
        let orchestrator = CaptureOrchestrator(referenceAligner: aligner)
        let conditioner = PassthroughMicConditioner()

        let delay = 320
        let blockSize = 2_048
        let blocks = 45 // > 80 000 samples, so at least one 5 s chunk is emitted
        let total = blockSize * blocks
        let system = whiteNoise(count: total, seed: 7)
        var microphone = [Float](repeating: 0, count: total)
        for index in delay..<total {
            microphone[index] = 0.5 * system[index - delay] // pure acoustic echo
        }

        var chunks: [CaptureOrchestratorChunk] = []
        for block in 0..<blocks {
            let lower = block * blockSize
            let upper = lower + blockSize
            let outMic = await orchestrator.ingest(
                samples: Array(microphone[lower..<upper]),
                source: .microphone, hostTime: nil, micConditioner: conditioner
            )
            let outSystem = await orchestrator.ingest(
                samples: Array(system[lower..<upper]),
                source: .system, hostTime: nil, micConditioner: conditioner
            )
            chunks.append(contentsOf: outMic.chunks)
            chunks.append(contentsOf: outSystem.chunks)
        }

        guard let micChunk = chunks.first(where: { $0.source == .microphone })?.chunk,
              let systemChunk = chunks.first(where: { $0.source == .system })?.chunk else {
            XCTFail("expected at least one chunk per source")
            return
        }

        let micRms = rms(micChunk.samples)
        let systemRms = rms(systemChunk.samples)
        XCTAssertGreaterThan(systemRms, 0.01, "system chunk should carry the far-end signal")
        XCTAssertLessThan(
            micRms,
            systemRms * 0.2,
            "echo should be gated out of the mic chunk (micRms=\(micRms), systemRms=\(systemRms))"
        )
    }

    /// The finalize diagnostics must be able to see whether the echo delay
    /// locked and how many mic windows the gate muted — otherwise the audio-side
    /// echo removal is invisible when a recording still has problems.
    func testEchoDiagnosticsReportLockAndGateActivity() async {
        let aligner = EchoReferenceAligner(
            sampleRate: 16_000,
            maxDelayMs: 50,
            correlationWindow: 1_000,
            minConfidence: 0.5
        )
        let orchestrator = CaptureOrchestrator(referenceAligner: aligner)
        let conditioner = PassthroughMicConditioner()

        let delay = 320
        let blockSize = 2_048
        let blocks = 6
        let total = blockSize * blocks
        let system = whiteNoise(count: total, seed: 7)
        var microphone = [Float](repeating: 0, count: total)
        for index in delay..<total {
            microphone[index] = 0.5 * system[index - delay]
        }

        for block in 0..<blocks {
            let lower = block * blockSize
            let upper = lower + blockSize
            _ = await orchestrator.ingest(
                samples: Array(microphone[lower..<upper]),
                source: .microphone, hostTime: nil, micConditioner: conditioner
            )
            _ = await orchestrator.ingest(
                samples: Array(system[lower..<upper]),
                source: .system, hostTime: nil, micConditioner: conditioner
            )
        }

        let diagnostics = await orchestrator.echoDiagnostics()
        XCTAssertNotNil(diagnostics.alignerLockedDelaySamples, "aligner should have locked on the synthetic echo")
        XCTAssertGreaterThan(diagnostics.gateMutedWindows, 0, "gate should have muted echo windows after lock")
        XCTAssertGreaterThanOrEqual(diagnostics.gateInspectedWindows, diagnostics.gateMutedWindows)
    }

    // MARK: - helpers

    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }

    private func whiteNoise(count: Int, seed: UInt64) -> [Float] {
        var state = seed &+ 0x9E3779B97F4A7C15
        var out = [Float]()
        out.reserveCapacity(count)
        for _ in 0..<count {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let bits = UInt32(truncatingIfNeeded: state >> 32)
            out.append(Float(bits) / Float(UInt32.max) * 2 - 1)
        }
        return out
    }

    /// Push `cycles` paired 8 k-sample batches through the orchestrator so the
    /// chunkers see steady paired drains. Each cycle stamps a fresh hostTime
    /// per source (advancing by 0.5 s — one batch duration), matching how the
    /// real audio stack delivers a new mach time on every buffer. Pass nil
    /// for a source's base seconds to simulate `isHostTimeValid == false`
    /// across the entire stream.
    private func driveCycles(
        orchestrator: CaptureOrchestrator,
        conditioner: any MicConditioning,
        cycles: Int,
        micHostTimeBaseSeconds: Double?,
        systemHostTimeBaseSeconds: Double?
    ) async -> [CaptureOrchestratorChunk] {
        let cycleSeconds = Double(cycleFrames) / 16_000.0
        var collected: [CaptureOrchestratorChunk] = []
        for cycle in 0..<cycles {
            let micBatch = [Float](repeating: 0.1, count: cycleFrames)
            let sysBatch = [Float](repeating: 0.1, count: cycleFrames)
            let micHostTime: UInt64? = micHostTimeBaseSeconds.map {
                AVAudioTime.hostTime(forSeconds: $0 + cycleSeconds * Double(cycle))
            }
            let sysHostTime: UInt64? = systemHostTimeBaseSeconds.map {
                AVAudioTime.hostTime(forSeconds: $0 + cycleSeconds * Double(cycle))
            }

            let outA = await orchestrator.ingest(
                samples: micBatch,
                source: .microphone,
                hostTime: micHostTime,
                micConditioner: conditioner
            )
            let outB = await orchestrator.ingest(
                samples: sysBatch,
                source: .system,
                hostTime: sysHostTime,
                micConditioner: conditioner
            )
            collected.append(contentsOf: outA.chunks)
            collected.append(contentsOf: outB.chunks)
        }
        return collected
    }
}

private final class ConstantMicConditioner: MicConditioning, @unchecked Sendable {
    private let sampleValue: Float
    private(set) var callCount = 0
    private(set) var diagnostics = MeetingEchoSuppressionDiagnostics.passthrough()

    init(sampleValue: Float) {
        self.sampleValue = sampleValue
    }

    func condition(microphone: [Float], speaker: [Float], hasSpeakerReference: Bool) -> [Float] {
        callCount += 1
        return [Float](repeating: sampleValue, count: microphone.count)
    }

    func reset() {
        callCount = 0
        diagnostics = MeetingEchoSuppressionDiagnostics.passthrough()
    }
}

private final class RecordingMicConditioner: MicConditioning, @unchecked Sendable {
    private(set) var references: [[Float]] = []
    private(set) var diagnostics = MeetingEchoSuppressionDiagnostics.passthrough()

    func condition(microphone: [Float], speaker: [Float], hasSpeakerReference: Bool) -> [Float] {
        references.append(speaker)
        return microphone
    }

    func reset() {
        references.removeAll()
        diagnostics = MeetingEchoSuppressionDiagnostics.passthrough()
    }
}
