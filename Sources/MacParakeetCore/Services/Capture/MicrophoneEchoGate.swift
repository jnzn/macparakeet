import Foundation

/// Suppresses residual acoustic echo in the microphone signal before it reaches
/// STT, by muting short windows that are overwhelmingly a copy of the far-end.
///
/// The far-end plays through the speakers and leaks back into the raw mic. After
/// ``EchoReferenceAligner`` locks the speaker→mic delay, the supplied reference
/// is the far-end time-aligned with that echo, so within any short window the
/// echo is (close to) a scaled copy of the reference. We measure how much of the
/// mic window's energy is explained by the reference — the squared normalized
/// cross-correlation, i.e. coherence. Coherence is a *waveform* test, so it
/// tells echo apart from genuine double-talk: when the local speaker talks over
/// the far-end the mic carries a second, uncorrelated voice and coherence drops,
/// even if both happen to say the same word. Only windows that are almost
/// entirely the far-end are zeroed; everything else passes through unchanged.
///
/// Conservative by construction — it never runs until the delay is locked, and
/// when a window is ambiguous it keeps the audio. The far-end's own words are
/// always preserved on the clean system stream, so muting its echo here can only
/// remove duplication, never lose content. Sample count is preserved exactly so
/// downstream chunk timestamps are unaffected.
struct MicrophoneEchoGate {
    let windowSamples: Int
    let referenceFloorRms: Float
    let echoDominanceThreshold: Float
    let passHangoverWindows: Int

    init(
        windowSamples: Int = 320,
        referenceFloorRms: Float = 0.01,
        echoDominanceThreshold: Float = 0.8,
        passHangoverWindows: Int = 3
    ) {
        self.windowSamples = max(1, windowSamples)
        self.referenceFloorRms = referenceFloorRms
        self.echoDominanceThreshold = echoDominanceThreshold
        self.passHangoverWindows = max(0, passHangoverWindows)
    }

    private var passHoldRemaining = 0

    /// Windows inspected and windows muted since the last ``reset()`` — surfaced
    /// in capture diagnostics so the gate's real-world activity is observable.
    private(set) var inspectedWindows = 0
    private(set) var gatedWindows = 0

    mutating func reset() {
        passHoldRemaining = 0
        inspectedWindows = 0
        gatedWindows = 0
    }

    /// Returns `microphone` with echo-dominated windows zeroed. `reference` must
    /// be the far-end already aligned to the echo; `aligned` is whether the
    /// delay has been locked yet. Output length always equals the input length.
    mutating func process(microphone: [Float], reference: [Float], aligned: Bool) -> [Float] {
        guard aligned, !microphone.isEmpty else { return microphone }

        var output = microphone
        var start = 0
        while start + windowSamples <= microphone.count {
            let end = start + windowSamples
            inspectedWindows += 1
            if shouldGateWindow(microphone: microphone, reference: reference, start: start, end: end) {
                gatedWindows += 1
                for index in start..<end {
                    output[index] = 0
                }
            }
            start += windowSamples
        }
        // A trailing partial window (< windowSamples) is left untouched: too
        // short for a stable coherence estimate, and never dropping samples
        // keeps the mic timeline aligned with the system stream.
        return output
    }

    /// True when the window is overwhelmingly the far-end echoing back, after
    /// honoring a brief hold that protects the tail of just-detected near-end
    /// speech from being clipped.
    private mutating func shouldGateWindow(
        microphone: [Float],
        reference: [Float],
        start: Int,
        end: Int
    ) -> Bool {
        // No aligned reference for this window → can't attribute it to the
        // far-end → keep it (and treat as near-end for hold purposes).
        guard end <= reference.count else {
            passHoldRemaining = passHangoverWindows
            return false
        }

        var micEnergy: Float = 0
        var refEnergy: Float = 0
        var crossEnergy: Float = 0
        for index in start..<end {
            let micSample = microphone[index]
            let refSample = reference[index]
            micEnergy += micSample * micSample
            refEnergy += refSample * refSample
            crossEnergy += micSample * refSample
        }

        let windowLength = Float(end - start)
        let referenceRms = (refEnergy / windowLength).squareRoot()
        guard referenceRms >= referenceFloorRms, micEnergy > 0 else {
            // Far-end silent (or mic silent): nothing to attribute to echo.
            passHoldRemaining = passHangoverWindows
            return false
        }

        // Fraction of the mic window's energy explained by a best-fit scaled
        // copy of the reference == squared normalized cross-correlation.
        let coherence = (crossEnergy * crossEnergy) / (refEnergy * micEnergy)
        guard coherence >= echoDominanceThreshold else {
            // Independent near-end energy present (double-talk or local speech).
            passHoldRemaining = passHangoverWindows
            return false
        }

        if passHoldRemaining > 0 {
            passHoldRemaining -= 1
            return false
        }
        return true
    }
}
