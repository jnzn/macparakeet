#if canImport(AppKit)
import AppKit
#endif
#if canImport(ApplicationServices)
import ApplicationServices
#endif
import Foundation

/// Snapshot of what the user is dictating *into* at the moment `startRecording`
/// fires. Captured once per dictation session and then injected into the
/// cleanup LLM prompt so the model can disambiguate ambiguous transcriptions
/// using real context (e.g. a Teams window titled "Chat with Yeswanth" lets
/// "just once" resolve to "Yeswanth" when the user meant the name).
///
/// Every field is optional: AX can be blocked by permission, by the app (some
/// Electron shells), or by an explicit blocklist. `isEmpty` is true when no
/// useful signal came back.
public struct AppContext: Equatable, Sendable {
    public let bundleID: String?
    public let windowTitle: String?
    public let focusedFieldValue: String?
    public let selectedText: String?

    public init(
        bundleID: String? = nil,
        windowTitle: String? = nil,
        focusedFieldValue: String? = nil,
        selectedText: String? = nil
    ) {
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.focusedFieldValue = focusedFieldValue
        self.selectedText = selectedText
    }

    /// True when none of the three content signals came back with text. A
    /// bundle ID alone is not enough to warrant a context block in the prompt.
    public var isEmpty: Bool {
        isBlank(windowTitle) && isBlank(focusedFieldValue) && isBlank(selectedText)
    }

    /// Context hint lines to prepend to the cleanup prompt. Returns empty
    /// string when nothing useful was captured. Long field/selection values
    /// are truncated so the prompt doesn't balloon if the user has selected
    /// an entire document.
    public func asPromptBlock(
        maxFieldChars: Int = 300,
        maxSelectionChars: Int = 500
    ) -> String {
        var lines: [String] = []
        if let windowTitle, !isBlank(windowTitle) {
            lines.append("- Window: \(windowTitle.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        if let focusedFieldValue, !isBlank(focusedFieldValue) {
            let cleaned = focusedFieldValue.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append("- Current field contains: \"\(Self.truncate(cleaned, limit: maxFieldChars))\"")
        }
        if let selectedText, !isBlank(selectedText) {
            let cleaned = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append("- Selected text: \"\(Self.truncate(cleaned, limit: maxSelectionChars))\"")
        }
        return lines.joined(separator: "\n")
    }

    private func isBlank(_ value: String?) -> Bool {
        (value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ?? true
    }

    private static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let idx = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<idx]) + "…"
    }
}

/// Read-only snapshot of the current macOS frontmost app context. Consumed by
/// `DictationService` at start-of-dictation to resolve which `AppProfile`
/// applies, and to gather AX-based context hints for the cleanup LLM.
public enum AppContextService {
    /// Apps whose AX tree we refuse to read on principle. Window titles /
    /// focused fields in these apps often contain secrets (passwords, recovery
    /// phrases, private keys) that have no business appearing in an LLM prompt.
    /// Banking apps and other per-user sensitive sources aren't enumerable —
    /// users can extend this via profile settings in a later iteration.
    public static let blocklistedBundleIDs: Set<String> = [
        "com.1password.1password",
        "com.1password.1password7",
        "com.1password.7",
        "com.agilebits.onepassword7",
        "com.apple.keychainaccess",
        "com.apple.systempreferences",
        "com.apple.systemsettings",
    ]

    /// True when the given bundle ID is in the hardcoded block list. Case-
    /// sensitive, matches Apple's canonical bundle identifier format.
    public static func isBlocklisted(bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return blocklistedBundleIDs.contains(bundleID)
    }

    /// Bundle identifier of the frontmost foreground app, or nil if unavailable.
    /// The MacParakeet menu-bar app does not activate on the dictation hotkey,
    /// and its floating overlays are non-activating NSPanels, so the frontmost
    /// app at this moment is the app the user is actually dictating into.
    public static func frontmostBundleID() -> String? {
        #if canImport(AppKit)
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        #else
        return nil
        #endif
    }

    /// Title of the currently focused window in the frontmost app, or nil if
    /// AX is denied / the app doesn't expose a title. `timeoutSeconds` bounds
    /// any single AX call — Electron and other slow apps can otherwise block
    /// the caller for hundreds of milliseconds.
    public static func frontmostWindowTitle(timeoutSeconds: Float = 0.15) -> String? {
        #if canImport(AppKit) && canImport(ApplicationServices)
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return nil
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeoutSeconds)

        guard let window: AXUIElement = copyAXAttribute(app, kAXFocusedWindowAttribute as CFString) else {
            return nil
        }
        let title: String? = copyAXAttribute(window, kAXTitleAttribute as CFString)
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
        #else
        return nil
        #endif
    }

    /// Full AX snapshot for the cleanup prompt. Reads bundle ID + window title
    /// here, and delegates focused-field-value + selected-text to the provided
    /// `AccessibilityService` (which already implements the multi-tier fallback
    /// for selection reads). Runs on a detached task so slow AX calls don't
    /// block the calling actor; returns a best-effort `AppContext` in all
    /// failure modes — never throws.
    public static func captureContext(
        accessibility: AccessibilityService,
        timeoutSeconds: Float = 0.15
    ) async -> AppContext {
        await Task.detached(priority: .userInitiated) {
            let bundleID = frontmostBundleID()
            if isBlocklisted(bundleID: bundleID) {
                return AppContext(bundleID: bundleID)
            }
            let windowTitle = frontmostWindowTitle(timeoutSeconds: timeoutSeconds)
            let focus = accessibility.captureFocusSnapshot(timeoutSeconds: timeoutSeconds)
            return AppContext(
                bundleID: bundleID,
                windowTitle: windowTitle,
                focusedFieldValue: focus.focusedFieldValue,
                selectedText: focus.selectedText
            )
        }.value
    }

    #if canImport(ApplicationServices)
    /// Typed AX attribute read. Returns nil when the attribute is absent, the
    /// AX call fails, or the returned value isn't the requested type.
    private static func copyAXAttribute<T>(_ element: AXUIElement, _ attribute: CFString) -> T? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard status == .success, let value else { return nil }
        return value as? T
    }
    #endif
}
