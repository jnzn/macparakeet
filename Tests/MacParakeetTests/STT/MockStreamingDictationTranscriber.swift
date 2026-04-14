@preconcurrency import AVFoundation
import Foundation
@testable import MacParakeetCore

public actor MockStreamingDictationTranscriber: StreamingDictationTranscriber {
    public var loadModelsCallCount = 0
    public var loadError: Error?

    public var startSessionCallCount = 0
    public var startError: Error?

    public var appendCallCount = 0
    public var appendError: Error?
    public var lastAppendedFrameLength: AVAudioFrameCount = 0

    public var finishCallCount = 0
    public var finishError: Error?
    public var finishResult = "mock final transcript"

    public var cancelCallCount = 0
    public var shutdownCallCount = 0

    private var ready = false
    private var partialContinuation: AsyncStream<String>.Continuation?
    private var sessionActive = false

    public init() {}

    public func configureLoadError(_ error: Error?) { loadError = error }
    public func configureStartError(_ error: Error?) { startError = error }
    public func configureAppendError(_ error: Error?) { appendError = error }
    public func configureFinish(result: String, error: Error? = nil) {
        finishResult = result
        finishError = error
    }

    public func emitPartial(_ text: String) {
        partialContinuation?.yield(text)
    }

    public func isSessionActive() -> Bool { sessionActive }

    public func loadModels() async throws {
        loadModelsCallCount += 1
        if let loadError { throw loadError }
        ready = true
    }

    public func isReady() async -> Bool { ready }

    public func startSession() async throws -> AsyncStream<String> {
        startSessionCallCount += 1
        if let startError { throw startError }
        if sessionActive {
            await cancel()
        }
        let (stream, continuation) = AsyncStream<String>.makeStream()
        partialContinuation = continuation
        sessionActive = true
        return stream
    }

    public func appendAudio(_ buffer: AVAudioPCMBuffer) async throws {
        appendCallCount += 1
        lastAppendedFrameLength = buffer.frameLength
        if let appendError { throw appendError }
        guard sessionActive else { throw StreamingDictationError.sessionNotStarted }
    }

    public func finish() async throws -> String {
        finishCallCount += 1
        guard sessionActive else { throw StreamingDictationError.sessionNotStarted }
        partialContinuation?.finish()
        partialContinuation = nil
        sessionActive = false
        if let finishError { throw finishError }
        return finishResult
    }

    public func cancel() async {
        cancelCallCount += 1
        partialContinuation?.finish()
        partialContinuation = nil
        sessionActive = false
    }

    public func shutdown() async {
        shutdownCallCount += 1
        await cancel()
        ready = false
    }

    public var keepAliveCallCount = 0
    public func keepAlive() async {
        keepAliveCallCount += 1
    }
}
