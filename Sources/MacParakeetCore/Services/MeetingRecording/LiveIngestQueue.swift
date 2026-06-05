import Foundation
import os

/// Decouples the real-time meeting capture-event drain — which must persist
/// recording audio to disk without ever blocking — from the slower live STT/VAD
/// ingest. Resampled sample packets are buffered up to `depth`; under sustained
/// ingest lag the OLDEST packet is dropped (and counted in `droppedCount`) so
/// memory stays bounded across a multi-hour meeting. A single drain task delivers
/// buffered packets to `handler` in FIFO order.
///
/// The authoritative on-disk recording is written upstream of this queue, so a
/// drop here only costs a live-transcription chunk (the full audio remains on
/// disk for re-transcription) — never recorded audio. See
/// `docs/audits/2026-06-04-pdx-subsystems-audit.md` (PDX-001 / PDX-002).
final class LiveIngestQueue: @unchecked Sendable {
    struct Packet: Sendable {
        let samples: [Float]
        let source: AudioSource
        let hostTime: UInt64?
    }

    private let continuation: AsyncStream<Packet>.Continuation
    private let drainTask: Task<Void, Never>
    private let drops = OSAllocatedUnfairLock(initialState: 0)

    init(depth: Int, handler: @escaping @Sendable (Packet) async -> Void) {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Packet.self,
            bufferingPolicy: .bufferingNewest(max(1, depth))
        )
        self.continuation = continuation
        self.drainTask = Task {
            for await packet in stream {
                await handler(packet)
            }
        }
    }

    /// Non-blocking enqueue from the real-time capture consumer. Returns without
    /// waiting; if the bounded buffer is full the oldest queued packet is dropped
    /// and counted. Safe to call from the capture-event drain — it never blocks it.
    func enqueue(_ packet: Packet) {
        if case .dropped = continuation.yield(packet) {
            drops.withLock { $0 += 1 }
        }
    }

    /// Number of packets dropped due to backpressure since creation.
    var droppedCount: Int {
        drops.withLock { $0 }
    }

    /// Stop accepting new packets. The drain task ends once the already-buffered
    /// packets have been delivered.
    func finishInput() {
        continuation.finish()
    }

    /// Await the drain task. Pair with `finishInput()` to flush remaining packets;
    /// bounded only by the per-packet handler cost times the buffered count.
    func awaitDrain() async {
        await drainTask.value
    }

    /// Best-effort interrupt of the drain task (used on teardown timeout). With the
    /// input stream already finished the loop ends after the in-flight handler call.
    func cancelDrain() {
        drainTask.cancel()
    }
}
