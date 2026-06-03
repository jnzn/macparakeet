import XCTest
@testable import MacParakeetCore

final class EchoReferenceAlignerTests: XCTestCase {
    // MARK: - Delay line

    func testDelayLineZeroPrefillsThenEmitsDelayedInput() {
        var line = EchoReferenceDelayLine(delaySamples: 2)
        XCTAssertEqual(line.process([1, 2, 3]), [0, 0, 1])
        XCTAssertEqual(line.process([4, 5]), [2, 3])
    }

    func testDelayLineZeroDelayIsPassthrough() {
        var line = EchoReferenceDelayLine(delaySamples: 0)
        XCTAssertEqual(line.process([1, 2, 3]), [1, 2, 3])
    }

    // MARK: - Aligner

    func testReturnsSystemUnchangedBeforeConfidentLock() {
        var aligner = makeAligner()
        let system = noise(count: 256, seed: 1)
        let microphone = noise(count: 256, seed: 2)

        let reference = aligner.alignedReference(microphone: microphone, system: system)

        XCTAssertEqual(reference, system)
        XCTAssertNil(aligner.lockedDelaySamples)
    }

    func testLocksOntoKnownEchoDelay() {
        let delay = 320
        var aligner = makeAligner()
        let (system, microphone) = echoPair(totalSamples: 3_000, delay: delay, gain: 0.5, seed: 7)

        feed(&aligner, system: system, microphone: microphone, blockSize: 256)

        XCTAssertEqual(aligner.lockedDelaySamples, delay)
    }

    func testStaysInertWhenMicrophoneUncorrelatedWithSystem() {
        var aligner = makeAligner()
        let system = noise(count: 4_000, seed: 11)
        let microphone = noise(count: 4_000, seed: 99)

        feed(&aligner, system: system, microphone: microphone, blockSize: 256)

        XCTAssertNil(aligner.lockedDelaySamples)
    }

    func testStaysInertWhenFarEndSilent() {
        var aligner = makeAligner()
        let system = [Float](repeating: 0, count: 4_000)
        let microphone = noise(count: 4_000, seed: 3)

        feed(&aligner, system: system, microphone: microphone, blockSize: 256)

        XCTAssertNil(aligner.lockedDelaySamples)
    }

    func testReferenceIsDelayedNotPassthroughAfterLock() {
        let delay = 320
        var aligner = makeAligner()
        let (system, microphone) = echoPair(totalSamples: 3_000, delay: delay, gain: 0.5, seed: 7)
        feed(&aligner, system: system, microphone: microphone, blockSize: 256)
        XCTAssertEqual(aligner.lockedDelaySamples, delay, "precondition: aligner must lock")

        // Once locked the reference is the system stream delayed by `delay`
        // (the delay line is already warmed by the post-lock tail of `feed`), so
        // a fresh system block comes back time-shifted — not the same-instant
        // input. The exact per-sample shift is covered by the delay-line tests.
        let probe = noise(count: delay, seed: 222)
        let reference = aligner.alignedReference(
            microphone: [Float](repeating: 0, count: delay),
            system: probe
        )

        XCTAssertEqual(reference.count, probe.count)
        XCTAssertNotEqual(reference, probe, "reference should be delayed, not passthrough")
    }

    func testResetClearsLock() {
        let delay = 320
        var aligner = makeAligner()
        let (system, microphone) = echoPair(totalSamples: 3_000, delay: delay, gain: 0.5, seed: 7)
        feed(&aligner, system: system, microphone: microphone, blockSize: 256)
        XCTAssertEqual(aligner.lockedDelaySamples, delay)

        aligner.reset()

        XCTAssertNil(aligner.lockedDelaySamples)
        let system2 = noise(count: 256, seed: 5)
        XCTAssertEqual(aligner.alignedReference(microphone: noise(count: 256, seed: 6), system: system2), system2)
    }

    // MARK: - helpers

    private func makeAligner() -> EchoReferenceAligner {
        // Small window/lag so estimation is cheap and locks within a few hundred ms.
        EchoReferenceAligner(
            sampleRate: 16_000,
            maxDelayMs: 50,            // 800 samples
            correlationWindow: 1_000,
            minConfidence: 0.5
        )
    }

    private func feed(
        _ aligner: inout EchoReferenceAligner,
        system: [Float],
        microphone: [Float],
        blockSize: Int
    ) {
        var index = 0
        let total = min(system.count, microphone.count)
        while index < total {
            let end = min(index + blockSize, total)
            _ = aligner.alignedReference(
                microphone: Array(microphone[index..<end]),
                system: Array(system[index..<end])
            )
            index = end
        }
    }

    /// `system` is broadband noise; `microphone` is that same signal delayed by
    /// `delay` and scaled by `gain` — a pure acoustic echo with no near-end.
    private func echoPair(totalSamples: Int, delay: Int, gain: Float, seed: UInt64) -> (system: [Float], microphone: [Float]) {
        let system = noise(count: totalSamples, seed: seed)
        var microphone = [Float](repeating: 0, count: totalSamples)
        for i in delay..<totalSamples {
            microphone[i] = gain * system[i - delay]
        }
        return (system, microphone)
    }

    private func noise(count: Int, seed: UInt64) -> [Float] {
        var state = seed &+ 0x9E3779B97F4A7C15
        var out = [Float]()
        out.reserveCapacity(count)
        for _ in 0..<count {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let bits = UInt32(truncatingIfNeeded: state >> 32)
            // Map to [-1, 1).
            out.append(Float(bits) / Float(UInt32.max) * 2 - 1)
        }
        return out
    }
}
