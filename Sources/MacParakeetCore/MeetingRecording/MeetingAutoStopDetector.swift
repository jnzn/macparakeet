import Foundation

/// Pure arm/fire state machine for activity-based meeting auto-stop (ADR-023).
/// Fed one `isCallActive` sample per poll; emits `.autoStop` exactly once, after
/// the call has been inactive for `delaySeconds` — but only after a call was seen
/// at least once during this recording (so in-person recordings never fire).
public struct MeetingAutoStopDetector {
    public enum Decision: Equatable { case none, autoStop }

    private enum Phase: Equatable {
        case disarmed
        case armed(releasedSince: Date?)
        case fired
    }

    public let delaySeconds: TimeInterval
    private var phase: Phase = .disarmed

    public init(delaySeconds: TimeInterval) {
        self.delaySeconds = delaySeconds
    }

    public mutating func sample(isCallActive: Bool, now: Date) -> Decision {
        switch phase {
        case .fired:
            return .none
        case .disarmed:
            if isCallActive { phase = .armed(releasedSince: nil) }
            return .none
        case .armed:
            if isCallActive {
                phase = .armed(releasedSince: nil)   // reset the release timer
                return .none
            }
            let since: Date
            if case .armed(let r) = phase, let r { since = r } else { since = now }
            if now.timeIntervalSince(since) >= delaySeconds {
                phase = .fired
                return .autoStop
            }
            phase = .armed(releasedSince: since)
            return .none
        }
    }
}
