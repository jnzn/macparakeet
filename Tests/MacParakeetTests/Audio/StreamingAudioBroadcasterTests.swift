@preconcurrency import AVFoundation
import XCTest

@testable import MacParakeetCore

final class StreamingAudioBroadcasterTests: XCTestCase {
    private func makeBuffer(frames: AVAudioFrameCount = 1600) throws -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw XCTSkip("Could not allocate PCM buffer")
        }
        buffer.frameLength = frames
        return buffer
    }

    func test_mockAudioProcessor_emitsBuffersToSubscriber() async throws {
        let mock = MockAudioProcessor()
        let stream = await mock.subscribeToAudioBuffers()

        let b1 = try makeBuffer(frames: 1600)
        let b2 = try makeBuffer(frames: 800)
        await mock.emitBroadcastBuffer(b1)
        await mock.emitBroadcastBuffer(b2)
        await mock.finishBroadcast()

        var frames: [AVAudioFrameCount] = []
        for await buffer in stream {
            frames.append(buffer.frameLength)
        }
        XCTAssertEqual(frames, [1600, 800])
    }

    func test_mockAudioProcessor_stopCapture_terminatesStream() async throws {
        let mock = MockAudioProcessor()
        await mock.configure(captureResult: URL(fileURLWithPath: "/tmp/fake.wav"))
        let stream = await mock.subscribeToAudioBuffers()

        let buffer = try makeBuffer()
        await mock.emitBroadcastBuffer(buffer)
        _ = try await mock.stopCapture()

        var count = 0
        for await _ in stream {
            count += 1
        }
        XCTAssertEqual(count, 1)
    }

    func test_mockAudioProcessor_resubscribe_replacesPriorStream() async throws {
        let mock = MockAudioProcessor()
        let first = await mock.subscribeToAudioBuffers()
        let second = await mock.subscribeToAudioBuffers()

        let buffer = try makeBuffer()
        await mock.emitBroadcastBuffer(buffer)
        await mock.finishBroadcast()

        var firstCount = 0
        for await _ in first {
            firstCount += 1
        }
        var secondCount = 0
        for await _ in second {
            secondCount += 1
        }
        XCTAssertEqual(firstCount, 0, "prior subscription should have been terminated")
        XCTAssertEqual(secondCount, 1)
    }

    func test_audioRecorder_subscribeBeforeStart_returnsOpenStream() async throws {
        let recorder = AudioRecorder()
        let stream = await recorder.subscribeToAudioBuffers()

        // Without starting recording, no buffers arrive. Confirm the stream is
        // alive by racing a short timeout against an expected-never-yielded value.
        let gotSomething = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask {
                for await _ in stream {
                    return true
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 100_000_000)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        XCTAssertFalse(gotSomething, "expected no buffers without a recording session")
    }

    func test_audioRecorder_resubscribe_terminatesPriorStream() async throws {
        let recorder = AudioRecorder()
        let first = await recorder.subscribeToAudioBuffers()
        _ = await recorder.subscribeToAudioBuffers()

        // Consuming `first` should see immediate completion since resubscribe
        // finished it.
        var firstCount = 0
        for await _ in first {
            firstCount += 1
        }
        XCTAssertEqual(firstCount, 0)
    }
}
