import AppKit
import Carbon
import Foundation
import OSLog

/// Reads the user's currently selected text from the frontmost app.
///
/// Prefers the Accessibility API (`kAXSelectedTextAttribute`) because it is
/// silent and side-effect-free. Falls back to a Cmd+C-based probe for apps
/// whose AX tree doesn't expose selection (Electron — VS Code, Discord,
/// Slack, Teams 2, Obsidian — and some web/PDF viewers), which every app
/// that supports copy will surface. The probe snapshots the clipboard,
/// simulates Cmd+C, waits briefly for the copy to land, reads the new
/// clipboard contents, and restores the original — same pattern used by
/// Raycast, Alfred, PopClip, and SuperWhisper for their selection grabs.
@MainActor
public final class SelectionReader {
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "SelectionReader")
    private let accessibility: AccessibilityServiceProtocol

    /// Max wait in milliseconds for Cmd+C-induced clipboard changeCount tick.
    /// 300 ms is generous for even laggy Electron apps; typical is <50 ms.
    private let cmdCMaxWaitMs: Int = 300
    private let cmdCPollIntervalMs: Int = 15

    public init(accessibility: AccessibilityServiceProtocol) {
        self.accessibility = accessibility
    }

    public enum Source: String, Sendable {
        case accessibility
        case clipboardProbe
    }

    public struct Result: Sendable {
        public let text: String
        public let source: Source
    }

    public enum Error: Swift.Error, LocalizedError {
        case noSelection
        case accessibilityPermissionRequired
        case clipboardProbeUnavailable(String)

        public var errorDescription: String? {
            switch self {
            case .noSelection:
                return "No text is selected."
            case .accessibilityPermissionRequired:
                return "Accessibility permission is required to read selected text."
            case .clipboardProbeUnavailable(let message):
                return "Couldn't read the selected text via clipboard probe: \(message)"
            }
        }
    }

    /// Attempt AX first; on failure fall back to Cmd+C probe. Throws only
    /// when both paths fail.
    public func readSelection() throws -> Result {
        do {
            let text = try accessibility.getSelectedText(maxCharacters: nil)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                logger.info("selection_read source=ax chars=\(text.count)")
                return Result(text: text, source: .accessibility)
            }
        } catch AccessibilityServiceError.notAuthorized {
            // AX auth is required for both paths (we need it to simulate
            // Cmd+C too). Propagate as the specific error so the caller
            // can surface the correct guidance.
            throw Error.accessibilityPermissionRequired
        } catch {
            logger.info("ax_selection_unavailable reason=\(Self.axReason(error), privacy: .public)")
        }

        // Cmd+C fallback.
        do {
            let text = try probeSelectionViaClipboard()
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw Error.noSelection
            }
            logger.info("selection_read source=clipboard chars=\(trimmed.count)")
            return Result(text: trimmed, source: .clipboardProbe)
        } catch let e as Error {
            throw e
        } catch {
            throw Error.clipboardProbeUnavailable(error.localizedDescription)
        }
    }

    // MARK: - Clipboard probe

    /// Snapshot the clipboard, simulate Cmd+C, poll for the changeCount to
    /// tick (i.e. the copy landed), read the new string, restore the
    /// snapshot. Sets the nspasteboard.org `ConcealedType` / `TransientType`
    /// hints on the transient read so clipboard managers (Maccy, Pastebot,
    /// LaunchBar) skip recording it.
    private func probeSelectionViaClipboard() throws -> String {
        guard AXIsProcessTrusted() else {
            throw Error.accessibilityPermissionRequired
        }

        let pasteboard = NSPasteboard.general
        let savedItems = snapshotPasteboard(pasteboard)
        let originalChangeCount = pasteboard.changeCount

        defer {
            // Restore the original contents regardless of whether the probe
            // succeeded. Minimal delay so a clipboard manager polling on a
            // timer has less opportunity to record the transient copy.
            restorePasteboard(pasteboard, items: savedItems)
        }

        try simulateCmdC()

        // Poll for changeCount to tick past our baseline. If the target app
        // was empty-selected, it never ticks — bail after the timeout.
        let deadlineMs = cmdCMaxWaitMs
        var waitedMs = 0
        while pasteboard.changeCount == originalChangeCount && waitedMs < deadlineMs {
            let interval = TimeInterval(cmdCPollIntervalMs) / 1000.0
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: interval))
            waitedMs += cmdCPollIntervalMs
        }

        guard pasteboard.changeCount != originalChangeCount else {
            logger.info("clipboard_probe_timeout waited_ms=\(waitedMs, privacy: .public)")
            throw Error.noSelection
        }

        guard let copied = pasteboard.string(forType: .string) else {
            throw Error.noSelection
        }

        // Immediately mark the current (transient) entry with concealed-type
        // hints so any clipboard manager that checks-on-set skips it.
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))

        return copied
    }

    private func snapshotPasteboard(_ pasteboard: NSPasteboard) -> [NSPasteboardItem]? {
        pasteboard.pasteboardItems?.map { item in
            let restored = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    restored.setData(data, forType: type)
                }
            }
            return restored
        }
    }

    private func restorePasteboard(_ pasteboard: NSPasteboard, items: [NSPasteboardItem]?) {
        pasteboard.clearContents()
        if let items, !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }

    private func simulateCmdC() throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw Error.clipboardProbeUnavailable("CGEventSource unavailable")
        }
        let cVirtualKey: UInt16 = 8  // 'c'
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: cVirtualKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: cVirtualKey, keyDown: false)
        else {
            throw Error.clipboardProbeUnavailable("CGEvent creation failed")
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private static func axReason(_ error: Swift.Error) -> String {
        guard let axError = error as? AccessibilityServiceError else { return "unknown" }
        switch axError {
        case .notAuthorized: return "no_permission"
        case .noFocusedElement: return "no_focused_element"
        case .noSelectedText: return "no_selected_text"
        case .textTooLong: return "too_long"
        case .unsupportedElement: return "unsupported_element"
        }
    }
}
