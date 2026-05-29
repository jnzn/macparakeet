import AVFoundation
import CoreAudio
import Foundation
import os

/// Abstract surface that `SharedMicrophoneStream` uses to drive real
/// `AVAudioEngine` operations. Splitting it out lets unit tests exercise the
/// stream's state machine and fan-out under a deterministic mock, while the
/// production adapter handles the Core Audio side.
///
/// Implementations must serialize concurrent calls. `SharedMicrophoneStream`
/// also serializes via its own engine queue, so platform implementations may
/// rely on that — but they must remain reentrancy-safe (e.g. handle a stop
/// during a partially-failed start).
public protocol MicrophoneEnginePlatform: AnyObject, Sendable {
    /// True between a successful `configureAndStart` and the next
    /// `stopEngine`. Implementations may also set this to `false` if the
    /// engine fails post-start.
    var isEngineRunning: Bool { get }

    /// Live input format reported by the running engine, or `nil` if the
    /// engine is not running or its format is invalid.
    var inputFormat: AVAudioFormat? { get }

    /// Idempotent start. Stops any existing engine and rebuilds it with the
    /// requested VPIO mode. Installs `tapHandler` as the buffer callback;
    /// the handler runs on the audio render thread.
    ///
    /// - Important: The buffer passed to `tapHandler` is valid only for the
    ///   synchronous duration of the call. Implementations must not retain
    ///   the buffer past return.
    func configureAndStart(
        vpioEnabled: Bool,
        bufferSize: AVAudioFrameCount,
        tapHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) throws

    /// Stop the engine, remove the tap, and tear down VPIO. Recreates the
    /// underlying `AVAudioEngine` so coreaudiod releases the VPAU aggregate
    /// (`CADefaultDeviceAggregate-<pid>-N`). Mirrors the ephemeral-engine
    /// pattern proven in `MicrophoneCapture` (PR #186).
    func stopEngine()
}

/// Production adapter that drives a real `AVAudioEngine`. Mirrors the
/// engine-lifecycle invariants from `MicrophoneCapture` (PR #186):
///
/// - VPIO ducking is suppressed so other apps' audio isn't ~50% attenuated.
/// - The engine is destroyed and recreated on stop so coreaudiod releases
///   the VPAU aggregate device. A long-lived engine keeps the VPAU alive
///   indefinitely, which inherits the duplex layout into other engines.
/// - When configured with a `deviceAttemptsBuilder`, each `configureAndStart`
///   walks the resolved attempt list (selected → implicit systemDefault →
///   builtIn) and recreates the engine on every failed attempt before trying
///   the next — the same fallback shape `MicrophoneCapture` uses today.
public final class AVAudioEngineMicrophonePlatform: MicrophoneEnginePlatform, @unchecked Sendable {
    public typealias DeviceAttemptsBuilder = @Sendable () -> [MeetingInputDeviceAttempt]
    public typealias InputDeviceSetter = @Sendable (AudioDeviceID, AVAudioEngine) -> Bool
    typealias EngineStarter = @Sendable (
        AVAudioEngine,
        Bool,
        AVAudioFrameCount,
        @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) throws -> Void

    private let logger = Logger(
        subsystem: "com.macparakeet.core",
        category: "AVAudioEngineMicrophonePlatform"
    )
    private let queue = DispatchQueue(label: "com.macparakeet.shared-mic-platform")
    private let defaultInputListenerQueue = DispatchQueue(
        label: "com.macparakeet.shared-mic-platform.default-input-listener"
    )
    private let deviceAttemptsBuilder: DeviceAttemptsBuilder?
    private let inputDeviceSetter: InputDeviceSetter
    private let engineStarter: EngineStarter?
    private var audioEngine = AVAudioEngine()
    private var running: Bool = false
    private var lastSucceededAttemptLocked: MeetingInputDeviceAttempt?
    /// Token for the `AVAudioEngine.configurationChangeNotification` observer
    /// installed on the current `audioEngine` instance. Cleared on
    /// `tearDown` / `resetEngine` / `replaceEngineAfterFailure` so the
    /// next instance gets its own observer. Recorded here purely to
    /// surface the signal in `dictation-audio.log` — Core Audio sends
    /// this when the input chain reconfigures (default-input change,
    /// format change, sample-rate change), which is the most likely
    /// trigger for the silent tap-stall under investigation.
    private var configurationChangeObserver: NSObjectProtocol?
    private var defaultInputChangeObserver: AudioObjectPropertyListenerBlock?

