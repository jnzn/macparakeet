#if canImport(AppKit)
import AppKit
#endif
#if canImport(ApplicationServices)
import ApplicationServices
#endif
#if canImport(Vision)
import Vision
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
    /// Visible text content from the active window (AX tree or OCR).
    /// Only populated when an LLM is configured. Capped at ~1500 chars.
    public let windowContent: String?

    public init(
        bundleID: String? = nil,
        windowTitle: String? = nil,
        focusedFieldValue: String? = nil,
        selectedText: String? = nil,
        windowContent: String? = nil
    ) {
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.focusedFieldValue = focusedFieldValue
        self.selectedText = selectedText
        self.windowContent = windowContent
    }

    /// Returns a copy with `windowContent` filled in.
    public func withWindowContent(_ content: String) -> AppContext {
        AppContext(
            bundleID: bundleID,
            windowTitle: windowTitle,
            focusedFieldValue: focusedFieldValue,
            selectedText: selectedText,
            windowContent: content
        )
    }

    /// True when none of the content signals came back with text.
    /// A bundle ID alone is not enough to warrant a context block in the prompt.
    public var isEmpty: Bool {
        isBlank(windowTitle) && isBlank(focusedFieldValue) && isBlank(selectedText) && isBlank(windowContent)
    }

    /// Context hint lines to prepend to the cleanup prompt. Returns empty
    /// string when nothing useful was captured. Long field/selection values
    /// are truncated so the prompt doesn't balloon if the user has selected
    /// an entire document.
    public func asPromptBlock(
        maxFieldChars: Int = 300,
        maxSelectionChars: Int = 500,
        maxWindowContentChars: Int = 1500
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
        if let windowContent, !isBlank(windowContent) {
            let cleaned = windowContent.trimmingCharacters(in: .whitespacesAndNewlines)
            // Explicit instruction so the model doesn't reproduce document content in output.
            lines.append("- Active window content (reference only — do NOT reproduce in output): \"\(Self.truncate(cleaned, limit: maxWindowContentChars))\"")
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

    /// Best-effort screen rect for the frontmost app's current text selection.
    /// Fallback ladder:
    ///   1. Selection bounds via `kAXBoundsForRangeParameterizedAttribute`
    ///   2. Focused element bounds (position + size)
    ///   3. Frontmost window bounds
    ///   4. nil
    ///
    /// Result is in **Cocoa screen coordinates** (origin = bottom-left of the
    /// primary display, Y increases upward). AX returns top-left-origin rects
    /// relative to the primary display; this helper handles the conversion so
    /// callers can position NSWindow/NSPanel frames directly.
    ///
    /// Used by the AI Assistant bubble to render near the selected text. In
    /// Electron / web apps where selection bounds aren't exposed, tiers 2–3
    /// still give us a usable anchor (the focused field or the window itself).
    public static func frontmostSelectionScreenRect(
        timeoutSeconds: Float = 0.15
    ) -> CGRect? {
        #if canImport(AppKit) && canImport(ApplicationServices)
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        return selectionScreenRect(for: pid, timeoutSeconds: timeoutSeconds)
        #else
        return nil
        #endif
    }

    /// Best-effort screen rect for a specific app's current text selection.
    /// Used by the AI Assistant bubble to capture an anchor against the source
    /// app before the bubble takes key-window status.
    ///
    /// `includeWindowFallback` is configurable so contextual bubble placement
    /// can degrade to "no anchor" instead of snapping to the target app's
    /// outer window frame when AX won't surface a real text rect.
    public static func selectionScreenRect(
        for pid: pid_t,
        timeoutSeconds: Float = 0.15,
        includeWindowFallback: Bool = true
    ) -> CGRect? {
        #if canImport(AppKit) && canImport(ApplicationServices)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeoutSeconds)

        // Tier 1: selection bounds
        if let focused: AXUIElement = copyAXAttribute(app, kAXFocusedUIElementAttribute as CFString) {
            AXUIElementSetMessagingTimeout(focused, timeoutSeconds)
            if let rect = selectionBoundsRect(of: focused) {
                return convertAXRectToCocoa(rect)
            }
            // Tier 2: focused element bounds (position + size)
            if let rect = elementBoundsRect(of: focused) {
                return convertAXRectToCocoa(rect)
            }
        }

        guard includeWindowFallback else { return nil }

        // Tier 3: frontmost window bounds
        if let window: AXUIElement = copyAXAttribute(app, kAXFocusedWindowAttribute as CFString) {
            AXUIElementSetMessagingTimeout(window, timeoutSeconds)
            if let rect = elementBoundsRect(of: window) {
                return convertAXRectToCocoa(rect)
            }
        }
        return nil
        #else
        return nil
        #endif
    }

    #if canImport(AppKit) && canImport(ApplicationServices)
    /// Tier 1 lookup: selected-text range → bounds rect. Requires the element
    /// to support both `kAXSelectedTextRangeAttribute` and
    /// `kAXBoundsForRangeParameterizedAttribute` (native Cocoa text fields
    /// and most good AX citizens do; Electron apps usually don't).
    private static func selectionBoundsRect(of element: AXUIElement) -> CGRect? {
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeValue
        ) == .success, let rangeValue else { return nil }

        var rawBounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &rawBounds
        ) == .success, let rawBounds else { return nil }

        guard CFGetTypeID(rawBounds) == AXValueGetTypeID() else { return nil }
        let axBounds = unsafeBitCast(rawBounds, to: AXValue.self)
        guard AXValueGetType(axBounds) == .cgRect else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(axBounds, .cgRect, &rect) else { return nil }
        guard rect.width > 0 || rect.height > 0 else { return nil }
        return rect
    }

    /// Tier 2/3: element bounds via position + size attributes.
    private static func elementBoundsRect(of element: AXUIElement) -> CGRect? {
        guard let position = axPointValue(element, kAXPositionAttribute as CFString),
              let size = axSizeValue(element, kAXSizeAttribute as CFString) else {
            return nil
        }
        let rect = CGRect(origin: position, size: size)
        guard rect.width > 0, rect.height > 0 else { return nil }
        return rect
    }

    private static func axPointValue(_ element: AXUIElement, _ attribute: CFString) -> CGPoint? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &rawValue) == .success,
              let rawValue,
              CFGetTypeID(rawValue) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(rawValue, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgPoint else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func axSizeValue(_ element: AXUIElement, _ attribute: CFString) -> CGSize? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &rawValue) == .success,
              let rawValue,
              CFGetTypeID(rawValue) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(rawValue, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgSize else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    /// Convert an AX-returned rect (top-left origin, relative to the primary
    /// display) to Cocoa screen coordinates (bottom-left origin). The Y flip
    /// uses the primary screen's frame height — NSScreen.screens[0] is
    /// always the primary display per Apple docs.
    private static func convertAXRectToCocoa(_ rect: CGRect) -> CGRect {
        guard let primary = NSScreen.screens.first else { return rect }
        let primaryHeight = primary.frame.height
        let cocoaY = primaryHeight - rect.origin.y - rect.height
        return CGRect(x: rect.origin.x, y: cocoaY, width: rect.width, height: rect.height)
    }
    #endif

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

    // MARK: - Window Content Capture

    /// Synchronous best-effort extraction of visible text from the frontmost window.
    /// Designed to run inside a `Task.detached` block while the user is speaking.
    ///
    /// Tier 1 — Accessibility text (native apps, <5ms):
    ///   Reads the focused window's content elements via AX. Works for Mail, Notes,
    ///   Obsidian, Bear, most Cocoa apps. Silent Electron fallback to Tier 2.
    ///
    /// Tier 2 — Vision OCR on a silent window screenshot (~100–200ms):
    ///   `CGWindowListCreateImage` captures the specific window without any visual
    ///   disruption (no flash, no focus steal). `VNRecognizeTextRequest` (.fast mode)
    ///   extracts text locally. Requires Screen Recording permission (already granted
    ///   for meeting recording).
    ///
    /// Returns nil when the app is blocklisted, AX is denied, or both tiers fail.
    public static func captureWindowContent(maxChars: Int = 1500, timeoutSeconds: Float = 0.1) -> String? {
        #if canImport(AppKit)
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              !isBlocklisted(bundleID: frontApp.bundleIdentifier) else { return nil }
        let pid = frontApp.processIdentifier

        // Tier 1: Accessibility text tree
        #if canImport(ApplicationServices)
        if let text = axContentText(pid: pid, maxChars: maxChars, timeoutSeconds: timeoutSeconds) {
            return text
        }
        #endif

        // Tier 2: Silent window screenshot + Vision OCR
        guard let windowID = frontmostWindowID(pid: pid) else { return nil }
        return visionWindowOCR(windowID: windowID, maxChars: maxChars)
        #else
        return nil
        #endif
    }

    #if canImport(AppKit)
    /// CGWindowID of the frontmost on-screen window belonging to `pid`, or nil.
    private static func frontmostWindowID(pid: pid_t) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        // Window list is front-to-back; first match for this PID at layer 0 is frontmost.
        return list.first { dict in
            (dict[kCGWindowOwnerPID as String] as? Int32) == pid &&
            (dict[kCGWindowLayer as String] as? Int) == 0
        }.flatMap { dict in
            dict[kCGWindowNumber as String] as? CGWindowID
        }
    }
    #endif

    #if canImport(AppKit) && canImport(ApplicationServices)
    /// Lightweight AX text extraction: checks the focused window's immediate
    /// content elements (AXTextArea, AXWebArea, AXScrollArea) up to one level
    /// deep. Avoids full-tree walks that stall on complex Electron shells.
    private static func axContentText(pid: pid_t, maxChars: Int, timeoutSeconds: Float) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeoutSeconds)

        guard let window: AXUIElement = copyAXAttribute(app, kAXFocusedWindowAttribute as CFString) else {
            return nil
        }

        // Some native text editors expose the whole document directly.
        if let doc: String = copyAXAttribute(window, kAXDocumentAttribute as CFString), !doc.isEmpty {
            return doc.count > maxChars ? String(doc.prefix(maxChars)) + "…" : doc
        }

        let contentRoles: Set<String> = ["AXTextArea", "AXWebArea", "AXTextView"]
        var collected: [String] = []

        func harvest(_ element: AXUIElement) {
            guard collected.joined().count < maxChars else { return }
            if let role: String = copyAXAttribute(element, kAXRoleAttribute as CFString),
               contentRoles.contains(role),
               let value: String = copyAXAttribute(element, kAXValueAttribute as CFString),
               !value.isEmpty {
                collected.append(value)
            }
        }

        // Walk immediate children, then one level deeper inside scroll areas.
        if let children: [AXUIElement] = copyAXAttribute(window, kAXChildrenAttribute as CFString) {
            for child in children {
                harvest(child)
                if let grandchildren: [AXUIElement] = copyAXAttribute(child, kAXChildrenAttribute as CFString) {
                    for grandchild in grandchildren { harvest(grandchild) }
                }
            }
        }

        let result = collected.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return nil }
        return result.count > maxChars ? String(result.prefix(maxChars)) + "…" : result
    }
    #endif

    /// Captures a silent screenshot of the given window and extracts text with
    /// Vision OCR (.fast mode, no language correction). Returns nil if Screen
    /// Recording permission is unavailable or the window is gone.
    private static func visionWindowOCR(windowID: CGWindowID, maxChars: Int) -> String? {
        #if canImport(Vision) && canImport(AppKit)
        // TODO: migrate to SCScreenshotManager when the call site becomes async.
        // CGWindowListCreateImage is deprecated in macOS 14 but still functional;
        // SCScreenshotManager requires an async context incompatible with this sync path.
        guard let image = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .nominalResolution]
        ) else { return nil }

        var extracted: String?
        let request = VNRecognizeTextRequest { req, _ in
            guard let observations = req.results as? [VNRecognizedTextObservation] else { return }
            let text = observations
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: " ")
            extracted = text.isEmpty ? nil : text
        }
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false

        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])

        guard let text = extracted, !text.isEmpty else { return nil }
        return text.count > maxChars ? String(text.prefix(maxChars)) + "…" : text
        #else
        return nil
        #endif
    }
}
