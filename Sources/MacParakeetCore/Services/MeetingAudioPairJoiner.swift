import Foundation

struct MeetingAudioPair: Sendable, Equatable {
    let microphoneSamples: [Float]
    let systemSamples: [Float]
    let microphoneHostTime: UInt64?
    let systemHostTime: UInt64?
    let hasMicrophoneSignal: Bool
    let hasSystemSignal: Bool
}

struct MeetingAudioPairJoiner {
    private struct QueuedSamples {
        let samples: [Float]
        let hostTime: UInt64?
    }

    static let maxLag = 4
    private static let maxLagSamples = 16_000
    private static let maxQueueSize = 30

    private var microphoneQueue: [QueuedSamples] = []
    private var systemQueue: [QueuedSamples] = []
    private var activeSoloSource: AudioSource?

    mutating func reset() {
        microphoneQueue.removeAll(keepingCapacity: true)
        systemQueue.removeAll(keepingCapacity: true)
        activeSoloSource = nil
    }

    mutating func push(samples: [Float], hostTime: UInt64?, source: AudioSource) {
        guard !samples.isEmpty else { return }
        if let activeSoloSource, activeSoloSource != source {
            self.activeSoloSource = nil
        }
        switch source {
        case .microphone:
            microphoneQueue.append(QueuedSamples(samples: samples, hostTime: hostTime))
            trimQueueIfNeeded(&microphoneQueue)
        case .system:
            systemQueue.append(QueuedSamples(samples: samples, hostTime: hostTime))
            trimQueueIfNeeded(&systemQueue)
        }
    }

    mutating func drainPairs() -> [MeetingAudioPair] {
        var pairs: [MeetingAudioPair] = []
        while let pair = popPair() {
            pairs.append(pair)
        }
        return pairs
    }

    mutating func flushRemainingPairs() -> [MeetingAudioPair] {
        var pairs: [MeetingAudioPair] = []
        while let pair = popPairWhenFlushing() {
            pairs.append(pair)
        }
        return pairs
    }

    private mutating func popPair() -> MeetingAudioPair? {
        if let microphone = microphoneQueue.first, let system = systemQueue.first {
            microphoneQueue.removeFirst()
            systemQueue.removeFirst()
            activeSoloSource = nil
            let aligned = Self.align(microphone: microphone.samples, system: system.samples)
            return MeetingAudioPair(
                microphoneSamples: aligned.microphone,
                systemSamples: aligned.system,
                microphoneHostTime: microphone.hostTime,
                systemHostTime: system.hostTime,
                hasMicrophoneSignal: true,
                hasSystemSignal: true
            )
        }

        if let microphone = microphoneQueue.first,
           systemQueue.isEmpty,
           (activeSoloSource == .microphone
            || microphoneQueue.count > Self.maxLag
            || queuedSampleCount(in: microphoneQueue) > Self.maxLagSamples) {
            microphoneQueue.removeFirst()
            activeSoloSource = .microphone
            return MeetingAudioPair(
                microphoneSamples: microphone.samples,
                systemSamples: Array(repeating: 0, count: microphone.samples.count),
                microphoneHostTime: microphone.hostTime,
                systemHostTime: nil,
                hasMicrophoneSignal: true,
                hasSystemSignal: false
            )
        }

        if let system = systemQueue.first,
           microphoneQueue.isEmpty,
           (activeSoloSource == .system
            || systemQueue.count > Self.maxLag
            || queuedSampleCount(in: systemQueue) > Self.maxLagSamples) {
            systemQueue.removeFirst()
            activeSoloSource = .system
            return MeetingAudioPair(
                microphoneSamples: Array(repeating: 0, count: system.samples.count),
                systemSamples: system.samples,
                microphoneHostTime: nil,
                systemHostTime: system.hostTime,
                hasMicrophoneSignal: false,
                hasSystemSignal: true
            )
        }

        return nil
    }

    private mutating func popPairWhenFlushing() -> MeetingAudioPair? {
        if let pair = popPair() {
            return pair
        }

        if let microphone = microphoneQueue.first {
            microphoneQueue.removeFirst()
            activeSoloSource = .microphone
            return MeetingAudioPair(
                microphoneSamples: microphone.samples,
                systemSamples: Array(repeating: 0, count: microphone.samples.count),
                microphoneHostTime: microphone.hostTime,
                systemHostTime: nil,
                hasMicrophoneSignal: true,
                hasSystemSignal: false
            )
        }

        if let system = systemQueue.first {
            systemQueue.removeFirst()
            activeSoloSource = .system
            return MeetingAudioPair(
                microphoneSamples: Array(repeating: 0, count: system.samples.count),
                systemSamples: system.samples,
                microphoneHostTime: nil,
                systemHostTime: system.hostTime,
                hasMicrophoneSignal: false,
                hasSystemSignal: true
            )
        }

        return nil
    }

    private func trimQueueIfNeeded(_ queue: inout [QueuedSamples]) {
        if queue.count > Self.maxQueueSize {
            queue.removeFirst(queue.count - Self.maxQueueSize)
        }
    }

    private func queuedSampleCount(in queue: [QueuedSamples]) -> Int {
        queue.reduce(into: 0) { partialResult, queued in
            partialResult += queued.samples.count
        }
    }

    private static func align(microphone: [Float], system: [Float]) -> (microphone: [Float], system: [Float]) {
        let frameCount = max(microphone.count, system.count)
        guard frameCount > 0 else { return ([], []) }

        var alignedMicrophone = microphone
        var alignedSystem = system
        if alignedMicrophone.count < frameCount {
            alignedMicrophone.append(contentsOf: repeatElement(0, count: frameCount - alignedMicrophone.count))
        }
        if alignedSystem.count < frameCount {
            alignedSystem.append(contentsOf: repeatElement(0, count: frameCount - alignedSystem.count))
        }
        return (alignedMicrophone, alignedSystem)
    }
}
