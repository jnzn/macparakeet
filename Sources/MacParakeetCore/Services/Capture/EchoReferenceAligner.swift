import Foundation

/// FIFO delay line: emits its input delayed by a fixed number of samples,
/// zero-filled at the start. Used to time-shift the far-end (system) reference
/// so it lines up with the echo in the microphone before echo suppression.
struct EchoReferenceDelayLine {
    private var pending: [Float]

    init(delaySamples: Int) {
        pending = [Float](repeating: 0, count: max(0, delaySamples))
    }

    mutating func process(_ input: [Float]) -> [Float] {
        guard !input.isEmpty else { return input }
        pending.append(contentsOf: input)
        let output = Array(pending.prefix(input.count))
        pending.removeFirst(input.count)
        return output
    }
}

/// Time-aligns the far-end (system) reference with the echo present in the raw
/// microphone before that reference is handed to the echo suppressor.
///
/// The far-end plays through the speakers and arrives back at the mic a short,
/// device-dependent delay later (output buffering + DAC + speaker + air + mic +
/// ADC + input buffering — typically ~100–300 ms on a laptop). Feeding the
/// suppressor the *same-instant* system samples (zero delay) gives it a
/// reference that is out of phase with the echo, so it cannot cancel — which is
/// why the shipped suppressor underperforms.
///
/// This estimates the delay by normalized cross-correlation during far-end
/// dominant stretches (the other party talking while the local mic is mostly
/// just echo) and, once it has a confident estimate, locks it and delays the
/// reference to match. The acoustic path latency is effectively constant for a
/// given device/session, so the estimate is locked once rather than chased.
///
/// Until a confident estimate exists it returns the reference unchanged
/// (zero delay) — identical to the previous behavior, so it can never make
/// cancellation worse than not aligning at all.
struct EchoReferenceAligner {
    private let maxDelaySamples: Int
    private let correlationWindow: Int
    private let minConfidence: Double
    private let minReferenceRms: Double

    private var estimationSystem: [Float] = []
    private var estimationMicrophone: [Float] = []
    private var delayLine: EchoReferenceDelayLine?

    /// The locked echo delay in samples, or `nil` while still un-estimated.
    private(set) var lockedDelaySamples: Int?

    init(
        sampleRate: Int = 16_000,
        maxDelayMs: Int = 250,
        correlationWindow: Int = 4_000,
        minConfidence: Float = 0.5,
        minReferenceRms: Float = 0.01
    ) {
        self.maxDelaySamples = max(1, sampleRate * max(0, maxDelayMs) / 1_000)
        self.correlationWindow = max(1, correlationWindow)
        self.minConfidence = Double(minConfidence)
        self.minReferenceRms = Double(minReferenceRms)
    }

    mutating func reset() {
        estimationSystem.removeAll(keepingCapacity: true)
        estimationMicrophone.removeAll(keepingCapacity: true)
        delayLine = nil
        lockedDelaySamples = nil
    }

    /// Returns the system reference aligned to the echo in `microphone`. Must be
    /// called on every pair (including silent/solo ones) so the delay line stays
    /// in step with the system timeline — when the far-end falls silent its echo
    /// still lingers in the mic for `delay` samples, and the delay line supplies
    /// exactly that lingering reference.
    mutating func alignedReference(microphone: [Float], system: [Float]) -> [Float] {
        if lockedDelaySamples != nil {
            return delayLine?.process(system) ?? system
        }
        accumulateAndEstimate(microphone: microphone, system: system)
        return system
    }

    private mutating func accumulateAndEstimate(microphone: [Float], system: [Float]) {
        let count = min(microphone.count, system.count)
        guard count > 0 else { return }
        estimationSystem.append(contentsOf: system.prefix(count))
        estimationMicrophone.append(contentsOf: microphone.prefix(count))

        guard estimationSystem.count >= correlationWindow + maxDelaySamples else { return }

        if let delay = estimateDelay() {
            lockedDelaySamples = delay
            delayLine = EchoReferenceDelayLine(delaySamples: delay)
            estimationSystem.removeAll(keepingCapacity: false)
            estimationMicrophone.removeAll(keepingCapacity: false)
        } else {
            // No confident estimate from this window; start fresh so cost stays
            // bounded and a later far-end-dominant stretch gets a clean look.
            estimationSystem.removeAll(keepingCapacity: true)
            estimationMicrophone.removeAll(keepingCapacity: true)
        }
    }

    /// Lag (in samples) of the peak normalized cross-correlation between the
    /// system window and the microphone, or `nil` if the far-end is too quiet or
    /// no lag clears the confidence threshold (e.g. double-talk or silence).
    private func estimateDelay() -> Int? {
        let window = correlationWindow
        var systemEnergy = 0.0
        for index in 0..<window {
            let value = Double(estimationSystem[index])
            systemEnergy += value * value
        }
        guard systemEnergy > 0,
              (systemEnergy / Double(window)).squareRoot() >= minReferenceRms else {
            return nil
        }

        var bestLag = 0
        var bestCorrelation = -1.0
        for lag in 0...maxDelaySamples {
            var dot = 0.0
            var microphoneEnergy = 0.0
            for index in 0..<window {
                let micValue = Double(estimationMicrophone[index + lag])
                dot += Double(estimationSystem[index]) * micValue
                microphoneEnergy += micValue * micValue
            }
            guard microphoneEnergy > 0 else { continue }
            let correlation = dot / (systemEnergy * microphoneEnergy).squareRoot()
            if correlation > bestCorrelation {
                bestCorrelation = correlation
                bestLag = lag
            }
        }

        return bestCorrelation >= minConfidence ? bestLag : nil
    }
}
