import XCTest
@testable import MacParakeetCore

final class AudioChunkerTests: XCTestCase {
    func testEmitsFiveSecondChunkAndRetainsOneSecondOverlap() async {
        let chunker = AudioChunker()
        let samples = [Float](repeating: 0.25, count: 80_000)

        let firstChunk = await chunker.addSamples(samples)
        let bufferSampleCount = await chunker.bufferSampleCount
        let currentPositionMs = await chunker.currentPositionMs

        XCTAssertNotNil(firstChunk)
        XCTAssertEqual(firstChunk?.samples.count, 80_000)
        XCTAssertEqual(firstChunk?.startMs, 0)
        XCTAssertEqual(firstChunk?.endMs, 5_000)
        XCTAssertEqual(bufferSampleCount, 16_000)
        XCTAssertEqual(currentPositionMs, 4_000)
    }

    func testFlushReturnsRemainingAudioAboveMinimumThreshold() async {
        let chunker = AudioChunker()
        _ = await chunker.addSamples([Float](repeating: 0.1, count: 80_000))

        let flushed = await chunker.flush()

        XCTAssertNotNil(flushed)
        XCTAssertEqual(flushed?.samples.count, 16_000)
        XCTAssertEqual(flushed?.startMs, 4_000)
        XCTAssertEqual(flushed?.endMs, 5_000)
    }

    func testFlushDropsTinyTail() async {
        let chunker = AudioChunker()

        let flushed = await chunker.addSamples([Float](repeating: 0.1, count: 4_000))

        let finalFlush = await chunker.flush()

        XCTAssertNil(flushed)
        XCTAssertNil(finalFlush)
    }

    func testResampleDownsamplesTo16kHz() {
        let input = Array(0..<48_000).map(Float.init)

        let output = AudioChunker.resample(samples: input, fromRate: 48_000, toRate: 16_000)

        XCTAssertEqual(output.count, 16_000)
    }
}
