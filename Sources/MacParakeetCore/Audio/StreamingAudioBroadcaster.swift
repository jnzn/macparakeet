@preconcurrency import AVFoundation
import Foundation

/// Broadcasts converted 16 kHz mono Float32 audio buffers from an active microphone
/// recording to a subscriber. Used by streaming dictation to feed a live ASR pipeline
/// alongside the existing WAV-file path, without modifying batch capture semantics.
///
/// Single-subscriber per recording session: calling `subscribeToAudioBuffers()` while
/// a prior subscription is active replaces it (the prior stream terminates).
///
/// The returned stream terminates automatically when recording stops. If no recording
/// is in progress when the subscriber starts consuming, the stream stays open and
/// yields buffers once recording begins.
public protocol StreamingAudioBroadcaster: Sendable {
    func subscribeToAudioBuffers() async -> AsyncStream<AVAudioPCMBuffer>
}
