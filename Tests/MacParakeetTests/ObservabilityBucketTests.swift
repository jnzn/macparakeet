import XCTest
@testable import MacParakeetCore

/// AUDIT-022: exact `wordCount` / `processingSeconds` are fingerprintable on a
/// small cohort, so they're coarsened into range labels before leaving the
/// device. These lock the bucket boundaries.
final class ObservabilityBucketTests: XCTestCase {
    func testWordCountBucketBoundaries() {
        XCTAssertEqual(Observability.wordCountBucket(-3), "none")
        XCTAssertEqual(Observability.wordCountBucket(0), "none")
        XCTAssertEqual(Observability.wordCountBucket(1), "1_9")
        XCTAssertEqual(Observability.wordCountBucket(9), "1_9")
        XCTAssertEqual(Observability.wordCountBucket(10), "10_49")
        XCTAssertEqual(Observability.wordCountBucket(84), "50_99")
        XCTAssertEqual(Observability.wordCountBucket(240), "100_249")
        XCTAssertEqual(Observability.wordCountBucket(499), "250_499")
        XCTAssertEqual(Observability.wordCountBucket(999), "500_999")
        XCTAssertEqual(Observability.wordCountBucket(1000), "gte_1000")
        XCTAssertEqual(Observability.wordCountBucket(50_000), "gte_1000")
    }

    func testProcessingSecondsBucketBoundaries() {
        XCTAssertEqual(Observability.processingSecondsBucket(0), "lt_1s")
        XCTAssertEqual(Observability.processingSecondsBucket(0.99), "lt_1s")
        XCTAssertEqual(Observability.processingSecondsBucket(1), "1_5s")
        XCTAssertEqual(Observability.processingSecondsBucket(12.4), "5_15s")
        XCTAssertEqual(Observability.processingSecondsBucket(29.9), "15_30s")
        XCTAssertEqual(Observability.processingSecondsBucket(30), "30_60s")
        XCTAssertEqual(Observability.processingSecondsBucket(119), "60_120s")
        XCTAssertEqual(Observability.processingSecondsBucket(120), "gte_120s")
        XCTAssertEqual(Observability.processingSecondsBucket(9_999), "gte_120s")
    }
}
