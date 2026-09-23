import Foundation

/// Pure auto-stop policy for ADR-023. No AppKit, timers, audio APIs, or UI.
/// The app coordinator owns signal observation, grace clocks, and countdown UI;
/// this policy only decides whether the current observation is stop-eligible.
public enum MeetingAutoStopPolicy {
    public struct MeetingContext: Sendable, Equatable {
        /// Recognized meeting apps observed running at or after recording start.
        public var observedMeetingAppBundleIDs: Set<String>
        public var startedAt: Date
        /// Set once a call-app has been seen actively capturing the mic during
        /// this recording (ADR-023 Phase 1.5 restore). Gates `.callEnded` so an
        /// in-person recording — no call app ever on the mic — never fires it.
        public var callSeenActive: Bool

        public init(
            observedMeetingAppBundleIDs: Set<String>,
            startedAt: Date,
            callSeenActive: Bool = false
        ) {
            self.observedMeetingAppBundleIDs = observedMeetingAppBundleIDs
            self.startedAt = startedAt
            self.callSeenActive = callSeenActive
        }
    }

    public struct Observation: Sendable, Equatable {
        public var now: Date
        public var isRecording: Bool
        public var isPaused: Bool
        public var runningMeetingAppBundleIDs: Set<String>
        /// Continuous seconds where both meeting channels have stayed below
        /// the coordinator's silence threshold.
        public var continuousSilenceSeconds: TimeInterval
        /// `true` when a call-app is currently capturing the mic, per
        /// `MicInputProbe` + `MeetingCallActivity.isCall`, this poll tick.
        public var isCallActive: Bool
        /// Continuous seconds since a call-app was last seen capturing the mic.
        public var continuousCallInactiveSeconds: TimeInterval

        public init(
            now: Date,
            isRecording: Bool,
            isPaused: Bool,
            runningMeetingAppBundleIDs: Set<String>,
            continuousSilenceSeconds: TimeInterval,
            isCallActive: Bool = false,
            continuousCallInactiveSeconds: TimeInterval = 0
        ) {
            self.now = now
            self.isRecording = isRecording
            self.isPaused = isPaused
            self.runningMeetingAppBundleIDs = runningMeetingAppBundleIDs
            self.continuousSilenceSeconds = continuousSilenceSeconds
            self.isCallActive = isCallActive
            self.continuousCallInactiveSeconds = continuousCallInactiveSeconds
        }
    }

    public struct Config: Sendable, Equatable {
        public var appQuitEnabled: Bool
        public var silenceEnabled: Bool
        /// ADR-023 Phase 1.5 restore: allowlist-based call-activity detection
        /// (mic release by the actual call app, not app quit or ambient
        /// silence). On by default alongside the other two signals, matching
        /// what PDX shipped before this got dropped in a rebase.
        public var callEndedEnabled: Bool
        /// Read by the app coordinator before it calls the policy for an
        /// app-quit proposal. Stored here so one config object describes the
        /// complete ADR-023 posture.
        public var appQuitGraceSeconds: TimeInterval
        public var silenceGraceSeconds: TimeInterval
        /// How long a call-app must be absent from the mic-capturing process
        /// list before `.callEnded` fires. PDX's original default was 5s —
        /// safe to be this aggressive (unlike the silence grace) because mic
        /// release by the actual call app is a precise signal, not a heuristic
        /// over ambient audio level.
        public var callEndedGraceSeconds: TimeInterval

        public init(
            appQuitEnabled: Bool = true,
            silenceEnabled: Bool = true,
            callEndedEnabled: Bool = true,
            appQuitGraceSeconds: TimeInterval = 15,
            silenceGraceSeconds: TimeInterval = 240,
            callEndedGraceSeconds: TimeInterval = 5
        ) {
            self.appQuitEnabled = appQuitEnabled
            self.silenceEnabled = silenceEnabled
            self.callEndedEnabled = callEndedEnabled
            self.appQuitGraceSeconds = appQuitGraceSeconds
            self.silenceGraceSeconds = silenceGraceSeconds
            self.callEndedGraceSeconds = callEndedGraceSeconds
        }

        public static let `default` = Config()
    }

    public enum StopReason: Sendable, Equatable, Hashable {
        case meetingAppClosed(bundleID: String)
        case prolongedSilence
        case callEnded

        public var telemetryReason: TelemetryMeetingAutoStopReason {
            switch self {
            case .meetingAppClosed:
                return .meetingAppClosed
            case .prolongedSilence:
                return .prolongedSilence
            case .callEnded:
                return .callEnded
            }
        }
    }

    public enum Decision: Sendable, Equatable {
        case keepRecording
        case proposeStop(reason: StopReason)
    }

    public static func evaluate(
        context: MeetingContext,
        observation: Observation,
        config: Config
    ) -> Decision {
        guard observation.isRecording, !observation.isPaused else {
            return .keepRecording
        }

        if config.appQuitEnabled,
           let closedBundleID = closedObservedMeetingApp(
               observed: context.observedMeetingAppBundleIDs,
               running: observation.runningMeetingAppBundleIDs
           ) {
            return .proposeStop(reason: .meetingAppClosed(bundleID: closedBundleID))
        }

        // Checked ahead of silence: mic release by the actual call app is a
        // precise signal (short grace, safe), whereas silence is a heuristic
        // over ambient audio level (long grace, to avoid firing on an ordinary
        // pause). `callSeenActive` gates it so an in-person recording — no
        // call app ever captured the mic — never fires this.
        if config.callEndedEnabled, context.callSeenActive,
           observation.continuousCallInactiveSeconds >= config.callEndedGraceSeconds {
            return .proposeStop(reason: .callEnded)
        }

        if config.silenceEnabled,
           observation.continuousSilenceSeconds >= config.silenceGraceSeconds {
            return .proposeStop(reason: .prolongedSilence)
        }

        return .keepRecording
    }

    private static func closedObservedMeetingApp(
        observed: Set<String>,
        running: Set<String>
    ) -> String? {
        observed
            .subtracting(running)
            .sorted()
            .first
    }
}