    // MARK: Stall recovery
    //
    // macOS AVAudioEngine input start is racy: `engine.start()` can return
    // success and post a configuration change, yet the IO proc never begins
    // pulling buffers — the tap stays silent for the whole session (observed as
    // `dictation_capture_no_buffers_within_timeout` with input_buffers=0). It
    // self-heals on a later start anywhere from seconds to ~30s later. When a
    // configuration change is followed by no buffers within a short window, we
    // re-prime the engine with the last good params and retry (bounded), which
    // recovers the common quick-flake case within a few hundred ms.

    /// Params from the last user-initiated `configureAndStart`, replayed during
    /// stall recovery. Set on success, cleared on stop/teardown.
    private var rememberedStart: (vpioEnabled: Bool, bufferSize: AVAudioFrameCount, tapHandler: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
    /// Set true by the (wrapped) tap handler on the render thread; read on the
    /// engine queue by the stall watchdog. Reset when a watchdog window opens.
    private let sawBufferSinceCheck = OSAllocatedUnfairLock(initialState: false)
    /// Recovery attempts since the last user-initiated start. Reset to 0 once a
    /// buffer is confirmed flowing, or on the next `configureAndStart`.
    private var stallRecoveryAttempts = 0
    private static let maxStallRecoveryAttempts = 3
    private static let stallCheckDelaySeconds: TimeInterval = 0.3

    public init(
        deviceAttemptsBuilder: DeviceAttemptsBuilder? = nil,
        inputDeviceSetter: @escaping InputDeviceSetter = { deviceID, engine in
            AudioDeviceManager.setInputDevice(deviceID, on: engine)
        }
    ) {
        self.deviceAttemptsBuilder = deviceAttemptsBuilder
        self.inputDeviceSetter = inputDeviceSetter
        self.engineStarter = nil
    }

    init(
        deviceAttemptsBuilder: DeviceAttemptsBuilder? = nil,
        inputDeviceSetter: @escaping InputDeviceSetter = { deviceID, engine in
            AudioDeviceManager.setInputDevice(deviceID, on: engine)
        },
        engineStarter: @escaping EngineStarter
    ) {
        self.deviceAttemptsBuilder = deviceAttemptsBuilder
        self.inputDeviceSetter = inputDeviceSetter
        self.engineStarter = engineStarter
    }

    public var isEngineRunning: Bool {
        // Must not be called from the platform's own queue — `queue.sync`
        // would deadlock. Caller is expected to be on a different queue
        // (typically `SharedMicrophoneStream.engineQueue` or a UI thread).
        dispatchPrecondition(condition: .notOnQueue(queue))
        return queue.sync { running }
    }

    public var inputFormat: AVAudioFormat? {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return queue.sync {
            guard running else { return nil }
            do {
                let format = try catchingObjCException {
                    audioEngine.inputNode.outputFormat(forBus: 0)
                }
                return format.sampleRate > 0 && format.channelCount > 0 ? format : nil
            } catch {
                let errorType = AudioCaptureDiagnostics.errorType(error)
                logger.error(
                    "shared_mic_engine_input_format_failed error_type=\(errorType, privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)"
                )
                AudioCaptureDiagnostics.append(
                    "shared_mic_engine_input_format_failed \(AudioCaptureDiagnostics.errorFields(error))"
                )
                return nil
            }
        }
    }

    /// The device attempt that produced the most recent successful start, or
    /// `nil` if no `deviceAttemptsBuilder` was configured (the engine used
    /// whatever device the system chose) or the platform is not running.
    public var lastSucceededAttempt: MeetingInputDeviceAttempt? {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return queue.sync { running ? lastSucceededAttemptLocked : nil }
    }

    public func configureAndStart(
        vpioEnabled: Bool,
        bufferSize: AVAudioFrameCount,
        tapHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) throws {
        try queue.sync {
            // User-initiated start: this is the authoritative param set the
            // stall watchdog replays, and a fresh recovery budget.
            rememberedStart = (vpioEnabled, bufferSize, tapHandler)
            stallRecoveryAttempts = 0
            try performConfigureAndStartLocked(
                vpioEnabled: vpioEnabled,
                bufferSize: bufferSize,
                tapHandler: tapHandler
            )
        }
    }

    /// Queue-held body of `configureAndStart`. Also invoked (already on
    /// `queue`) by the stall watchdog to re-prime after a silent start.
    private func performConfigureAndStartLocked(
        vpioEnabled: Bool,
        bufferSize: AVAudioFrameCount,
        tapHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) throws {
            // VPIO toggle requires a stop → setVoiceProcessingEnabled → start
            // sequence; the engine cannot be reconfigured while running.
            if running {
                tearDownLocked()
            }

            let attempts = deviceAttemptsBuilder?() ?? []
            if attempts.isEmpty {
                // No device chain — use whatever the engine's input node picks.
                try startConfiguredEngineLocked(
                    vpioEnabled: vpioEnabled,
                    bufferSize: bufferSize,
                    tapHandler: tapHandler
                )
                lastSucceededAttemptLocked = nil
                return
            }

            var lastError: Error?
            for attempt in attempts {
                let transport = AudioCaptureDiagnostics.deviceTransportLabel(attempt.deviceID)
                let deviceLabel = AudioCaptureDiagnostics.deviceLabel(attempt.deviceID)
                if let deviceID = attempt.explicitDeviceID {
                    guard inputDeviceSetter(deviceID, audioEngine) else {
                        logger.warning(
                            "shared_mic_engine_input_device_set_failed source=\(attempt.source.logValue, privacy: .public) transport=\(transport, privacy: .public)"
                        )
                        AudioCaptureDiagnostics.append(
                            "shared_mic_engine_input_device_set_failed source=\(attempt.source.logValue) device=\(deviceLabel) transport=\(transport)"
                        )
                        if lastError == nil {
                            lastError = AVAudioEngineMicrophonePlatformError.deviceSetFailed(attempt)
                        }
                        resetEngineLocked()
                        continue
                    }
                }

                do {
                    try startConfiguredEngineLocked(
                        vpioEnabled: vpioEnabled,
                        bufferSize: bufferSize,
                        tapHandler: tapHandler
                    )
                    lastSucceededAttemptLocked = attempt
                    logger.info(
                        "shared_mic_engine_input_device_started source=\(attempt.source.logValue, privacy: .public) transport=\(transport, privacy: .public) vpio=\(vpioEnabled, privacy: .public)"
                    )
                    AudioCaptureDiagnostics.append(
                        "shared_mic_engine_input_device_started source=\(attempt.source.logValue) device=\(deviceLabel) transport=\(transport) vpio=\(vpioEnabled)"
                    )
                    return
                } catch {
                    lastError = error
                    let errorType = AudioCaptureDiagnostics.errorType(error)
                    logger.warning(
                        "shared_mic_engine_input_device_start_failed source=\(attempt.source.logValue, privacy: .public) transport=\(transport, privacy: .public) error_type=\(errorType, privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)"
                    )
                    AudioCaptureDiagnostics.append(
                        "shared_mic_engine_input_device_start_failed source=\(attempt.source.logValue) device=\(deviceLabel) transport=\(transport) \(AudioCaptureDiagnostics.errorFields(error))"
                    )
                    // startConfiguredEngineLocked already replaces the engine on
                    // failure, so nothing more to reset here.
                }
            }

            throw lastError ?? AVAudioEngineMicrophonePlatformError.noDeviceAvailable
    }

    public func stopEngine() {
        queue.sync {
            guard running else { return }
            tearDownLocked()
            // User-initiated stop: drop the replay params + recovery budget so a
            // late stall watchdog can't re-prime a deliberately-stopped engine.
            rememberedStart = nil
            stallRecoveryAttempts = 0
            logger.info("shared_mic_engine_stopped")
            AudioCaptureDiagnostics.append("shared_mic_engine_stopped")
        }
    }

    // MARK: - Stall recovery (queue-held)

    /// Open a watchdog window after a configuration change: if no buffer is
    /// observed within `stallCheckDelaySeconds`, the input start silently
    /// stalled — re-prime with the remembered params and retry (bounded).
    /// Called from the configuration-change observer (already on `queue`).
    private func scheduleStallCheckLocked() {
        guard running, rememberedStart != nil else { return }
        sawBufferSinceCheck.withLock { $0 = false }
        queue.asyncAfter(deadline: .now() + Self.stallCheckDelaySeconds) { [weak self] in
            self?.evaluateStallLocked()
        }
    }

    /// Queue-held. Either confirms buffers are flowing (resets the budget) or
    /// re-primes the engine once, up to `maxStallRecoveryAttempts`.
    private func evaluateStallLocked() {
        guard running, let remembered = rememberedStart else { return }
        if sawBufferSinceCheck.withLock({ $0 }) {
            stallRecoveryAttempts = 0 // healthy — buffers are flowing
            return
        }
        guard stallRecoveryAttempts < Self.maxStallRecoveryAttempts else {
            logger.error("shared_mic_engine_stall_recovery_exhausted attempts=\(self.stallRecoveryAttempts, privacy: .public)")
            AudioCaptureDiagnostics.append(
                "shared_mic_engine_stall_recovery_exhausted attempts=\(stallRecoveryAttempts)"
            )
            return
        }
        stallRecoveryAttempts += 1
        logger.info("shared_mic_engine_stall_recovery attempt=\(self.stallRecoveryAttempts, privacy: .public)")
        AudioCaptureDiagnostics.append(
            "shared_mic_engine_stall_recovery attempt=\(stallRecoveryAttempts)"
        )
        // Re-prime: tearDownLocked recreates the engine + removes the old
        // observer; performConfigureAndStartLocked installs a fresh engine,
        // tap, and config-change observer (which re-arms this watchdog).
        tearDownLocked()
        do {
            try performConfigureAndStartLocked(
                vpioEnabled: remembered.vpioEnabled,
                bufferSize: remembered.bufferSize,
                tapHandler: remembered.tapHandler
            )
        } catch {
            logger.error(
                "shared_mic_engine_stall_recovery_failed error_type=\(AudioCaptureDiagnostics.errorType(error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)"
            )
            AudioCaptureDiagnostics.append(
                "shared_mic_engine_stall_recovery_failed \(AudioCaptureDiagnostics.errorFields(error))"
            )
        }
    }

    // MARK: - Internals (queue-held)

    private func startConfiguredEngineLocked(
        vpioEnabled: Bool,
        bufferSize: AVAudioFrameCount,
        tapHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) throws {
        guard let engineStarter else {
            try startEngineLocked(
                vpioEnabled: vpioEnabled,
                bufferSize: bufferSize,
                tapHandler: tapHandler
            )
            return
        }

        do {
            try engineStarter(audioEngine, vpioEnabled, bufferSize, tapHandler)
        } catch {
            replaceEngineAfterFailureLocked()
            throw error
        }
        running = true
        installConfigurationChangeObserverLocked()
    }

    private func startEngineLocked(
        vpioEnabled: Bool,
        bufferSize: AVAudioFrameCount,
        tapHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) throws {
        let inputNode = audioEngine.inputNode
        do {
            try catchingObjCException {
                try inputNode.setVoiceProcessingEnabled(vpioEnabled)
            }
        } catch {
            // VPIO toggle failed before tap install / engine start. Replace
            // the engine so the next attempt isn't on a half-configured one.
            replaceEngineAfterFailureLocked()
            throw error
        }
        if vpioEnabled, #available(macOS 14.0, *) {
            do {
                try catchingObjCException {
                    inputNode.voiceProcessingOtherAudioDuckingConfiguration = .init(
                        enableAdvancedDucking: false,
                        duckingLevel: .min
                    )
                }
            } catch {
                let errorType = AudioCaptureDiagnostics.errorType(error)
                logger.debug(
                    "shared_mic_engine_ducking_config_failed error_type=\(errorType, privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)"
                )
            }
        }

        let liveFormat: AVAudioFormat
        do {
            liveFormat = try catchingObjCException {
                inputNode.outputFormat(forBus: 0)
            }
        } catch {
            replaceEngineAfterFailureLocked()
            throw error
        }
        guard liveFormat.sampleRate > 0, liveFormat.channelCount > 0 else {
            replaceEngineAfterFailureLocked()
            throw AVAudioEngineMicrophonePlatformError.invalidInputFormat(
                sampleRate: liveFormat.sampleRate,
                channels: liveFormat.channelCount
            )
        }

        do {
            try catchingObjCException {
                inputNode.installTap(
                    onBus: 0,
                    bufferSize: bufferSize,
                    format: nil
                ) { [weak self] buffer, time in
                    // Record liveness for the stall watchdog before forwarding.
                    self?.sawBufferSinceCheck.withLock { $0 = true }
                    tapHandler(buffer, time)
                }
            }
        } catch {
            try? catchingObjCException {
                inputNode.removeTap(onBus: 0)
            }
            try? catchingObjCException {
                try inputNode.setVoiceProcessingEnabled(false)
            }
            replaceEngineAfterFailureLocked()
            throw error
        }

        do {
            try catchingObjCException {
                try audioEngine.start()
            }
        } catch {
            try? catchingObjCException {
                inputNode.removeTap(onBus: 0)
            }
            try? catchingObjCException {
                try inputNode.setVoiceProcessingEnabled(false)
            }
            replaceEngineAfterFailureLocked()
            throw error
        }
        running = true
        installConfigurationChangeObserverLocked()
        installDefaultInputChangeObserverLocked()
    }

