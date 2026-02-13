import XCTest
@testable import MacParakeetCore

final class MLXLLMServiceTests: XCTestCase {
    func testGenerateRejectsEmptyPromptBeforeModelLoad() async {
        let service = MLXLLMService()
        let request = LLMRequest(prompt: "   ", options: .init(timeoutSeconds: 1))

        do {
            _ = try await service.generate(request: request)
            XCTFail("Expected invalidPrompt error")
        } catch let error as LLMServiceError {
            guard case .invalidPrompt = error else {
                XCTFail("Expected invalidPrompt, got \(error)")
                return
            }
        } catch {
            XCTFail("Expected LLMServiceError.invalidPrompt, got \(error)")
        }
    }
}
