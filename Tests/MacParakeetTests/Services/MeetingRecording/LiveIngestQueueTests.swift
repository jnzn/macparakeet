import XCTest
@testable import MacParakeetCore

/// Unit tests for the bounded live STT/VAD ingest queue that decouples the
/// real-time meeting capture-event drain from the slower orchestrator/VAD ingest
/// (audit PDX-001/PDX-002). The capture consumer must never block (so it can keep
/// writing recording audio to disk), and under sustained ingest lag the queue
/// must drop OLDEST packets with a bound rather than grow without limit.
final class LiveIngestQueueTests: XCTestCase {
    func testDeliversPacketsInOrderWhenDrainKeepsUp() async {
        let collector = DeliveredIndices()
        let queue = LiveIngestQueue(depth: 64) { packet in
            await collector.append(Int(packet.samples.first ?? -1))
        }

        for index in 0..<10 {
            queue.enqueue(packet(index))
        }
        queue.finishInput()
        await queue.awaitDrain()

        let delivered = await collector.values()
        XCTAssertEqual(delivered, Array(0..<10))
        XCTAssertEqual(queue.droppedCount, 0)
    }

    func testDropsNothingWhenEnqueuedWithinDepth() async {
        let gate = TestGate()
        // Handler blocks on the first packet so the drain cannot relieve the buffer.
        let queue = LiveIngestQueue(depth: 8) { _ in await gate.wait() }

        for index in 0..<4 {
            queue.enqueue(packet(index))
        }

        XCTAssertEqual(queue.droppedCount, 0)

        gate.open()
        queue.finishInput()
        await queue.awaitDrain()
    }

    func testDropsOldestAndCountsWhenEnqueuedBeyondDepthWithDrainBlocked() async {
        let gate = TestGate()
        let depth = 4
        let queue = LiveIngestQueue(depth: depth) { _ in await gate.wait() }

        let overflow = 50
        for index in 0..<(depth + 1 + overflow) {
            queue.enqueue(packet(index, source: .system))
        }

        // Drain is blocked on the first packet, so at most one packet left the
        // bounded buffer; the rest beyond `depth` must be dropped and counted.
        XCTAssertGreaterThanOrEqual(queue.droppedCount, overflow)

        gate.open()
        queue.finishInput()
        await queue.awaitDrain()
    }

    private func packet(_ index: Int, source: AudioSource = .microphone) -> LiveIngestQueue.Packet {
        LiveIngestQueue.Packet(samples: [Float(index)], source: source, hostTime: nil)
    }
}

private actor DeliveredIndices {
    private var indices: [Int] = []
    func append(_ index: Int) { indices.append(index) }
    func values() -> [Int] { indices }
}

private final class TestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let pending = waiters
        waiters = []
        lock.unlock()
        for continuation in pending {
            continuation.resume()
        }
    }
}
