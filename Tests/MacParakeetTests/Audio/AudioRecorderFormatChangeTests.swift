import AVFoundation
import XCTest
@testable import MacParakeetCore

final class AudioRecorderFormatChangeTests: XCTestCase {
    func testTapConverterNeedsRebuildWhenNoCachedFormat() throws {
        let incoming = try makeFormat()
        XCTAssertTrue(tapConverterNeedsRebuild(cachedSourceFormat: nil, incomingBufferFormat: incoming))
    }

    func testTapConverterDoesNotNeedRebuildForEquivalentFormat() throws {
        let cached = try makeFormat()
        let incoming = try makeFormat()
        XCTAssertFalse(
            tapConverterNeedsRebuild(cachedSourceFormat: cached, incomingBufferFormat: incoming)
        )
    }

    func testTapConverterNeedsRebuildWhenInterleavingChanges() throws {
        let nonInterleaved = try makeFormat(interleaved: false)
        let interleaved = try makeFormat(interleaved: true)
        XCTAssertTrue(
            tapConverterNeedsRebuild(
                cachedSourceFormat: nonInterleaved,
                incomingBufferFormat: interleaved
            )
        )
    }

    func testTapConverterNeedsRebuildWhenSampleRateChanges() throws {
        let cached = try makeFormat(sampleRate: 48_000)
        let incoming = try makeFormat(sampleRate: 44_100)
        XCTAssertTrue(
            tapConverterNeedsRebuild(cachedSourceFormat: cached, incomingBufferFormat: incoming)
        )
    }

    func testSharedModeStopDuringStartAbortsPendingSubscription() async throws {
        let platform = AudioRecorderBlockingPlatform()
        let stream = SharedMicrophoneStream(platform: platform, bufferSize: 1024)
        let recorder = AudioRecorder(
            sharedStream: stream,
            permissionProvider: { true }
        )
        let arrived = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        platform.configureAndStartHook = {
            arrived.signal()
            release.wait()
        }

        let startTask = Task {
            try await recorder.start()
        }

        XCTAssertEqual(arrived.wait(timeout: .now() + 5), .success)

        do {
            _ = try await recorder.stop()
            XCTFail("stop() should throw while start is still pending")
        } catch AudioProcessorError.recordingFailed(let reason) {
            XCTAssertEqual(reason, "Not recording")
        } catch {
            XCTFail("Unexpected stop error: \(error)")
        }

        release.signal()

        do {
            try await startTask.value
            XCTFail("start() should abort after stop invalidates the pending generation")
        } catch AudioProcessorError.recordingFailed(let reason) {
            XCTAssertEqual(reason, "interrupted during subscribe")
        } catch {
            XCTFail("Unexpected start error: \(error)")
        }

        try await Task.sleep(for: .milliseconds(50))
        let isRecording = await recorder.isRecording
        XCTAssertFalse(isRecording)
        XCTAssertEqual(stream.diagnostics.subscriberCount, 0)
        XCTAssertFalse(stream.diagnostics.engineRunning)
    }

    private func makeFormat(
        sampleRate: Double = 48_000,
        channels: AVAudioChannelCount = 2,
        interleaved: Bool = false
    ) throws -> AVAudioFormat {
        try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: channels,
                interleaved: interleaved
            )
        )
    }
}

private final class AudioRecorderBlockingPlatform: MicrophoneEnginePlatform, @unchecked Sendable {
    private let lock = NSLock()
    private let hookLock = NSLock()
    private var _isRunning = false
    private var _tapHandler: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
    private var _configureAndStartHook: (@Sendable () -> Void)?

    var configureAndStartHook: (@Sendable () -> Void)? {
        get { hookLock.withLock { _configureAndStartHook } }
        set { hookLock.withLock { _configureAndStartHook = newValue } }
    }

    var isEngineRunning: Bool {
        lock.withLock { _isRunning }
    }

    var inputFormat: AVAudioFormat? {
        AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)
    }

    func configureAndStart(
        vpioEnabled: Bool,
        bufferSize: AVAudioFrameCount,
        tapHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) throws {
        configureAndStartHook?()
        lock.withLock {
            _isRunning = true
            _tapHandler = tapHandler
        }
    }

    func stopEngine() {
        lock.withLock {
            _isRunning = false
            _tapHandler = nil
        }
    }
}
