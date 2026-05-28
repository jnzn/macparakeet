@preconcurrency import AVFoundation
import XCTest

@testable import MacParakeetCore

final class DictationServiceStreamingTests: XCTestCase {
    var service: DictationService!
    var mockAudio: MockAudioProcessor!
    var mockSTT: MockSTTClient!
    var mockStreaming: MockStreamingDictationTranscriber!
    var dictationRepo: DictationRepository!

    override func setUp() async throws {
        let dbManager = try DatabaseManager()
        mockAudio = MockAudioProcessor()
        mockSTT = MockSTTClient()
        mockStreaming = MockStreamingDictationTranscriber()
        dictationRepo = DictationRepository(dbQueue: dbManager.dbQueue)
    }

    private func makeService(streamingEnabled: Bool) -> DictationService {
        DictationService(
            audioProcessor: mockAudio,
            sttTranscriber: mockSTT,
            dictationRepo: dictationRepo,
            streamingBroadcaster: mockAudio,
            streamingTranscriber: mockStreaming,
            streamingOverlayEnabled: { streamingEnabled }
        )
    }

    private func makeBuffer(frames: AVAudioFrameCount = 1600) throws -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw XCTSkip("Could not allocate PCM buffer")
        }
        buffer.frameLength = frames
        return buffer
    }

    /// Poll-with-timeout helper — used because the streaming session runs on a
    /// background Task and its effects on the mock are observable only after a
    /// few actor hops.
    private func waitFor(
        _ condition: @Sendable () async -> Bool,
        timeoutMs: Int = 2000,
        file: StaticString = #file,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("waitFor timed out after \(timeoutMs)ms", file: file, line: line)
    }

    func test_streamingDisabled_transcriberNotEngaged() async throws {
        service = makeService(streamingEnabled: false)
        try await service.startRecording()

        // Give the background task time to run if it were going to.
        try await Task.sleep(nanoseconds: 50_000_000)

        let loadCount = await mockStreaming.loadModelsCallCount
        let startCount = await mockStreaming.startSessionCallCount
        XCTAssertEqual(loadCount, 0)
        XCTAssertEqual(startCount, 0)
    }

    func test_streamingEnabled_loadsModelAndStartsSession() async throws {
        service = makeService(streamingEnabled: true)
        try await service.startRecording()

        await waitFor { await self.mockStreaming.startSessionCallCount == 1 }
        let loadCount = await mockStreaming.loadModelsCallCount
        XCTAssertEqual(loadCount, 1, "model should be loaded lazily on first session")
    }

    func test_streamingEnabled_forwardsBuffersToTranscriber() async throws {
        service = makeService(streamingEnabled: true)
        try await service.startRecording()
        await waitFor { await self.mockStreaming.startSessionCallCount == 1 }

        let buffer = try makeBuffer(frames: 1600)
        await mockAudio.emitBroadcastBuffer(buffer)

        await waitFor { await self.mockStreaming.appendCallCount >= 1 }
        let frames = await mockStreaming.lastAppendedFrameLength
        XCTAssertEqual(frames, 1600)
    }

    func test_streamingEnabled_stopRecording_finishesSession() async throws {
        await mockSTT.configure(result: STTResult(text: "hello world"))
        service = makeService(streamingEnabled: true)
        try await service.startRecording()
        await waitFor { await self.mockStreaming.startSessionCallCount == 1 }

        _ = try await service.stopRecording()

        // stopCapture on the mock terminates the broadcaster; the streaming task
        // naturally exits and calls finish() on the transcriber.
        await waitFor { await self.mockStreaming.finishCallCount == 1 }
    }

    func test_streamingEnabled_cancelRecording_subsequentStartWorks() async throws {
        // On cancel, the streaming task exits without touching transcriber state
        // (to avoid actor-reentrancy races with a follow-up session). Verify
        // that a subsequent startRecording still produces a working streaming
        // session — which is the behavior that actually matters.
        service = makeService(streamingEnabled: true)
        try await service.startRecording()
        await waitFor { await self.mockStreaming.startSessionCallCount == 1 }

        await service.cancelRecording()

        try await service.startRecording()
        await waitFor { await self.mockStreaming.startSessionCallCount == 2 }

        let buffer = try makeBuffer(frames: 1600)
        await mockAudio.emitBroadcastBuffer(buffer)
        await waitFor { await self.mockStreaming.appendCallCount >= 1 }
    }

    func test_streamingDisabled_stopRecording_neverTouchesTranscriber() async throws {
        await mockSTT.configure(result: STTResult(text: "hello"))
        service = makeService(streamingEnabled: false)

        try await service.startRecording()
        _ = try await service.stopRecording()

        try await Task.sleep(nanoseconds: 50_000_000)
        let starts = await mockStreaming.startSessionCallCount
        let finishes = await mockStreaming.finishCallCount
        let cancels = await mockStreaming.cancelCallCount
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(finishes, 0)
        XCTAssertEqual(cancels, 0)
    }
}
