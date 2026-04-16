import XCTest
@testable import MacParakeetCore

final class AIAssistantServiceTests: XCTestCase {
    // MARK: - Config defaults

    func testClaudeConfigDefaults() {
        let config = AIAssistantConfig.defaultClaude
        XCTAssertEqual(config.provider, .claude)
        XCTAssertTrue(config.commandTemplate.contains("--dangerously-skip-permissions"))
        XCTAssertTrue(config.commandTemplate.contains("claude"))
        XCTAssertEqual(config.modelName, "sonnet")
    }

    func testCodexConfigDefaults() {
        let config = AIAssistantConfig.defaultCodex
        XCTAssertEqual(config.provider, .codex)
        XCTAssertTrue(config.commandTemplate.contains("--dangerously-bypass-approvals-and-sandbox"))
        XCTAssertTrue(config.commandTemplate.contains("codex"))
        XCTAssertEqual(config.modelName, "gpt-5.2")
    }

    func testTimeoutFloorsAtMinimum() {
        let config = AIAssistantConfig(provider: .claude, timeoutSeconds: 1)
        XCTAssertEqual(config.timeoutSeconds, AIAssistantConfig.minimumTimeout)
    }

    func testEffectiveCommandTemplateAppendsModelWhenMissing() {
        let config = AIAssistantConfig(
            provider: .claude,
            commandTemplate: "claude -p",
            modelName: "opus"
        )
        XCTAssertEqual(config.effectiveCommandTemplate, "claude -p --model opus")
    }

    func testEffectiveCommandTemplatePreservesExistingModelFlag() {
        let config = AIAssistantConfig(
            provider: .claude,
            commandTemplate: "claude -p --model haiku",
            modelName: "opus"
        )
        // User-provided --model wins; modelName field ignored.
        XCTAssertEqual(config.effectiveCommandTemplate, "claude -p --model haiku")
    }

    // MARK: - Config store round-trip

    func testConfigStoreRoundTrip() throws {
        let defaults = UserDefaults(suiteName: "AIAssistantServiceTests.roundTrip")!
        defaults.removePersistentDomain(forName: "AIAssistantServiceTests.roundTrip")
        let store = AIAssistantConfigStore(defaults: defaults)

        XCTAssertNil(store.load())

        let customColor = CodableColor(red: 0.2, green: 0.5, blue: 0.8, opacity: 0.75)
        let original = AIAssistantConfig(
            provider: .codex,
            commandTemplate: "codex custom --extra-flag",
            modelName: "gpt-5.2-pro",
            timeoutSeconds: 240,
            bubbleBackgroundColor: customColor
        )
        try store.save(original)

        let loaded = store.load()
        XCTAssertEqual(loaded, original)
        XCTAssertEqual(loaded?.bubbleBackgroundColor, customColor)

        store.delete()
        XCTAssertNil(store.load())
    }

    /// Existing UserDefaults blobs predate the `bubbleBackgroundColor`
    /// field. They must decode cleanly with `bubbleBackgroundColor == nil`,
    /// at which point `effectiveBubbleBackgroundColor` resolves to the
    /// shipped default. Guards against a regression where adding the field
    /// inadvertently makes the decoder pick up the default and store it as
    /// a non-nil value (which would defeat the optional pattern).
    func testConfigStoreNilBubbleColorDecodesAsNilNotDefault() throws {
        let defaults = UserDefaults(suiteName: "AIAssistantServiceTests.nilColor")!
        defaults.removePersistentDomain(forName: "AIAssistantServiceTests.nilColor")
        let store = AIAssistantConfigStore(defaults: defaults)

        let original = AIAssistantConfig(provider: .claude)
        XCTAssertNil(original.bubbleBackgroundColor)
        try store.save(original)

        let loaded = store.load()
        XCTAssertNotNil(loaded)
        XCTAssertNil(loaded?.bubbleBackgroundColor)
        XCTAssertEqual(
            loaded?.effectiveBubbleBackgroundColor,
            AIAssistantConfig.defaultBubbleBackgroundColor
        )
    }

