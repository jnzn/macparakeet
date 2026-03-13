import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class LLMSettingsViewModelTests: XCTestCase {
    var viewModel: LLMSettingsViewModel!
    var mockConfigStore: MockLLMConfigStore!
    var mockClient: MockLLMClient!

    override func setUp() {
        viewModel = LLMSettingsViewModel()
        mockConfigStore = MockLLMConfigStore()
        mockClient = MockLLMClient()
    }

    // MARK: - Defaults

    func testDefaultValuesAfterInit() {
        XCTAssertEqual(viewModel.selectedProviderID, .openai)
        XCTAssertEqual(viewModel.apiKeyInput, "")
        XCTAssertEqual(viewModel.modelName, "gpt-4o")
        XCTAssertEqual(viewModel.baseURLOverride, "")
        XCTAssertEqual(viewModel.connectionTestState, .idle)
        XCTAssertFalse(viewModel.isConfigured)
        XCTAssertTrue(viewModel.requiresAPIKey)
    }

    // MARK: - Provider Change

    func testProviderChangeUpdatesModelName() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)

        viewModel.selectedProviderID = .anthropic
        XCTAssertEqual(viewModel.modelName, "claude-sonnet-4-20250514")

        viewModel.selectedProviderID = .gemini
        XCTAssertEqual(viewModel.modelName, "gemini-2.0-flash")

        viewModel.selectedProviderID = .ollama
        XCTAssertEqual(viewModel.modelName, "llama3.2")
    }

    func testOllamaDoesNotRequireAPIKey() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.selectedProviderID = .ollama
        XCTAssertFalse(viewModel.requiresAPIKey)
    }

    func testCloudProviderRequiresAPIKey() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.selectedProviderID = .openai
        XCTAssertTrue(viewModel.requiresAPIKey)
    }

    // MARK: - Save

    func testSavePersistsToStore() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.selectedProviderID = .openai
        viewModel.apiKeyInput = "sk-test-123"
        viewModel.modelName = "gpt-4o-mini"

        viewModel.saveConfiguration()

        let saved = mockConfigStore.config
        XCTAssertNotNil(saved)
        XCTAssertEqual(saved?.id, .openai)
        XCTAssertEqual(saved?.apiKey, "sk-test-123")
        XCTAssertEqual(saved?.modelName, "gpt-4o-mini")
    }

    func testSaveWithBaseURLOverride() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.selectedProviderID = .custom
        viewModel.modelName = "my-model"
        viewModel.baseURLOverride = "https://my-server.com/v1"

        viewModel.saveConfiguration()

        let saved = mockConfigStore.config
        XCTAssertEqual(saved?.baseURL.absoluteString, "https://my-server.com/v1")
    }

    // MARK: - Load Existing

    func testLoadsExistingConfigOnConfigure() {
        mockConfigStore.config = .openai(apiKey: "sk-existing", model: "gpt-4")

        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)

        XCTAssertEqual(viewModel.selectedProviderID, .openai)
        XCTAssertEqual(viewModel.apiKeyInput, "sk-existing")
        XCTAssertEqual(viewModel.modelName, "gpt-4")
    }

    // MARK: - isConfigured

    func testIsConfiguredWhenStoreHasConfig() {
        mockConfigStore.config = .openai(apiKey: "sk-test")
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        XCTAssertTrue(viewModel.isConfigured)
    }

    func testIsConfiguredFalseWhenStoreEmpty() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        XCTAssertFalse(viewModel.isConfigured)
    }

    // MARK: - Clear

    func testClearResetsState() {
        mockConfigStore.config = .openai(apiKey: "sk-test")
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)

        viewModel.clearConfiguration()

        XCTAssertNil(mockConfigStore.config)
        XCTAssertEqual(viewModel.apiKeyInput, "")
        XCTAssertEqual(viewModel.connectionTestState, .idle)
        XCTAssertFalse(viewModel.isConfigured)
    }

    // MARK: - Test Connection

    func testConnectionSuccess() async throws {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.apiKeyInput = "sk-test"

        viewModel.testConnection()

        // Wait for async task
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(viewModel.connectionTestState, .success)
    }

    func testConnectionFailure() async throws {
        mockClient.testConnectionError = LLMError.authenticationFailed
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.apiKeyInput = "sk-bad"

        viewModel.testConnection()

        try await Task.sleep(nanoseconds: 100_000_000)
        if case .error = viewModel.connectionTestState {
            // Expected
        } else {
            XCTFail("Expected error state, got \(viewModel.connectionTestState)")
        }
    }

    // MARK: - Configuration Changed Callback

    func testSaveCallsOnConfigurationChanged() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        var callbackCalled = false
        viewModel.onConfigurationChanged = { callbackCalled = true }
        viewModel.apiKeyInput = "sk-test"
        viewModel.saveConfiguration()
        XCTAssertTrue(callbackCalled)
    }

    func testClearCallsOnConfigurationChanged() {
        mockConfigStore.config = .openai(apiKey: "sk-test")
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        var callbackCalled = false
        viewModel.onConfigurationChanged = { callbackCalled = true }
        viewModel.clearConfiguration()
        XCTAssertTrue(callbackCalled)
    }

    // MARK: - Provider switch clears API key for local

    func testSwitchingToLocalClearsAPIKey() {
        viewModel.configure(configStore: mockConfigStore, llmClient: mockClient)
        viewModel.apiKeyInput = "sk-test"

        viewModel.selectedProviderID = .ollama
        XCTAssertEqual(viewModel.apiKeyInput, "")
    }
}
