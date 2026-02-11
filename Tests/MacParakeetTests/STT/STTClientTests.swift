import XCTest
@testable import MacParakeetCore

final class STTClientTests: XCTestCase {

    func testSTTResultCreation() {
        let words = [
            TimestampedWord(word: "Hello", startMs: 0, endMs: 500, confidence: 0.98),
            TimestampedWord(word: "world", startMs: 520, endMs: 1000, confidence: 0.95),
        ]
        let result = STTResult(text: "Hello world", words: words)

        XCTAssertEqual(result.text, "Hello world")
        XCTAssertEqual(result.words.count, 2)
        XCTAssertEqual(result.words[0].word, "Hello")
        XCTAssertEqual(result.words[1].startMs, 520)
    }

    func testSTTResultEmptyWords() {
        let result = STTResult(text: "Hello")
        XCTAssertEqual(result.text, "Hello")
        XCTAssertTrue(result.words.isEmpty)
    }

    func testSTTErrorDescriptions() {
        XCTAssertNotNil(STTError.daemonNotRunning.errorDescription)
        XCTAssertNotNil(STTError.timeout.errorDescription)
        XCTAssertNotNil(STTError.modelNotLoaded.errorDescription)
        XCTAssertNotNil(STTError.outOfMemory.errorDescription)
        XCTAssertNotNil(STTError.invalidResponse.errorDescription)
        XCTAssertNotNil(STTError.transcriptionFailed("test").errorDescription)
        XCTAssertNotNil(STTError.daemonStartFailed("test").errorDescription)
    }

    func testMockSTTClientTranscribe() async throws {
        let mock = MockSTTClient()
        let expectedResult = STTResult(text: "Hello from mock")
        await mock.configure(result: expectedResult)

        let result = try await mock.transcribe(audioPath: "/tmp/test.wav")
        XCTAssertEqual(result.text, "Hello from mock")

        let callCount = await mock.transcribeCallCount
        XCTAssertEqual(callCount, 1)

        let lastPath = await mock.lastAudioPath
        XCTAssertEqual(lastPath, "/tmp/test.wav")
    }

    func testMockSTTClientError() async {
        let mock = MockSTTClient()
        await mock.configure(error: STTError.transcriptionFailed("test error"))

        do {
            _ = try await mock.transcribe(audioPath: "/tmp/test.wav")
            XCTFail("Should have thrown")
        } catch let error as STTError {
            if case .transcriptionFailed(let reason) = error {
                XCTAssertEqual(reason, "test error")
            } else {
                XCTFail("Wrong error type")
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testMockSTTClientWarmUp() async throws {
        let mock = MockSTTClient()
        try await mock.warmUp()
        let called = await mock.warmUpCalled
        XCTAssertTrue(called)
    }

    func testMockSTTClientShutdown() async {
        let mock = MockSTTClient()
        await mock.shutdown()
        let called = await mock.shutdownCalled
        XCTAssertTrue(called)
    }

    func testConsumeProgressUpdatesHandlesSplitChunks() {
        var buffer = Data()

        let first = STTClient.consumeProgressUpdates(
            from: &buffer,
            appending: Data("PROGRESS:1/10\nPRO".utf8)
        )
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].0, 1)
        XCTAssertEqual(first[0].1, 10)

        let second = STTClient.consumeProgressUpdates(
            from: &buffer,
            appending: Data("GRESS:2/10\n".utf8)
        )
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second[0].0, 2)
        XCTAssertEqual(second[0].1, 10)
    }

    func testConsumeProgressUpdatesIgnoresMalformedLines() {
        var buffer = Data()

        let updates = STTClient.consumeProgressUpdates(
            from: &buffer,
            appending: Data("INFO:start\nPROGRESS:bad\nPROGRESS:3/12\n".utf8)
        )

        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates[0].0, 3)
        XCTAssertEqual(updates[0].1, 12)
    }

    func testConsumeProgressUpdatesCanFlushTrailingLine() {
        var buffer = Data()

        let first = STTClient.consumeProgressUpdates(
            from: &buffer,
            appending: Data("PROGRESS:4/20".utf8)
        )
        XCTAssertTrue(first.isEmpty)

        let flushed = STTClient.consumeProgressUpdates(
            from: &buffer,
            appending: Data(),
            consumeTrailingLine: true
        )
        XCTAssertEqual(flushed.count, 1)
        XCTAssertEqual(flushed[0].0, 4)
        XCTAssertEqual(flushed[0].1, 20)
    }
}