    /// Synthesize a "legacy" JSON blob — one that was written before the
    /// `bubbleBackgroundColor` field existed — and confirm it decodes
    /// cleanly. Backwards-compat insurance for users upgrading across this
    /// change.
    func testLegacyConfigJSONDecodesWithoutBubbleColor() throws {
        let legacyJSON = """
            {
                "provider": "claude",
                "commandTemplate": "claude --dangerously-skip-permissions -p",
                "modelName": "sonnet",
                "timeoutSeconds": 120
            }
            """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AIAssistantConfig.self, from: legacyJSON)
        XCTAssertEqual(decoded.provider, .claude)
        XCTAssertNil(decoded.bubbleBackgroundColor)
        XCTAssertNil(decoded.hotkeyTrigger)
        XCTAssertEqual(
            decoded.effectiveBubbleBackgroundColor,
            AIAssistantConfig.defaultBubbleBackgroundColor
        )
    }

    // MARK: - Prompt rendering

    func testSystemPromptIncludesSelection() {
        let system = AIAssistantService.renderSystemPrompt(selection: "let x = 42")
        XCTAssertTrue(system.contains("let x = 42"))
        XCTAssertTrue(system.contains("Selected text"))
    }

    func testUserPromptWithoutHistoryIsJustQuestion() {
        let user = AIAssistantService.renderUserPrompt(history: [], question: "  What does this do?  ")
        XCTAssertEqual(user, "What does this do?")
    }

    func testUserPromptWithHistoryReplaysTurns() {
        let history = [
            AIAssistantTurn(question: "Explain this", response: "It's a constant."),
            AIAssistantTurn(question: "Is it mutable?", response: "No — `let` is immutable."),
        ]
        let user = AIAssistantService.renderUserPrompt(history: history, question: "What about optimization?")
        XCTAssertTrue(user.contains("Conversation so far:"))
        XCTAssertTrue(user.contains("Turn 1 question: Explain this"))
        XCTAssertTrue(user.contains("Turn 2 answer: No — `let` is immutable."))
        XCTAssertTrue(user.contains("New question: What about optimization?"))
    }

    // MARK: - Service ask()

    func testAskBailsWhenNoConfig() async {
        let service = AIAssistantService(
            executor: MockExecutor(),
            configProvider: { nil }
        )
        do {
            _ = try await service.ask(AIAssistantRequest(selection: "x", question: "y"))
            XCTFail("Expected commandNotConfigured error")
        } catch let error as LocalCLIError {
            if case .commandNotConfigured = error {} else {
                XCTFail("Expected .commandNotConfigured, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAskForwardsRenderedPromptsAndConfigToExecutor() async throws {
        let mockExecutor = MockExecutor()
        mockExecutor.stubbedResponse = "  Here is the answer.  "
        let config = AIAssistantConfig(
            provider: .claude,
            commandTemplate: "claude -p",
            modelName: "sonnet",
            timeoutSeconds: 180
        )
        let service = AIAssistantService(
            executor: mockExecutor,
            configProvider: { config }
        )
        let request = AIAssistantRequest(selection: "print(\"hi\")", question: "what does this print?")

        let output = try await service.ask(request)

        XCTAssertEqual(output, "Here is the answer.")
        XCTAssertEqual(mockExecutor.invocations.count, 1)
        let call = mockExecutor.invocations[0]
        XCTAssertTrue(call.systemPrompt.contains("print(\"hi\")"))
        XCTAssertTrue(call.userPrompt.contains("what does this print?"))
        XCTAssertEqual(call.config.commandTemplate, "claude -p --model sonnet")
        XCTAssertEqual(call.config.timeoutSeconds, 180)
    }

    func testAskPropagatesExecutorErrors() async {
        let mockExecutor = MockExecutor()
        mockExecutor.errorToThrow = LocalCLIError.timeout(seconds: 60)
        let service = AIAssistantService(
            executor: mockExecutor,
            configProvider: { AIAssistantConfig.defaultClaude }
        )
        do {
            _ = try await service.ask(AIAssistantRequest(selection: "x", question: "y"))
            XCTFail("Expected timeout error")
        } catch let error as LocalCLIError {
            if case .timeout(let seconds) = error {
                XCTAssertEqual(seconds, 60)
            } else {
                XCTFail("Expected .timeout, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAskRoutesOllamaProviderToOllamaExecutor() async throws {
        let cliExecutor = MockExecutor()
        let ollamaExecutor = MockExecutor()
        ollamaExecutor.stubbedResponse = "remote answer"
        let service = AIAssistantService(
            executor: cliExecutor,
            ollamaExecutor: ollamaExecutor,
            configProvider: {
                AIAssistantConfig(provider: .ollama, timeoutSeconds: 45)
            }
        )

        let output = try await service.ask(
            AIAssistantRequest(selection: "x", question: "answer this")
        )

        XCTAssertEqual(output, "remote answer")
        XCTAssertTrue(cliExecutor.invocations.isEmpty)
        XCTAssertEqual(ollamaExecutor.invocations.count, 1)
        XCTAssertEqual(ollamaExecutor.invocations[0].config.timeoutSeconds, 45)
    }

    func testAskRoutesOllamaOverrideToOllamaExecutor() async throws {
        let cliExecutor = MockExecutor()
        let ollamaExecutor = MockExecutor()
        ollamaExecutor.stubbedResponse = "override answer"
        let service = AIAssistantService(
            executor: cliExecutor,
            ollamaExecutor: ollamaExecutor,
            configProvider: {
                AIAssistantConfig(provider: .claude, timeoutSeconds: 30)
            }
        )

        let output = try await service.ask(
            AIAssistantRequest(
                selection: "x",
                question: "answer this",
                providerOverride: .ollama
            )
        )

        XCTAssertEqual(output, "override answer")
        XCTAssertTrue(cliExecutor.invocations.isEmpty)
        XCTAssertEqual(ollamaExecutor.invocations.count, 1)
    }
}

// MARK: - Mock executor

private final class MockExecutor: AIAssistantExecuting, @unchecked Sendable {
    struct Invocation {
        let systemPrompt: String
        let userPrompt: String
        let config: LocalCLIConfig
    }

    var invocations: [Invocation] = []
    var stubbedResponse: String = "ok"
    var errorToThrow: Error?

    func execute(
        systemPrompt: String,
        userPrompt: String,
        config: LocalCLIConfig
    ) async throws -> String {
        invocations.append(Invocation(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            config: config
        ))
        if let errorToThrow {
            throw errorToThrow
        }
        return stubbedResponse
    }
}
