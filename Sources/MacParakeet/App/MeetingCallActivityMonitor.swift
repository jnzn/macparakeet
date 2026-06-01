import Foundation
import MacParakeetCore

/// Polls mic-capturing processes while a meeting recording is active and, when the
/// recorded call ends (call app releases the mic for the configured delay), invokes
/// `onAutoStop`. Only created/started when the meeting auto-stop toggle is on.
@MainActor
final class MeetingCallActivityMonitor {
    private var task: Task<Void, Never>?
    private var detector: MeetingAutoStopDetector
    private let pollInterval: TimeInterval
    private let capturingBundleIDs: @MainActor () -> [String?]
    private let onAutoStop: @MainActor () -> Void

    init(
        delaySeconds: Int,
        pollInterval: TimeInterval = 1.5,
        capturingBundleIDs: @escaping @MainActor () -> [String?] = { MicInputProbe.capturingInputBundleIDs() },
        onAutoStop: @escaping @MainActor () -> Void
    ) {
        self.detector = MeetingAutoStopDetector(delaySeconds: TimeInterval(delaySeconds))
        self.pollInterval = pollInterval
        self.capturingBundleIDs = capturingBundleIDs
        self.onAutoStop = onAutoStop
    }

    func start() {
        task?.cancel()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let active = MeetingCallActivity.isCall(capturingBundleIDs: self.capturingBundleIDs())
                if self.detector.sample(isCallActive: active, now: Date()) == .autoStop {
                    self.onAutoStop()
                    break   // fire once; coordinator tears the monitor down
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
