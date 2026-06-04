import XCTest
@testable import MacParakeetCore

final class MicrophoneEchoGateTests: XCTestCase {
    // Pure echo: the mic is a scaled copy of the (already delay-aligned) far-end
    // reference. Once alignment is locked, those windows are nothing but the
    // far-end leaking back in and must be zeroed before they reach STT.
    func testZerosPureEchoWindowsWhenAligned() {
        var gate = makeGate()
        let reference = whiteNoise(count: 3_200, seed: 11, scale: 0.3)
        let microphone = reference.map { $0 * 0.5 }

        let gated = gate.process(microphone: microphone, reference: reference, aligned: true)

        XCTAssertEqual(gated.count, microphone.count, "gate must preserve sample count for chunk timing")
        XCTAssertTrue(gated.allSatisfy { $0 == 0 }, "pure echo should be fully gated")
    }

    // Local speech only: the far-end is silent, so whatever the mic hears is the
    // local speaker. Nothing may be gated.
    func testKeepsNearEndWhenFarEndSilent() {
        var gate = makeGate()
        let reference = [Float](repeating: 0, count: 3_200)
        let microphone = whiteNoise(count: 3_200, seed: 22, scale: 0.3)

        let gated = gate.process(microphone: microphone, reference: reference, aligned: true)

        XCTAssertEqual(gated, microphone, "near-end speech over a silent far-end must pass untouched")
    }

    // Double-talk: the local speaker talks over the far-end, so the mic is the
    // echo PLUS an independent near-end voice. Because the near-end waveform is
    // uncorrelated with the reference, coherence stays low and the window is
    // kept — the far-end copy still survives cleanly on the system stream.
    func testKeepsDoubleTalkWhereNearEndDominatesResidual() {
        var gate = makeGate()
        let reference = whiteNoise(count: 3_200, seed: 33, scale: 0.3)
        let nearEnd = whiteNoise(count: 3_200, seed: 99, scale: 0.3)
        let microphone = zip(reference, nearEnd).map { 0.4 * $0 + $1 }

        let gated = gate.process(microphone: microphone, reference: reference, aligned: true)

        XCTAssertEqual(gated, microphone, "double-talk with a strong independent near-end must be preserved")
    }

    // Until the aligner locks a delay the reference is not time-aligned with the
    // echo, so the gate must stay completely inert — never worse than today.
    func testInertUntilAligned() {
        var gate = makeGate()
        let reference = whiteNoise(count: 3_200, seed: 11, scale: 0.3)
        let microphone = reference.map { $0 * 0.5 }

        let gated = gate.process(microphone: microphone, reference: reference, aligned: false)

        XCTAssertEqual(gated, microphone, "gate must be inert before the echo delay is locked")
    }

    // MARK: - helpers

    private func makeGate() -> MicrophoneEchoGate {
        MicrophoneEchoGate(
            windowSamples: 320,
            referenceFloorRms: 0.01,
            echoDominanceThreshold: 0.8,
            passHangoverWindows: 0
        )
    }

    private func whiteNoise(count: Int, seed: UInt64, scale: Float) -> [Float] {
        var state = seed &+ 0x9E37_79B9_7F4A_7C15
        var out = [Float]()
        out.reserveCapacity(count)
        for _ in 0..<count {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let bits = UInt32(truncatingIfNeeded: state >> 32)
            out.append((Float(bits) / Float(UInt32.max) * 2 - 1) * scale)
        }
        return out
    }
}
