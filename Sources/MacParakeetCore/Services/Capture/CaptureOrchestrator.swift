import Foundation

struct CaptureOrchestratorChunk: Sendable {
    let source: AudioSource
    let chunk: AudioChunker.AudioChunk
}

struct CaptureOrchestratorPairMetadata: Sendable {
    let microphoneHostTime: UInt64?
    let systemHostTime: UInt64?
    let processedMicrophoneRms: Float?
}

struct CaptureOrchestratorOutput: Sendable {
    var chunks: [CaptureOrchestratorChunk] = []
    var diagnostics: [MeetingAudioJoinerDiagnostic] = []
    var pairMetadata: [CaptureOrchestratorPairMetadata] = []
}

/// Observability snapshot for the echo-removal stages, surfaced in the meeting
/// recording's finalize diagnostics so the aligner and gate are no longer
/// invisible: did the echo delay lock, and how many mic windows were muted.
struct CaptureOrchestratorEchoDiagnostics: Sendable, Equatable {
    let alignerLockedDelaySamples: Int?
    let gateInspectedWindows: Int
    let gateMutedWindows: Int
}

actor CaptureOrchestrator {
    private var pairJoiner = MeetingAudioPairJoiner()
    private var microphoneChunker: any MeetingLiveAudioChunking = FixedMeetingLiveAudioChunker()
    private var systemChunker: any MeetingLiveAudioChunking = FixedMeetingLiveAudioChunker()
    private var referenceAligner: EchoReferenceAligner
    private var microphoneEchoGate: MicrophoneEchoGate

    init(
        referenceAligner: EchoReferenceAligner = EchoReferenceAligner(),
        microphoneEchoGate: MicrophoneEchoGate = MicrophoneEchoGate()
    ) {
        self.referenceAligner = referenceAligner
        self.microphoneEchoGate = microphoneEchoGate
    }

    /// Swap in the per-source chunkers for the next recording. Sources are
    /// independent so one can use VAD while the other falls back to fixed.
    /// Call before `reset()` at session start; defaults to fixed chunkers.
    func configureChunkers(
        microphone: any MeetingLiveAudioChunking,
        system: any MeetingLiveAudioChunking
    ) {
        microphoneChunker = microphone
        systemChunker = system
    }

    func reset() async {
        pairJoiner.reset()
        referenceAligner.reset()
        microphoneEchoGate.reset()
        await microphoneChunker.reset()
        await systemChunker.reset()
    }

    /// Snapshot of the echo-removal stages for finalize-time diagnostics.
    func echoDiagnostics() -> CaptureOrchestratorEchoDiagnostics {
        CaptureOrchestratorEchoDiagnostics(
            alignerLockedDelaySamples: referenceAligner.lockedDelaySamples,
            gateInspectedWindows: microphoneEchoGate.inspectedWindows,
            gateMutedWindows: microphoneEchoGate.gatedWindows
        )
    }

    func ingest(
        samples: [Float],
        source: AudioSource,
        hostTime: UInt64?,
        micConditioner: any MicConditioning
    ) async -> CaptureOrchestratorOutput {
        pairJoiner.push(samples: samples, hostTime: hostTime, source: source)
        let pairs = pairJoiner.drainPairs()
        var output = await processPairs(pairs, micConditioner: micConditioner)
        output.diagnostics = pairJoiner.drainDiagnostics()
        return output
    }

    func flushPendingPairs(
        micConditioner: any MicConditioning
    ) async -> CaptureOrchestratorOutput {
        let pairs = pairJoiner.flushRemainingPairs()
        return await processPairs(pairs, micConditioner: micConditioner)
    }

    func flushChunkers() async -> [CaptureOrchestratorChunk] {
        var chunks: [CaptureOrchestratorChunk] = []
        if let microphone = await microphoneChunker.flush() {
            chunks.append(CaptureOrchestratorChunk(source: .microphone, chunk: microphone))
        }
        if let system = await systemChunker.flush() {
            chunks.append(CaptureOrchestratorChunk(source: .system, chunk: system))
        }
        return chunks
    }

    private func processPairs(
        _ pairs: [MeetingAudioPair],
        micConditioner: any MicConditioning
    ) async -> CaptureOrchestratorOutput {
        var output = CaptureOrchestratorOutput()
        for pair in pairs {
            // Feed both chunkers on every pair so their sample-position
            // counters stay aligned with wallclock. The pair joiner already
            // pads the absent source with silence on solo drains; without
            // pushing those zeros through to the absent chunker, its
            // `totalSamplesProcessed` freezes while the active source's
            // tracks wallclock — producing future-dated chunks (e.g.
            // "Me 17:24" inside a 9:20 recording).
            // Time-align the far-end reference with the echo in the mic before
            // suppression — the echo arrives a device-dependent delay after the
            // system audio is captured, so the same-instant reference cannot
            // cancel. Run on every pair (including silent/solo ones) so the
            // delay line stays in step with the system timeline: lingering echo
            // after the far-end stops still needs its delayed reference.
            let reference = referenceAligner.alignedReference(
                microphone: pair.microphoneSamples,
                system: pair.systemSamples
            )

            var processedMicrophoneRms: Float?
            let micSamples: [Float]
            if pair.hasMicrophoneSignal {
                let processedMic = micConditioner.condition(
                    microphone: pair.microphoneSamples,
                    speaker: reference,
                    hasSpeakerReference: reference.contains { $0 != 0 }
                )
                // Mute windows that are overwhelmingly far-end echo before they
                // reach STT, but only once the delay is locked so the reference
                // is genuinely aligned with the echo. The far-end's words still
                // survive on the clean system stream, and the on-disk recording
                // keeps the raw mic — only the STT-bound copy is gated.
                let gatedMic = microphoneEchoGate.process(
                    microphone: processedMic,
                    reference: reference,
                    aligned: referenceAligner.lockedDelaySamples != nil
                )
                processedMicrophoneRms = chunkRms(for: gatedMic)
                micSamples = gatedMic
            } else {
                micSamples = pair.microphoneSamples
            }

            for micChunk in await microphoneChunker.addSamples(micSamples) {
                output.chunks.append(CaptureOrchestratorChunk(source: .microphone, chunk: micChunk))
            }

            for systemChunk in await systemChunker.addSamples(pair.systemSamples) {
                output.chunks.append(CaptureOrchestratorChunk(source: .system, chunk: systemChunk))
            }

            output.pairMetadata.append(
                CaptureOrchestratorPairMetadata(
                    microphoneHostTime: pair.microphoneHostTime,
                    systemHostTime: pair.systemHostTime,
                    processedMicrophoneRms: processedMicrophoneRms
                )
            )
        }
        return output
    }

    private func chunkRms(for samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumSquares: Float = 0
        for sample in samples {
            sumSquares += sample * sample
        }
        return sqrt(sumSquares / Float(samples.count))
    }
}
