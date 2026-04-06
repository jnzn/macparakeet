import Foundation
import OSLog
@preconcurrency import AVFoundation

public final class MicrophoneCapture: @unchecked Sendable {
    public typealias AudioBufferHandler = @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    private enum LifecycleState {
        case idle
        case starting
        case running
        case stopping
    }

    private let logger = Logger(subsystem: "com.macparakeet.core", category: "MicrophoneCapture")
    private let lifecycleQueue = DispatchQueue(label: "com.macparakeet.microphonecapture")
    private let handlerLock = NSLock()
    private let audioEngine = AVAudioEngine()
    private let bufferSize: AVAudioFrameCount = 4096

    private var state: LifecycleState = .idle
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
        var startError: Error?
        var didStart = false

        lifecycleQueue.sync {
            guard state == .idle else {
                startError = MeetingAudioError.alreadyRunning
                return
            }

            guard Self.hasPermission else {
                startError = MeetingAudioError.microphonePermissionDenied
                return
            }

            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else {
                startError = MeetingAudioError.noMicrophoneAvailable
                return
            }

            state = .starting
            handlerLock.withLock { bufferHandler = handler }
            inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, time in
                guard let self,
                      let callback = self.handlerLock.withLock({ self.bufferHandler }) else { return }
                callback(buffer, time)
            }

            do {
                try audioEngine.start()
                state = .running
                didStart = true
            } catch {
                inputNode.removeTap(onBus: 0)
                handlerLock.withLock { bufferHandler = nil }
                state = .idle
                startError = MeetingAudioError.audioEngineStartFailed(error.localizedDescription)
            }
        }

        if let startError {
            throw startError
        }
        if didStart {
            logger.info("Microphone capture started")
        }
    }

    public func stop() {
        var didStop = false

        lifecycleQueue.sync {
            guard state != .idle else { return }
            state = .stopping

            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
            handlerLock.withLock {
                bufferHandler = nil
            }
            state = .idle
            didStop = true
        }

        if didStop {
            logger.info("Microphone capture stopped")
        }
    }
}