    private func tearDownLocked() {
        removeConfigurationChangeObserverLocked()
        removeDefaultInputChangeObserverLocked()
        guard engineStarter == nil else {
            audioEngine = AVAudioEngine()
            running = false
            lastSucceededAttemptLocked = nil
            return
        }
        let inputNode = audioEngine.inputNode
        try? catchingObjCException {
            inputNode.removeTap(onBus: 0)
        }
        try? catchingObjCException {
            try inputNode.setVoiceProcessingEnabled(false)
        }
        try? catchingObjCException {
            audioEngine.stop()
        }
        // Replace the engine. Releasing the old instance tears down the
        // VPAU aggregate device coreaudiod created for it, so a sibling
        // AVAudioEngine in the same process doesn't inherit duplex layout.
        audioEngine = AVAudioEngine()
        running = false
        lastSucceededAttemptLocked = nil
    }

    /// Reset between failed device attempts (no tap installed yet, just
    /// hand back a fresh engine for the next try).
    private func resetEngineLocked() {
        removeConfigurationChangeObserverLocked()
        removeDefaultInputChangeObserverLocked()
        try? catchingObjCException {
            audioEngine.stop()
        }
        audioEngine = AVAudioEngine()
        running = false
        lastSucceededAttemptLocked = nil
    }

