import Foundation

/// Drives the cancellable grace countdown shown before ADR-023 activity auto-stop
/// ends a recording (audit PDX-014). `start` runs a single cancellable timer;
/// `cancel` (the user clicked "Keep recording", or the recording ended another way)
/// prevents the pending stop. Only an undisturbed countdown calls `onExpire`.
///
/// `sleep` is injectable so the cancel-prevents-stop guarantee is deterministically
/// testable without wall-clock flake.
@MainActor
final class MeetingAutoStopCountdown {
    private var task: Task<Void, Never>?
    private(set) var isActive = false
    private let sleep: @Sendable (TimeInterval) async -> Void

    init(sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
        try? await Task.sleep(for: .seconds(seconds))
    }) {
        self.sleep = sleep
    }

    /// Start (or restart) the countdown. After `seconds` elapse uninterrupted,
    /// `onExpire` is called exactly once on the main actor. A `cancel()` or a
    /// superseding `start(...)` before then suppresses it.
    func start(seconds: TimeInterval, onExpire: @escaping @MainActor () -> Void) {
        cancel()
        isActive = true
        let sleep = self.sleep
        task = Task { @MainActor [weak self] in
            await sleep(seconds)
            // A cancelled task (cancel() or a superseding start()) must not fire.
            guard !Task.isCancelled else { return }
            self?.isActive = false
            self?.task = nil
            onExpire()
        }
    }

    /// Stop a running countdown without firing. Safe to call when inactive.
    func cancel() {
        task?.cancel()
        task = nil
        isActive = false
    }
}
