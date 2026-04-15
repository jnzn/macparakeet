import XCTest
@testable import MacParakeetCore

/// Unit coverage for the AX-first path of `SelectionReader`. The Cmd+C probe
/// depends on a real AXIsProcessTrusted() check + a real frontmost-app,
/// so it can't be unit-tested here — covered manually in chunk C smoke.
@MainActor
final class SelectionReaderTests: XCTestCase {
    func testReturnsAccessibilityResultWhenAXSucceeds() throws {
        let mock = MockAccessibilityService()
        mock.stubbedText = "hello selection"
        let reader = SelectionReader(accessibility: mock)

        let result = try reader.readSelection()

        XCTAssertEqual(result.text, "hello selection")
        XCTAssertEqual(result.source, .accessibility)
        XCTAssertEqual(mock.getSelectedCallCount, 1)
    }

    func testNotAuthorizedErrorPropagatesWithoutProbe() {
        let mock = MockAccessibilityService()
        mock.errorToThrow = AccessibilityServiceError.notAuthorized
        let reader = SelectionReader(accessibility: mock)

        do {
            _ = try reader.readSelection()
            XCTFail("Expected accessibilityPermissionRequired error")
        } catch SelectionReader.Error.accessibilityPermissionRequired {
            // expected
        } catch {
            XCTFail("Expected accessibilityPermissionRequired, got \(error)")
        }
        XCTAssertEqual(mock.getSelectedCallCount, 1)
    }

    // The remaining paths (noSelectedText → Cmd+C probe, unsupportedElement →
    // Cmd+C probe) touch AppKit / CGEvent / NSPasteboard and require real
    // process state. Covered in manual smoke testing against VS Code and
    // a native app.
}

private final class MockAccessibilityService: AccessibilityServiceProtocol, @unchecked Sendable {
    var stubbedText: String = ""
    var errorToThrow: Error?
    var getSelectedCallCount: Int = 0

    func getSelectedText(maxCharacters: Int?) throws -> String {
        getSelectedCallCount += 1
        if let errorToThrow { throw errorToThrow }
        return stubbedText
    }

    func getSelectedTextWithSource(maxCharacters: Int?) throws -> (String, AccessibilitySelectionSource) {
        (try getSelectedText(maxCharacters: maxCharacters), .selectedTextAttribute)
    }
}
