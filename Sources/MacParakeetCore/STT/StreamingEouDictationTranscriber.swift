@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import os

/// Concrete `StreamingDictationTranscriber` backed by FluidAudio's Parakeet EOU
/// streaming model. Wraps a `StreamingAsrManager` actor and adapts its callback-based
/// partial-transcript API into an `AsyncStream<String>` for Swift-idiomatic consumption.
public actor StreamingEouDictationTranscriber: StreamingDictationTranscriber {
    private let variant: StreamingModelVariant
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "StreamingEouDictation")

    private var manager: (any StreamingAsrManager)?
    private var partialContinuation: AsyncStream<String>.Continuation?
    private var sessionActive = false

    public init(variant: StreamingModelVariant = .parakeetEou160ms) {
        precondition(
            variant.engineFamily == .parakeetEou,
            "StreamingEouDictationTranscriber requires a Parakeet EOU variant"
        )
        self.variant = variant
    }

    public func loadModels() async throws {
        if manager != nil { return }
        let m = variant.createManager()
        do {
            try await m.loadModels()
            self.manager = m
            logger.info("Loaded streaming model: \(self.variant.displayName, privacy: .public)")
        } catch {
            throw StreamingDictationError.modelLoadFailed(error.localizedDescription)
        }
    }

    public func isReady() async -> Bool {
        manager != nil
    }

    public func startSession() async throws -> AsyncStream<String> {
        guard let manager else {
            throw StreamingDictationError.modelNotLoaded
        }
        if sessionActive {
            await cancel()
        }

        try await manager.reset()

        let (stream, continuation) = AsyncStream<String>.makeStream()
        self.partialContinuation = continuation

        await manager.setPartialTranscriptCallback { partial in
            continuation.yield(partial)
        }

        sessionActive = true
        return stream
    }

    public func appendAudio(_ buffer: AVAudioPCMBuffer) async throws {
        guard sessionActive, let manager else {
            throw StreamingDictationError.sessionNotStarted
        }
        do {
            try await manager.appendAudio(buffer)
            try await manager.processBufferedAudio()
        } catch {
            throw StreamingDictationError.transcriptionFailed(error.localizedDescription)
        }
    }

    public func finish() async throws -> String {
        guard sessionActive, let manager else {
            throw StreamingDictationError.sessionNotStarted
        }
        let finalText: String
        do {
            finalText = try await manager.finish()
        } catch {
            endSession()
            throw StreamingDictationError.transcriptionFailed(error.localizedDescription)
        }
        endSession()
        return finalText
    }

    public func cancel() async {
        guard sessionActive else { return }
        endSession()
        try? await manager?.reset()
    }

    public func shutdown() async {
        await cancel()
        await manager?.cleanup()
        manager = nil
    }

    public func keepAlive() async {
        // Only ping when loaded and idle. If a session is active, live dictation
        // is already keeping the model warm; interfering would mangle its state.
        guard let manager, !sessionActive else { return }
        do {
            // 1 s of silence at 16 kHz mono Float32. process() runs the full
            // encoder + decoder path on the silence, which is what keeps the
            // ANE context resident. We reset() afterward so no residual
            // buffer state leaks into the next real session.
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
            let frames: AVAudioFrameCount = 16000
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
            buffer.frameLength = frames
            // Buffer allocated fresh; channel data defaults to zeros. Skip explicit zeroing.
            try await manager.appendAudio(buffer)
            try await manager.processBufferedAudio()
            try await manager.reset()
            logger.debug("streaming_keep_alive_pinged")
        } catch {
            logger.warning("streaming_keep_alive_failed error=\(error.localizedDescription, privacy: .private)")
        }
    }

    private func endSession() {
        partialContinuation?.finish()
        partialContinuation = nil
        sessionActive = false
    }
}
