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
    private let enableVoiceProcessing: Bool

    private var state: LifecycleState = .idle
    private var bufferHandler: AudioBufferHandler?

    public init(enableVoiceProcessing: Bool = false) {
        self.enableVoiceProcessing = enableVoiceProcessing
    }

    var isVoiceProcessingRequested: Bool {
        enableVoiceProcessing
    }

    deinit {
        stop()
    }

    public static var hasPermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    public var inputFormat: AVAudioFormat? {
        do {
            let format = try catchingObjCException {
                audioEngine.inputNode.outputFormat(forBus: 0)
            }
            return format.sampleRate > 0 ? format : nil
        } catch {
            logger.error("Failed to query microphone input format: \(error.localizedDescription, privacy: .public)")
            return nil
        }
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
            state = .starting
            handlerLock.withLock { bufferHandler = handler }
            do {
                if enableVoiceProcessing {
                    do {
                        try catchingObjCException {
                            try inputNode.setVoiceProcessingEnabled(true)
                        }
                    } catch {
                        logger.warning("Voice processing unavailable, falling back to raw capture: \(error.localizedDescription, privacy: .public)")
                    }
                }

                do {
                    try installTapAndStartEngine(inputNode: inputNode)
                } catch {
                    guard enableVoiceProcessing else { throw error }

                    logger.warning("Voice-processing mic start failed, retrying without voice processing: \(error.localizedDescription, privacy: .public)")
                    audioEngine.stop()
                    try? catchingObjCException {
                        inputNode.removeTap(onBus: 0)
                    }
                    try? catchingObjCException {
                        try inputNode.setVoiceProcessingEnabled(false)
                    }
                    try installTapAndStartEngine(inputNode: inputNode)
                }

                state = .running
                didStart = true
            } catch {
                handlerLock.withLock { bufferHandler = nil }
                state = .idle
                if let meetingError = error as? MeetingAudioError {
                    startError = meetingError
                } else {
                    startError = MeetingAudioError.audioEngineStartFailed(error.localizedDescription)
                }
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

            try? catchingObjCException {
                audioEngine.inputNode.removeTap(onBus: 0)
            }
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

    private func installTapAndStartEngine(inputNode: AVAudioInputNode) throws {
        let format: AVAudioFormat
        do {
            format = try catchingObjCException {
                inputNode.outputFormat(forBus: 0)
            }
        } catch {
            throw MeetingAudioError.audioEngineStartFailed(
                "Failed to query microphone format: \(error.localizedDescription)"
            )
        }

        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MeetingAudioError.noMicrophoneAvailable
        }

        do {
            // Use `format: nil` so AVFAudio provides the bus's live format.
            // This avoids aggregate-device format drift crashes.
            try catchingObjCException {
                inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: nil) { [weak self] buffer, time in
                    guard let self,
                          let callback = self.handlerLock.withLock({ self.bufferHandler }) else { return }
                    callback(buffer, time)
                }
            }
        } catch {
            throw MeetingAudioError.audioEngineStartFailed(
                "Failed to install microphone tap: \(error.localizedDescription)"
            )
        }

        do {
            try audioEngine.start()
        } catch {
            try? catchingObjCException {
                inputNode.removeTap(onBus: 0)
            }
            throw MeetingAudioError.audioEngineStartFailed(error.localizedDescription)
        }
    }
}
