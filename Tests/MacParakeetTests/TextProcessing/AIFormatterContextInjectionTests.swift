import XCTest
@testable import MacParakeetCore

final class AIFormatterContextInjectionTests: XCTestCase {
    private let simpleTemplate = """
        Clean this up.

        Input: {{TRANSCRIPT}}
        """

    private let legacyV2Template = """
        You are a transcription cleanup assistant.

        Instructions: do stuff.

        Raw transcript:
        {{TRANSCRIPT}}
        """

    // MARK: - No-op cases

    func testNilContextReturnsTemplateUnchanged() {
        let result = AIFormatter.injectContextIntoPrompt(template: simpleTemplate, context: nil)
        XCTAssertEqual(result, simpleTemplate)
    }

    func testEmptyContextReturnsTemplateUnchanged() {
        let result = AIFormatter.injectContextIntoPrompt(template: simpleTemplate, context: AppContext())
        XCTAssertEqual(result, simpleTemplate)
    }

    func testBundleIDOnlyContextReturnsTemplateUnchanged() {
        let ctx = AppContext(bundleID: "com.apple.mail")
        let result = AIFormatter.injectContextIntoPrompt(template: simpleTemplate, context: ctx)
        XCTAssertEqual(result, simpleTemplate)
    }

    // MARK: - Injection

    func testInjectsContextBeforeInputLine() {
        let ctx = AppContext(windowTitle: "Chat with Yeswanth")
        let result = AIFormatter.injectContextIntoPrompt(template: simpleTemplate, context: ctx)

        // The context preamble header must appear.
        XCTAssertTrue(result.contains("App context"))
        // The window title must make it in.
        XCTAssertTrue(result.contains("- Window: Chat with Yeswanth"))
        // The `{{TRANSCRIPT}}` placeholder must still exist, untouched, so
        // LLMService.renderPrompt can substitute it normally.
        XCTAssertTrue(result.contains("{{TRANSCRIPT}}"))
        // The preamble must appear before the "Input:" line, not after.
        let preambleRange = result.range(of: "App context")!
        let inputRange = result.range(of: "Input: {{TRANSCRIPT}}")!
        XCTAssertTrue(preambleRange.lowerBound < inputRange.lowerBound)
    }

    func testInjectsContextBeforeRawTranscriptLine() {
        let ctx = AppContext(windowTitle: "Inbox — jensen@fastmail.com")
        let result = AIFormatter.injectContextIntoPrompt(template: legacyV2Template, context: ctx)

        XCTAssertTrue(result.contains("- Window: Inbox — jensen@fastmail.com"))
        XCTAssertTrue(result.contains("{{TRANSCRIPT}}"))

        let preambleRange = result.range(of: "App context")!
        // "Raw transcript:" should still precede the placeholder.
        let rawLineRange = result.range(of: "Raw transcript:")!
        let placeholderRange = result.range(of: "{{TRANSCRIPT}}")!
        XCTAssertTrue(preambleRange.lowerBound < rawLineRange.lowerBound)
        XCTAssertTrue(rawLineRange.lowerBound < placeholderRange.lowerBound)
    }

    func testTemplateWithoutPlaceholderGetsPrepended() {
        let template = "Clean the input."
        let ctx = AppContext(windowTitle: "Something")
        let result = AIFormatter.injectContextIntoPrompt(template: template, context: ctx)
        XCTAssertTrue(result.hasPrefix("App context") || result.contains("App context"))
        XCTAssertTrue(result.contains("Clean the input."))
    }

    func testIncludesAllFilledFields() {
        let ctx = AppContext(
            windowTitle: "Review — PR #123",
            focusedFieldValue: "LGTM! Ship it.",
            selectedText: "needs tests"
        )
        let result = AIFormatter.injectContextIntoPrompt(template: simpleTemplate, context: ctx)
        XCTAssertTrue(result.contains("Review — PR #123"))
        XCTAssertTrue(result.contains("LGTM! Ship it."))
        XCTAssertTrue(result.contains("needs tests"))
    }

    // MARK: - Render still works after injection

    func testRenderedPromptAfterInjectionSubstitutesTranscript() {
        let ctx = AppContext(windowTitle: "Chat with Yeswanth")
        let contextualTemplate = AIFormatter.injectContextIntoPrompt(template: simpleTemplate, context: ctx)
        let rendered = AIFormatter.renderPrompt(template: contextualTemplate, transcript: "just once")

        // After rendering, the placeholder must be gone and the transcript present.
        XCTAssertFalse(rendered.contains("{{TRANSCRIPT}}"))
        XCTAssertTrue(rendered.contains("just once"))
        // The context must have survived the render.
        XCTAssertTrue(rendered.contains("Chat with Yeswanth"))
    }
}
