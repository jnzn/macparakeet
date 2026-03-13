import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class TranscriptChatViewModelTests: XCTestCase {
    var viewModel: TranscriptChatViewModel!
    var mockService: MockLLMService!

    override func setUp() {
        viewModel = TranscriptChatViewModel()
        mockService = MockLLMService()
        viewModel.configure(llmService: mockService, transcriptText: "Test transcript content here.")
    }

    // MARK: - Initial State

    func testInitialState() {
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertEqual(viewModel.inputText, "")
        XCTAssertFalse(viewModel.isStreaming)
        XCTAssertNil(viewModel.errorMessage)
    }

    // MARK: - Send Message

    func testSendMessageAppendsUserAndAssistant() async throws {
        mockService.streamTokens = ["Hello", " there"]
        viewModel.inputText = "What is this about?"

        viewModel.sendMessage()

        // Wait for streaming to complete
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(viewModel.messages.count, 2)
        XCTAssertEqual(viewModel.messages[0].role, .user)
        XCTAssertEqual(viewModel.messages[0].content, "What is this about?")
        XCTAssertEqual(viewModel.messages[1].role, .assistant)
        XCTAssertEqual(viewModel.messages[1].content, "Hello there")
        XCTAssertFalse(viewModel.messages[1].isStreaming)
    }

    func testSendMessageClearsInput() {
        viewModel.inputText = "My question"
        viewModel.sendMessage()
        XCTAssertEqual(viewModel.inputText, "")
    }

    func testEmptyInputDoesNotSend() {
        viewModel.inputText = "   "
        viewModel.sendMessage()
        XCTAssertTrue(viewModel.messages.isEmpty)
    }

    func testSendMessageWhileStreamingDoesNotSend() async throws {
        mockService.streamTokens = ["slow"]
        viewModel.inputText = "First"
        viewModel.sendMessage()

        // Try to send again immediately
        viewModel.inputText = "Second"
        viewModel.sendMessage()

        try await Task.sleep(nanoseconds: 200_000_000)

        // Only the first message pair should exist
        XCTAssertEqual(viewModel.messages.count, 2)
        XCTAssertEqual(viewModel.messages[0].content, "First")
    }

    // MARK: - Error Handling

    func testSendMessageWithError() async throws {
        mockService.errorToThrow = LLMError.authenticationFailed
        viewModel.inputText = "Will fail"

        viewModel.sendMessage()

        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isStreaming)
        // User message stays, failed assistant message removed (empty content)
        XCTAssertEqual(viewModel.messages.count, 1)
        XCTAssertEqual(viewModel.messages[0].role, .user)
    }

    // MARK: - Clear History

    func testClearHistory() async throws {
        mockService.streamTokens = ["response"]
        viewModel.inputText = "Question"
        viewModel.sendMessage()

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(viewModel.messages.count, 2)

        viewModel.clearHistory()

        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertEqual(viewModel.inputText, "")
        XCTAssertNil(viewModel.errorMessage)
    }

    // MARK: - Update Transcript

    func testUpdateTranscriptClearsHistory() async throws {
        mockService.streamTokens = ["response"]
        viewModel.inputText = "Question"
        viewModel.sendMessage()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(viewModel.messages.count, 2)

        viewModel.updateTranscript("New transcript text")

        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertEqual(viewModel.inputText, "")
    }

    // MARK: - Cancel Streaming

    func testCancelStreaming() {
        viewModel.inputText = "Question"
        viewModel.sendMessage()

        // Cancel immediately
        viewModel.cancelStreaming()

        XCTAssertFalse(viewModel.isStreaming)
    }

    func testCancelStreamingDoesNotSurfaceError() async throws {
        mockService.streamTokens = ["slow"]
        viewModel.inputText = "Question"
        viewModel.sendMessage()

        viewModel.cancelStreaming()

        // Wait for cancelled task to settle
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(viewModel.errorMessage, "CancellationError should not surface in UI")
    }

    func testUpdateLLMServiceClearsHistory() async throws {
        mockService.streamTokens = ["response"]
        viewModel.inputText = "Question"
        viewModel.sendMessage()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(viewModel.messages.count, 2)

        let newService = MockLLMService()
        viewModel.updateLLMService(newService)

        XCTAssertTrue(viewModel.messages.isEmpty, "Provider swap should clear chat history")
    }

    // MARK: - Update LLM Service

    func testUpdateLLMServiceNilDisablesChat() {
        viewModel.updateLLMService(nil)
        viewModel.inputText = "Should not send"
        viewModel.sendMessage()
        XCTAssertTrue(viewModel.messages.isEmpty)
    }

    func testUpdateLLMServiceSwapsProvider() async throws {
        let newService = MockLLMService()
        newService.streamTokens = ["new", " provider"]
        viewModel.updateLLMService(newService)

        viewModel.inputText = "Hello"
        viewModel.sendMessage()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(viewModel.messages[1].content, "new provider")
    }
}
