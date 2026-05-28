@preconcurrency import AVFoundation
import XCTest

@testable import MacParakeetCore

final class StreamingDictationTranscriberTests: XCTestCase {
    private func silenceBuffer(frames: AVAudioFrameCount = 1600) throws -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw XCTSkip("Could not allocate PCM buffer")
        }
        buffer.frameLength = frames
        return buffer
    }

    func test_loadModels_marksTranscriberReady() async throws {
        let mock = MockStreamingDictationTranscriber()
        let initiallyReady = await mock.isReady()
        XCTAssertFalse(initiallyReady)

        try await mock.loadModels()

        let ready = await mock.isReady()
        XCTAssertTrue(ready)
        let count = await mock.loadModelsCallCount
        XCTAssertEqual(count, 1)
    }

    func test_loadModels_propagatesError() async throws {
        let mock = MockStreamingDictationTranscriber()
        struct BoomError: Error {}
        await mock.configureLoadError(BoomError())

        do {
            try await mock.loadModels()
            XCTFail("expected load to throw")
        } catch is BoomError {
            let ready = await mock.isReady()
            XCTAssertFalse(ready)
        }
    }

    func test_startSession_returnsStreamYieldingPartials() async throws {
        let mock = MockStreamingDictationTranscriber()
        try await mock.loadModels()
        let stream = try await mock.startSession()

        await mock.emitPartial("hello")
        await mock.emitPartial("hello world")

        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        let second = await iterator.next()

        XCTAssertEqual(first, "hello")
        XCTAssertEqual(second, "hello world")
    }

    func test_finish_terminatesStreamAndReturnsFinalText() async throws {
        let mock = MockStreamingDictationTranscriber()
        try await mock.loadModels()
        let stream = try await mock.startSession()
        await mock.configureFinish(result: "final text")

        await mock.emitPartial("final")
        let final = try await mock.finish()
        XCTAssertEqual(final, "final text")

        var collected: [String] = []
        for await partial in stream {
            collected.append(partial)
        }
        XCTAssertEqual(collected, ["final"])

        let active = await mock.isSessionActive()
        XCTAssertFalse(active)
    }

    func test_cancel_terminatesStreamWithoutReturningFinal() async throws {
        let mock = MockStreamingDictationTranscriber()
        try await mock.loadModels()
        let stream = try await mock.startSession()

        await mock.emitPartial("partial")
        await mock.cancel()

        var collected: [String] = []
        for await partial in stream {
            collected.append(partial)
        }
        XCTAssertEqual(collected, ["partial"])

        let active = await mock.isSessionActive()
        XCTAssertFalse(active)

        let finishCalls = await mock.finishCallCount
        XCTAssertEqual(finishCalls, 0)
    }

    func test_startSession_whileActive_cancelsPriorSession() async throws {
        let mock = MockStreamingDictationTranscriber()
        try await mock.loadModels()
        let firstStream = try await mock.startSession()

        await mock.emitPartial("first")
        let _ = try await mock.startSession()

        var firstCollected: [String] = []
        for await partial in firstStream {
            firstCollected.append(partial)
        }
        XCTAssertEqual(firstCollected, ["first"])

        let cancels = await mock.cancelCallCount
        XCTAssertEqual(cancels, 1)
        let starts = await mock.startSessionCallCount
        XCTAssertEqual(starts, 2)
    }

    func test_appendAudio_withoutSession_throws() async throws {
        let mock = MockStreamingDictationTranscriber()
        try await mock.loadModels()
        let buffer = try silenceBuffer()

        do {
            try await mock.appendAudio(buffer)
            XCTFail("expected throw")
        } catch let error as StreamingDictationError {
            XCTAssertEqual(error, .sessionNotStarted)
        }
    }

    func test_finish_withoutSession_throws() async throws {
        let mock = MockStreamingDictationTranscriber()
        try await mock.loadModels()

        do {
            _ = try await mock.finish()
            XCTFail("expected throw")
        } catch let error as StreamingDictationError {
            XCTAssertEqual(error, .sessionNotStarted)
        }
    }

    func test_appendAudio_recordsFrameLength() async throws {
        let mock = MockStreamingDictationTranscriber()
        try await mock.loadModels()
        _ = try await mock.startSession()
        let buffer = try silenceBuffer(frames: 800)

        try await mock.appendAudio(buffer)

        let calls = await mock.appendCallCount
        XCTAssertEqual(calls, 1)
        let frames = await mock.lastAppendedFrameLength
        XCTAssertEqual(frames, 800)
    }

    func test_shutdown_clearsReadyState() async throws {
        let mock = MockStreamingDictationTranscriber()
        try await mock.loadModels()
        _ = try await mock.startSession()

        await mock.shutdown()

        let ready = await mock.isReady()
        XCTAssertFalse(ready)
        let active = await mock.isSessionActive()
        XCTAssertFalse(active)
        let shutdowns = await mock.shutdownCallCount
        XCTAssertEqual(shutdowns, 1)
    }
}
