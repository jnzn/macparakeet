import Foundation
import MacParakeetCore
import OSLog

/// Polls mic-capturing processes while a meeting recording is active and, when the
/// recorded call ends (every allowlisted call app has released the mic for the
/// configured delay), invokes `onAutoStop`. Only created/started when the meeting
/// auto-stop toggle is on. ADR-023 Phase 1.5: detection is allowlist-based —
/// only the user's configured call apps arm or release the detector.
@MainActor
final class MeetingCallActivityMonitor {
    private var task: Task<Void, Never>?
    private var detector: MeetingAutoStopDetector
    private let delaySeconds: Int
    private let pollInterval: TimeInterval
    private let allowedPrefixes: [String]
    private let capturingBundleIDs: @MainActor () -> [String?]
    /// Returns `true` when the stop was actually delivered. `false` (e.g. the
    /// recording is paused) resets the detector so auto-stop can re-arm later
    /// instead of dying for the rest of the recording.
    private let onAutoStop: @MainActor () -> Bool
    private let logger = Logger(subsystem: "com.macparakeet", category: "MeetingAutoStop")

    init(
        delaySeconds: Int,
        allowedPrefixes: [String],
        pollInterval: TimeInterval = 1.5,
        capturingBundleIDs: @escaping @MainActor () -> [String?] = { MicInputProbe.capturingInputBundleIDs() },
        onAutoStop: @escaping @MainActor () -> Bool
    ) {
        self.detector = MeetingAutoStopDetector(delaySeconds: TimeInterval(delaySeconds))
        self.delaySeconds = delaySeconds
        self.pollInterval = pollInterval
        self.allowedPrefixes = allowedPrefixes
        self.capturingBundleIDs = capturingBundleIDs
        self.onAutoStop = onAutoStop
    }

    func start() {
        task?.cancel()
        let prefixList = allowedPrefixes.joined(separator: ", ")
        logger.info("Monitor started — delay=\(self.delaySeconds)s allowlist=[\(prefixList, privacy: .public)]")
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            var wasActive = false
            while !Task.isCancelled {
                let matching = MeetingCallActivity.matchingBundleIDs(
                    capturingBundleIDs: self.capturingBundleIDs(),
                    allowedPrefixes: self.allowedPrefixes
                )
                let active = !matching.isEmpty
                if active != wasActive {
                    if active {
                        let matchList = matching.joined(separator: ", ")
                        self.logger.info("Call detected — \(matchList, privacy: .public)")
                    } else {
                        self.logger.info("All call apps released the mic — auto-stop in \(self.delaySeconds)s unless one returns")
                    }
                    wasActive = active
                }
                if self.detector.sample(isCallActive: active, now: Date()) == .autoStop {
                    if self.onAutoStop() {
                        self.logger.info("Auto-stop delivered")
                        break   // fire once; coordinator tears the monitor down
                    }
                    // Dropped (recording paused / already stopping). Reset so a
                    // future call can re-arm instead of leaving auto-stop dead.
                    self.logger.info("Auto-stop dropped (recording not active) — detector reset")
                    self.detector = MeetingAutoStopDetector(delaySeconds: TimeInterval(self.delaySeconds))
                    wasActive = false
                }
                try? await Task.sleep(for: .seconds(self.pollInterval))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
