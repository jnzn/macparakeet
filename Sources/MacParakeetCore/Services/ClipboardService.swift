import AppKit
import Foundation

public protocol ClipboardServiceProtocol: Sendable {
    func pasteText(_ text: String) async throws
    func copyToClipboard(_ text: String) async
}

public enum ClipboardServiceError: LocalizedError {
    case accessibilityPermissionRequired
    case eventSourceUnavailable
    case eventCreationFailed

    public var errorDescription: String? {
        switch self {
        case .accessibilityPermissionRequired:
            return "Accessibility permission is required for auto-paste."
        case .eventSourceUnavailable:
            return "Paste automation unavailable (event source creation failed)."
        case .eventCreationFailed:
            return "Paste automation unavailable (could not create keyboard events)."
        }
    }
}

/// Handles clipboard save/restore and paste simulation via Cmd+V.
@MainActor
public final class ClipboardService: ClipboardServiceProtocol {
    public init() {}

    /// Paste text into the active app by:
    /// 1. Saving current clipboard
    /// 2. Setting transcript on clipboard
    /// 3. Simulating Cmd+V
    /// 4. Restoring original clipboard after 150ms delay
    public func pasteText(_ text: String) async throws {
        let pasteboard = NSPasteboard.general

        // 1. Save current clipboard contents
        let savedItems: [NSPasteboardItem]? = pasteboard.pasteboardItems?.map { item in
            let restored = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    restored.setData(data, forType: type)
                }
            }
            return restored
        }

        // 2. Set transcript
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ourChangeCount = pasteboard.changeCount

        // Always attempt to restore the previous clipboard contents after a short delay.
        // If caller intentionally rewrites clipboard on error, changeCount guard prevents clobbering.
        defer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                // If the user changed the clipboard after we wrote, do not clobber it.
                guard pasteboard.changeCount == ourChangeCount else {
                    return
                }

                pasteboard.clearContents()
                if let savedItems, !savedItems.isEmpty {
                    pasteboard.writeObjects(savedItems)
                }
            }
        }

        // 3. Simulate Cmd+V
        try simulatePaste()
    }

    /// Copy text to clipboard without paste simulation
    public func copyToClipboard(_ text: String) async {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - Private

    private func simulatePaste() throws {
        guard AXIsProcessTrusted() else {
            throw ClipboardServiceError.accessibilityPermissionRequired
        }

        // Cmd+V: virtual key 0x09 = 'v'
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw ClipboardServiceError.eventSourceUnavailable
        }

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
            throw ClipboardServiceError.eventCreationFailed
        }

        keyDown.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)

        keyUp.flags = .maskCommand
        keyUp.post(tap: .cghidEventTap)
    }
}
