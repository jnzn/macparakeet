import AppKit
import MacParakeetCore
import OSLog

/// Writes `text` to the given app's focused text area via clipboard paste.
/// Procedure:
///   1. Snapshot the current general pasteboard (with concealed-type hints
///      so clipboard managers skip it).
///   2. Activate the target app by pid so its window becomes frontmost.
///   3. Wait a tick for focus to land.
///   4. Write `text` to the pasteboard and simulate Cmd+V.
///   5. Restore the pasteboard snapshot after a short delay.
///
/// Works universally (AX-less apps fine, Electron fine) because every app
/// that can receive text via Cmd+V can receive a replacement this way.
/// Depends on Accessibility permission (for the CGEvent Cmd+V), which the
/// user has already granted for the primary dictation feature.
@MainActor
final class SelectionReplacer {
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "SelectionReplacer")
    private let clipboardService: ClipboardService

    init(clipboardService: ClipboardService) {
        self.clipboardService = clipboardService
    }

    enum Error: Swift.Error, LocalizedError {
        case targetAppUnavailable
        case underlying(Swift.Error)

        var errorDescription: String? {
            switch self {
            case .targetAppUnavailable:
                return "The original app is no longer available to receive the replacement."
            case .underlying(let inner):
                return inner.localizedDescription
            }
        }
    }

    /// Bring `pid` to the front, then paste `text`. Caller is responsible
    /// for dismissing the bubble before invoking (so the bubble's key
    /// window doesn't swallow Cmd+V). `ClipboardService.pasteText` already
    /// handles save/paste/restore + concealed-type hints.
    func replaceSelection(in pid: pid_t, with text: String) async throws {
        guard let runningApp = NSRunningApplication(processIdentifier: pid) else {
            throw Error.targetAppUnavailable
        }
        logger.info("replace_selection pid=\(pid, privacy: .public) chars=\(text.count)")

        // Activate the source app and wait a moment for its window to
        // become frontmost + its text field to be first responder before
        // paste-simulating. 80ms is empirically enough in the apps I've
        // tested (VS Code, Mail, Messages) without feeling laggy.
        runningApp.activate(options: [])
        try? await Task.sleep(for: .milliseconds(80))

        do {
            try await clipboardService.pasteText(text)
        } catch {
            throw Error.underlying(error)
        }
    }
}
