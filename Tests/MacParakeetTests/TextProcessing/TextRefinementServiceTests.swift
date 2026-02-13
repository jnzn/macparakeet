import XCTest
@testable import MacParakeetCore

final class TextRefinementServiceTests: XCTestCase {
    func testCleanModeReturnsDeterministicText() async {
        let service = TextRefinementService()
        let result = await service.refine(
            rawText: "um hello world",
            mode: .clean,
            customWords: [],
            snippets: []
        )

        XCTAssertEqual(result.text, "Hello world")
        XCTAssertEqual(result.path, .deterministic)
    }

    func testFormalModeUsesLLMWhenAvailable() async {
        let mockLLM = MockLLMService()
        await mockLLM.configureResponse(text: "Hello world from LLM.")
        let service = TextRefinementService(llmService: mockLLM)

        let result = await service.refine(
            rawText: "hello world",
            mode: .formal,
            customWords: [],
            snippets: []
        )

        XCTAssertEqual(result.text, "Hello world from LLM.")
        XCTAssertEqual(result.path, .llm)
        let requests = await mockLLM.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests[0].prompt.contains("formal"))
    }

    func testFormalModeFallsBackWhenLLMFails() async {
        let mockLLM = MockLLMService()
        await mockLLM.configureError(LLMServiceError.generationFailed("boom"))
        let service = TextRefinementService(llmService: mockLLM)

        let result = await service.refine(
            rawText: "um hello world",
            mode: .formal,
            customWords: [],
            snippets: []
        )

        XCTAssertEqual(result.text, "Hello world")
        XCTAssertEqual(result.path, .llmFallback)
        XCTAssertNotNil(result.fallbackReason)
    }
}