    private func replaceEngineAfterFailureLocked() {
        removeConfigurationChangeObserverLocked()
        removeDefaultInputChangeObserverLocked()
        try? catchingObjCException {
            audioEngine.stop()
        }
        audioEngine = AVAudioEngine()
        running = false
        lastSucceededAttemptLocked = nil
    }

    /// Observe `AVAudioEngine.configurationChangeNotification` on the
    /// current `audioEngine` and log every fire to `dictation-audio.log`.
    /// Core Audio posts this when the engine's input chain is renegotiated
    /// out from under us — default-input device change, sample-rate
    /// change, exclusive-access takeover by another process. Without
    /// observing it, those events are invisible in our logs and the
    /// silent tap-stall they can leave behind has no signature beyond
    /// "buffers stopped arriving."
    private func installConfigurationChangeObserverLocked() {
        let token = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: nil
        ) { [weak self] notification in
            guard let self, let engine = notification.object as? AVAudioEngine else { return }
            let engineBox = UncheckedSendableAudioEngine(engine)
            self.queue.async { [weak self, engineBox] in
                guard let self else { return }
                let format = engineBox.inputFormat()
                let snapshot = (
                    sr: format?.sampleRate ?? 0,
                    ch: format?.channelCount ?? 0,
                    isRunning: self.running
                )
                let defaultInput = AudioCaptureDiagnostics.defaultInputDeviceSummary()
                AudioCaptureDiagnostics.append(
                    "shared_mic_engine_configuration_changed sr=\(snapshot.sr) ch=\(snapshot.ch) isRunning=\(snapshot.isRunning) \(defaultInput)"
                )
                self.logger.info(
                    "shared_mic_engine_configuration_changed sr=\(snapshot.sr, privacy: .public) ch=\(snapshot.ch, privacy: .public) isRunning=\(snapshot.isRunning, privacy: .public)"
                )
                // A config change is the documented trigger for the silent
                // input-start stall; arm the watchdog to re-prime if no buffer
                // arrives shortly after.
                self.scheduleStallCheckLocked()
            }
        }
        configurationChangeObserver = token
    }

    private func removeConfigurationChangeObserverLocked() {
        if let token = configurationChangeObserver {
            NotificationCenter.default.removeObserver(token)
            configurationChangeObserver = nil
        }
    }

    private func installDefaultInputChangeObserverLocked() {
        guard defaultInputChangeObserver == nil else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            AudioCaptureDiagnostics.append(
                "audio_default_input_changed \(AudioCaptureDiagnostics.defaultInputDeviceSummary())"
            )
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            defaultInputListenerQueue,
            block
        )
        guard status == noErr else {
            AudioCaptureDiagnostics.append(
                "audio_default_input_listener_failed status=\(status)"
            )
            return
        }
        defaultInputChangeObserver = block
    }

    private func removeDefaultInputChangeObserverLocked() {
        guard let block = defaultInputChangeObserver else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            defaultInputListenerQueue,
            block
        )
        defaultInputChangeObserver = nil
    }
}

public enum AVAudioEngineMicrophonePlatformError: Error, Equatable, LocalizedError {
    case deviceSetFailed(MeetingInputDeviceAttempt)
    case invalidInputFormat(sampleRate: Double, channels: AVAudioChannelCount)
    case noDeviceAvailable

    public var errorDescription: String? {
        switch self {
        case .deviceSetFailed(let attempt):
            return "Failed to set \(attempt.source.logValue) input device"
        case .invalidInputFormat(let sampleRate, let channels):
            return "Invalid input format: sampleRate=\(sampleRate) channels=\(channels)"
        case .noDeviceAvailable:
            return "No microphone input device available"
        }
    }
}
