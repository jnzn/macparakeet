import ApplicationServices
import Foundation

public protocol AccessibilityServiceProtocol: Sendable {
    func getSelectedTextWithSource(maxCharacters: Int?) throws -> (String, AccessibilitySelectionSource)
    func getSelectedText(maxCharacters: Int?) throws -> String
}

public extension AccessibilityServiceProtocol {
    func getSelectedTextWithSource() throws -> (String, AccessibilitySelectionSource) {
        try getSelectedTextWithSource(maxCharacters: nil)
    }

    func getSelectedText() throws -> String {
        try getSelectedText(maxCharacters: nil)
    }
}

public enum AccessibilitySelectionSource: String, Sendable, Equatable {
    case selectedTextAttribute
    case parameterizedString
    case valueSubstring
}

public enum AccessibilityServiceError: Error, LocalizedError, Equatable {
    case notAuthorized
    case noFocusedElement
    case noSelectedText
    case textTooLong(max: Int, actual: Int)
    case unsupportedElement

    public var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Accessibility permission is required to read selected text."
        case .noFocusedElement:
            return "No focused text field was found."
        case .noSelectedText:
            return "Select text first."
        case .textTooLong(let max, let actual):
            return "Selection is too long (\(actual) chars). Maximum is \(max)."
        case .unsupportedElement:
            return "The focused element does not expose selected text."
        }
    }
}

protocol AccessibilityBackend: Sendable {
    func isTrusted() -> Bool
    func focusedElement() -> AXUIElement?
    func role(of element: AXUIElement) -> String?
    func selectedText(of element: AXUIElement) -> String?
    func selectedRange(of element: AXUIElement) -> CFRange?
    func fullValue(of element: AXUIElement) -> String?
    func string(for range: CFRange, of element: AXUIElement) -> String?
}

struct SystemAccessibilityBackend: AccessibilityBackend {
    func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    func focusedElement() -> AXUIElement? {
        let systemElement = AXUIElementCreateSystemWide()
        guard let value = copyAttributeValue(
            element: systemElement,
            attribute: kAXFocusedUIElementAttribute as CFString
        ) else {
            return nil
        }

        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value as AnyObject, to: AXUIElement.self)
    }

    func role(of element: AXUIElement) -> String? {
        guard let value = copyAttributeValue(
            element: element,
            attribute: kAXRoleAttribute as CFString
        ) else {
            return nil
        }
        return value as? String
    }

    func selectedText(of element: AXUIElement) -> String? {
        guard let value = copyAttributeValue(
            element: element,
            attribute: kAXSelectedTextAttribute as CFString
        ) else {
            return nil
        }
        return value as? String
    }

    func selectedRange(of element: AXUIElement) -> CFRange? {
        guard let value = copyAttributeValue(
            element: element,
            attribute: kAXSelectedTextRangeAttribute as CFString
        ) else {
            return nil
        }

        guard CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeDowncast(value as AnyObject, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else {
            return nil
        }

        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else {
            return nil
        }
        return range
    }

    func fullValue(of element: AXUIElement) -> String? {
        guard let value = copyAttributeValue(
            element: element,
            attribute: kAXValueAttribute as CFString
        ) else {
            return nil
        }
        return value as? String
    }

    func string(for range: CFRange, of element: AXUIElement) -> String? {
        var mutableRange = range
        guard let rangeValue = AXValueCreate(.cfRange, &mutableRange) else {
            return nil
        }

        var raw: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &raw
        )
        guard status == .success, let raw else {
            return nil
        }
        return raw as? String
    }

    private func copyAttributeValue(element: AXUIElement, attribute: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard status == .success else {
            return nil
        }
        return value
    }
}

public final class AccessibilityService: AccessibilityServiceProtocol, @unchecked Sendable {
    private let backend: any AccessibilityBackend
    private let defaultMaxCharacters: Int

