import AVFoundation
import Foundation
import os

/// Single mic engine shared across dictation and meeting recording.
///
/// Plan: `plans/active/shared-mic-engine.md` (PROPOSAL → in implementation).
/// The real-world bug this addresses: enabling VPIO anywhere in the process
/// makes coreaudiod hand every other `AVAudioEngine` a multi-channel duplex
/// layout. Two independent engines look isolated in code but aren't isolated
/// at the kernel layer. One shared engine with explicit VPIO arbitration
/// removes the ambiguity.
///
/// ## Design pillars
///
/// 1. **One mic engine per process.** Enforced by living in `AppEnvironment`
///    as a singleton. Multiple instances reproduce the original bug shape.
///
/// 2. **Lock-protected state, lock-free fan-out.** State changes
///    (subscribe/unsubscribe/engine-start) are serialized by an
///    `OSAllocatedUnfairLock`. Tap callbacks read a handler snapshot under
///    the same lock then release before invoking handlers. The audio render
///    thread never calls into actor-isolated code.
///
/// 3. **Engine ops serialized off-lock.** Engine start/stop runs on a
///    dedicated serial queue via continuation, so `subscribe` doesn't hold
///    the state lock across Core Audio I/O.
///
/// 4. **VPIO is sticky once engaged.** Once any subscriber requests VPIO,
///    it stays on for the engine's lifetime. Disengaging mid-session would
///    require another stop+start dance with no user-visible benefit.
///
/// 5. **VPIO engagement is deferred** if a non-VPIO subscriber is in
///    flight. Avoids a format-change in the middle of an active dictation
///    stream. The deferral counter is exposed for telemetry sizing.
///
/// 6. **Subscribers receive a read-only buffer** valid only for the
///    synchronous handler call. Retention or mutation requires copying
///    first; the engine may reuse the underlying memory immediately after
///    return.
public final class SharedMicrophoneStream: @unchecked Sendable {
    public typealias BufferHandler = @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void

    public struct SubscriberToken: Hashable, Sendable {
        public let id: UUID
        public init(id: UUID = UUID()) { self.id = id }
    }

    public enum SubscribeError: Error, Equatable {
        case engineStartFailed(String)
    }

    public struct Diagnostics: Equatable, Sendable {
        public let subscriberCount: Int
        public let vpioSubscriberCount: Int
        public let engineRunning: Bool
        public let vpioEngaged: Bool
        public let vpioDeferred: Bool
        public let vpioDeferralCount: Int
    }

    private struct Subscriber {
        let token: SubscriberToken
        let wantsVPIO: Bool
        let handler: BufferHandler
    }

    private struct State {
        var subscribers: [SubscriberToken: Subscriber] = [:]
        var engineRunning: Bool = false
        var vpioEngaged: Bool = false
        /// True when at least one subscriber wants VPIO but a non-VPIO
        /// subscriber is in flight, so engagement is held off until the
        /// non-VPIO subscriber leaves. Goes back to false on engagement.
        var vpioDeferred: Bool = false
        /// Lifetime counter — increments each time engagement is deferred.
        /// Exposed for telemetry sizing of the edge case.
        var vpioDeferralCount: Int = 0
    }

    private enum EngineAction: Equatable {
        case startEngine(vpio: Bool)
        case reconfigureToVPIO
        case stopEngine
        case none
    }

    private let logger = Logger(
        subsystem: "com.macparakeet.core",
        category: "SharedMicrophoneStream"
    )
    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let engineQueue = DispatchQueue(label: "com.macparakeet.shared-mic-stream.engine")
    private let platform: any MicrophoneEnginePlatform
    private let bufferSize: AVAudioFrameCount

    public init(
        platform: any MicrophoneEnginePlatform,
        bufferSize: AVAudioFrameCount = 4096
    ) {
        self.platform = platform
        self.bufferSize = bufferSize
    }

    // MARK: - Public API

    public var inputFormat: AVAudioFormat? {
        platform.inputFormat
    }

    public var diagnostics: Diagnostics {
        lock.withLock { state in
            Diagnostics(
                subscriberCount: state.subscribers.count,
                vpioSubscriberCount: state.subscribers.values.filter { $0.wantsVPIO }.count,
                engineRunning: state.engineRunning,
                vpioEngaged: state.vpioEngaged,
                vpioDeferred: state.vpioDeferred,
                vpioDeferralCount: state.vpioDeferralCount
            )
        }
    }

    /// Add a subscriber. Engine starts on first subscriber; VPIO engages
    /// (or defers) per the rules in the type docs.
    public func subscribe(
        wantsVPIO: Bool,
        handler: @escaping BufferHandler
    ) async throws -> SubscriberToken {
        let token = SubscriberToken()
        let action: EngineAction = lock.withLock { state in
            decideSubscribeAction(state: &state, token: token, wantsVPIO: wantsVPIO, handler: handler)
        }

        if action == .none {
            return token
        }

        do {
            try await runEngineAction(action)
        } catch {
            // Roll back the optimistic state mutation. If this was the
            // first subscriber, also clear engineRunning/vpioEngaged.
            lock.withLock { state in
                state.subscribers.removeValue(forKey: token)
                if state.subscribers.isEmpty {
                    state.engineRunning = false
                    state.vpioEngaged = false
                    state.vpioDeferred = false
                }
            }
            throw SubscribeError.engineStartFailed(error.localizedDescription)
        }
        return token
    }

