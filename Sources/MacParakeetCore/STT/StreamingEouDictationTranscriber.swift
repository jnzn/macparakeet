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

    private func endSession() {
        partialContinuation?.finish()
        partialContinuation = nil
        sessionActive = false
    }
}