    public init(defaultMaxCharacters: Int = 16_000) {
        self.defaultMaxCharacters = defaultMaxCharacters
        self.backend = SystemAccessibilityBackend()
    }

    init(
        defaultMaxCharacters: Int = 16_000,
        backend: any AccessibilityBackend
    ) {
        self.defaultMaxCharacters = defaultMaxCharacters
        self.backend = backend
    }

    public func getSelectedText(maxCharacters: Int?) throws -> String {
        try getSelectedTextWithSource(maxCharacters: maxCharacters).0
    }

    /// Best-effort read of the currently focused field's text value + its
    /// selected substring. Returns nil fields for any failure (no permission,
    /// no focused element, Electron-flavored empty AX tree, etc.) — never
    /// throws. Intended for assembling `AppContext` as a cleanup-prompt hint;
    /// the stricter `getSelectedText(maxCharacters:)` throws and is used by
    /// features that actually depend on a selection existing.
    ///
    /// `timeoutSeconds` bounds any one AX call so a busy target app can't
    /// stall the caller. Values that exceed the budget silently return nil.
    public func captureFocusSnapshot(
        timeoutSeconds: Float = 0.15,
        maxCharacters: Int = 1_000
    ) -> (focusedFieldValue: String?, selectedText: String?) {
        guard backend.isTrusted(),
              let element = backend.focusedElement() else {
            return (nil, nil)
        }
        #if canImport(ApplicationServices)
        AXUIElementSetMessagingTimeout(element, timeoutSeconds)
        #endif

        // Skip password fields regardless of other guards. AX exposes secure
        // field values as empty anyway, but being explicit is cheap.
        if let role = backend.role(of: element), role == "AXSecureTextField" {
            return (nil, nil)
        }

        let field = backend.fullValue(of: element)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let selection = backend.selectedText(of: element)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let truncField = field.flatMap { Self.truncate($0, limit: maxCharacters) }
        let truncSelection = selection.flatMap { Self.truncate($0, limit: maxCharacters) }
        return (
            (truncField?.isEmpty ?? true) ? nil : truncField,
            (truncSelection?.isEmpty ?? true) ? nil : truncSelection
        )
    }

    private static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let idx = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<idx]) + "…"
    }

    public func getSelectedTextWithSource(maxCharacters: Int?) throws -> (String, AccessibilitySelectionSource) {
        let max = maxCharacters ?? defaultMaxCharacters
        guard backend.isTrusted() else {
            throw AccessibilityServiceError.notAuthorized
        }
        guard let element = backend.focusedElement() else {
            throw AccessibilityServiceError.noFocusedElement
        }

        if let direct = normalized(backend.selectedText(of: element)), !direct.isEmpty {
            return (try validatedLength(direct, max: max), .selectedTextAttribute)
        }

        guard let range = backend.selectedRange(of: element) else {
            throw AccessibilityServiceError.unsupportedElement
        }
        guard range.length > 0 else {
            throw AccessibilityServiceError.noSelectedText
        }

        if let parameterized = normalized(backend.string(for: range, of: element)), !parameterized.isEmpty {
            return (try validatedLength(parameterized, max: max), .parameterizedString)
        }

        guard let value = backend.fullValue(of: element) else {
            throw AccessibilityServiceError.unsupportedElement
        }

        let ns = value as NSString
        let nsRange = NSRange(location: range.location, length: range.length)
        guard nsRange.location >= 0,
              nsRange.length >= 0,
              nsRange.location + nsRange.length <= ns.length else {
            throw AccessibilityServiceError.unsupportedElement
        }

        guard let extracted = normalized(ns.substring(with: nsRange)), !extracted.isEmpty else {
            throw AccessibilityServiceError.noSelectedText
        }
        return (try validatedLength(extracted, max: max), .valueSubstring)
    }

    private func normalized(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func validatedLength(_ text: String, max: Int) throws -> String {
        if text.count > max {
            throw AccessibilityServiceError.textTooLong(max: max, actual: text.count)
        }
        return text
    }
}