    /// Remove a subscriber. Engine stops when the last subscriber leaves.
    /// Idempotent — unsubscribing an unknown token is a no-op.
    ///
    /// If unsubscribe triggers a deferred-VPIO promotion (last non-VPIO
    /// subscriber leaving while VPIO subs remain) and the platform's
    /// reconfigure fails, we log and roll back the VPIO state so the
    /// engine continues serving the remaining subscribers raw audio.
    /// Subscribers can detect this via `diagnostics.vpioEngaged`.
    public func unsubscribe(_ token: SubscriberToken) async {
        let action: EngineAction = lock.withLock { state in
            decideUnsubscribeAction(state: &state, token: token)
        }

        if action == .none { return }

        do {
            try await runEngineAction(action)
        } catch {
            // Roll back the optimistic VPIO promotion. The engine is still
            // running raw; remaining subscribers continue receiving raw
            // audio. A stop-engine action that fails is logged but not
            // recoverable — engine is already in an indeterminate state.
            switch action {
            case .reconfigureToVPIO:
                lock.withLock { state in
                    state.vpioEngaged = false
                    state.vpioDeferred = !state.subscribers.isEmpty
                }
                logger.error(
                    "shared_mic_engine_reconfigure_failed reason=\(error.localizedDescription, privacy: .public)"
                )
            case .stopEngine:
                logger.error(
                    "shared_mic_engine_stop_failed reason=\(error.localizedDescription, privacy: .public)"
                )
            case .startEngine, .none:
                break
            }
        }
    }

    // MARK: - State machine (pure, lock-held)

    /// Decide the engine action for a new subscriber. Mutates state
    /// optimistically — caller must roll back on failure.
    private func decideSubscribeAction(
        state: inout State,
        token: SubscriberToken,
        wantsVPIO: Bool,
        handler: @escaping BufferHandler
    ) -> EngineAction {
        let isFirst = state.subscribers.isEmpty
        let hasNonVPIOInFlight = state.subscribers.values.contains { !$0.wantsVPIO }
        state.subscribers[token] = Subscriber(token: token, wantsVPIO: wantsVPIO, handler: handler)

        if isFirst {
            state.engineRunning = true
            state.vpioEngaged = wantsVPIO
            state.vpioDeferred = false
            return .startEngine(vpio: wantsVPIO)
        }

        // Engine already running.
        if !wantsVPIO {
            // Non-VPIO subscriber joins. No engine change needed.
            return .none
        }

        // wantsVPIO == true and engine running.
        if state.vpioEngaged {
            // VPIO already on; nothing to do.
            return .none
        }

        // wantsVPIO and engine not in VPIO → there must be at least one
        // non-VPIO subscriber holding it raw (otherwise the engine would
        // have either started VPIO via the isFirst branch above, or be
        // sticky-on from a prior VPIO sub). Defer engagement until that
        // subscriber leaves; promotion then happens via the unsubscribe
        // path. The `hasNonVPIOInFlight` guard is therefore always true
        // here, but kept as a precondition assertion in case future state
        // changes alter the invariant.
        assert(hasNonVPIOInFlight, "VPIO not engaged but no non-VPIO subscriber in flight — invariant broken")
        state.vpioDeferred = true
        state.vpioDeferralCount += 1
        return .none
    }

    /// Decide the engine action for unsubscribe.
    private func decideUnsubscribeAction(
        state: inout State,
        token: SubscriberToken
    ) -> EngineAction {
        guard state.subscribers.removeValue(forKey: token) != nil else {
            return .none
        }

        if state.subscribers.isEmpty {
            state.engineRunning = false
            state.vpioEngaged = false
            state.vpioDeferred = false
            return .stopEngine
        }

        // Engine stays up. If VPIO was deferred and the last non-VPIO
        // subscriber just left, engagement can proceed now.
        if state.vpioDeferred {
            let stillHasNonVPIO = state.subscribers.values.contains { !$0.wantsVPIO }
            let stillHasVPIOWanter = state.subscribers.values.contains { $0.wantsVPIO }
            if !stillHasNonVPIO && stillHasVPIOWanter {
                state.vpioDeferred = false
                state.vpioEngaged = true
                return .reconfigureToVPIO
            }
        }
        return .none
    }

    // MARK: - Engine ops (serialized, off-lock)

    private func runEngineAction(_ action: EngineAction) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            engineQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                do {
                    try self.executeEngineAction(action)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func executeEngineAction(_ action: EngineAction) throws {
        switch action {
        case .startEngine(let vpio):
            try platform.configureAndStart(
                vpioEnabled: vpio,
                bufferSize: bufferSize,
                tapHandler: makeFanOut()
            )
        case .reconfigureToVPIO:
            try platform.configureAndStart(
                vpioEnabled: true,
                bufferSize: bufferSize,
                tapHandler: makeFanOut()
            )
        case .stopEngine:
            platform.stopEngine()
        case .none:
            break
        }
    }

    // MARK: - Audio-thread fan-out

    /// Produces the closure that the platform installs as its tap handler.
    /// Called from the audio render thread on every buffer.
    private func makeFanOut() -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        return { [weak self] buffer, time in
            self?.deliverBuffer(buffer, time: time)
        }
    }

    /// Audio-thread entry point. Snapshots the handler set under the lock,
    /// releases, then invokes each handler. Lock hold time is bounded
    /// (small array build) and the unfair lock is render-thread-safe.
    ///
    /// **Buffer contract:** the buffer passed in is valid only for the
    /// synchronous duration of this call. Handlers that need to retain it
    /// past return must copy. The lock is **not** held while handlers run,
    /// so a slow handler does not block subscribe/unsubscribe.
    private func deliverBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        let handlers: [BufferHandler] = lock.withLock { state in
            state.subscribers.values.map(\.handler)
        }
        for handler in handlers {
            handler(buffer, time)
        }
    }
}
