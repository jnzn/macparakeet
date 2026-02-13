import XCTest
@testable import MacParakeetCore

final class TranscriptContextAssemblerTests: XCTestCase {
    func testAssembleReturnsOriginalWhenUnderLimit() {
        let transcript = "short transcript"
        let assembled = TranscriptContextAssembler.assemble(transcript: transcript, maxCharacters: 500)
        XCTAssertEqual(assembled, transcript)
    }

    func testAssembleTruncatesWithMarkerWhenOverLimit() {
        let transcript = String(repeating: "a", count: 1_000)
        let assembled = TranscriptContextAssembler.assemble(transcript: transcript, maxCharacters: 200)
        XCTAssertLessThanOrEqual(assembled.count, 200)
        XCTAssertTrue(assembled.contains("[...truncated...]"))
    }

    func testChunkCreatesOverlappingSegments() {
        let transcript = String(repeating: "x", count: 1_000)
        let chunks = TranscriptContextAssembler.chunk(transcript: transcript, chunkSize: 300, overlap: 100)

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks[0].count, 300)
        XCTAssertEqual(chunks[1].count, 300)
    }
}
