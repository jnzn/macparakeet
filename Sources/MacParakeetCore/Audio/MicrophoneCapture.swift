import Foundation
import OSLog
@preconcurrency import AVFoundation

public final class MicrophoneCapture: @unchecked Sendable {
    public typealias AudioBufferHandler = @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void

    private let logger = Logger(subsystem: "com.macparakeet.core", category: "MicrophoneCapture")
    private let lock = NSLock()
    private let audioEngine = AVAudioEngine()
    private let bufferSize: AVAudioFrameCount = 4096

    private var isRunning = false
    private var bufferHandler: AudioBufferHandler?

    public init() {}

    deinit {
        stop()
    }

    public static var hasPermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    public var inputFormat: AVAudioFormat? {
        let format = audioEngine.inputNode.outputFormat(forBus: 0)
        return format.sampleRate > 0 ? format : nil
    }

    public func start(handler: @escaping AudioBufferHandler) throws {
        guard !lock.withLock({ isRunning }) else {
            throw MeetingAudioError.alreadyRunning
        }

        guard Self.hasPermission else {
            throw MeetingAudioError.microphonePermissionDenied
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw MeetingAudioError.noMicrophoneAvailable
        }

        lock.withLock { bufferHandler = handler }
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, time in
            guard let self,
                  let callback = self.lock.withLock({ self.bufferHandler }) else { return }
            callback(buffer, time)
        }

        do {
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            lock.withLock { bufferHandler = nil }
            throw MeetingAudioError.audioEngineStartFailed(error.localizedDescription)
        }

        lock.withLock { isRunning = true }
        logger.info("Microphone capture started")
    }

    public func stop() {
        guard lock.withLock({ isRunning }) else { return }

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        lock.withLock {
            bufferHandler = nil
            isRunning = false
        }
        logger.info("Microphone capture stopped")
    }
}
