import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class AIAssistantOnboardingViewModelTests: XCTestCase {

    // MARK: - Helpers

    private func makeStores() -> (AIAssistantConfigStore, OnboardingMockLLMConfigStore, UserDefaults) {
        let suite = "com.macparakeet.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (AIAssistantConfigStore(defaults: defaults), OnboardingMockLLMConfigStore(), defaults)
    }

    private func makeViewModel(
        dependencies: AIAssistantOnboardingDependencies,
        aiAssistantStore: AIAssistantConfigStore? = nil,
        llmConfigStore: OnboardingMockLLMConfigStore? = nil
    ) -> AIAssistantOnboardingViewModel {
        let (store, llmStore, _) = makeStores()
        return AIAssistantOnboardingViewModel(
            dependencies: dependencies,
            aiAssistantStore: aiAssistantStore ?? store,
            llmConfigStore: llmConfigStore ?? llmStore
        )
    }

    // MARK: - Card ordering

    func testInitialCardIsIntro() {
        let vm = makeViewModel(dependencies: StubDependencies())
        XCTAssertEqual(vm.card, .intro)
    }

    func testContinueFromIntroAdvancesToFirstProvider() {
        let vm = makeViewModel(dependencies: StubDependencies())
        vm.continueFromIntro()
        XCTAssertEqual(vm.card, .provider(.claude))
    }

    func testSkipAllJumpsToFinishedAndPersistsNothing() async throws {
        let (store, llm, _) = makeStores()
        let vm = AIAssistantOnboardingViewModel(
            dependencies: StubDependencies(),
            aiAssistantStore: store,
            llmConfigStore: llm
        )
        vm.skipAll()

        XCTAssertEqual(vm.card, .finished)
        let payload = try vm.finish()
        XCTAssertNil(payload.aiAssistantConfig)
        XCTAssertNil(payload.ollamaProviderConfig)
        XCTAssertNil(store.load())
        XCTAssertNil(llm.savedConfig)
    }

    func testSkipCurrentProviderAdvancesWithoutEnabling() {
        let vm = makeViewModel(dependencies: StubDependencies())
        vm.continueFromIntro()
        XCTAssertEqual(vm.card, .provider(.claude))

        vm.skipCurrentProvider()
        XCTAssertEqual(vm.card, .provider(.codex))
        XCTAssertFalse(vm.enabledProviders.contains(.claude))
    }

    func testGoBackMovesToPreviousCard() {
        let vm = makeViewModel(dependencies: StubDependencies())
        vm.continueFromIntro()
        vm.skipCurrentProvider()
        XCTAssertEqual(vm.card, .provider(.codex))

        vm.goBack()
        XCTAssertEqual(vm.card, .provider(.claude))
    }

    // MARK: - CLI detection

    func testDetectMarksFoundWhenBinaryResolves() async {
        let resolved = URL(fileURLWithPath: "/usr/local/bin/claude")
        let vm = makeViewModel(
            dependencies: StubDependencies(resolvedBinaries: ["claude": resolved])
        )
        await vm.detect(.claude)

        XCTAssertEqual(vm.cliDetection[.claude], .found(resolved))
    }

    func testDetectMarksNotFoundWhenBinaryMissing() async {
        let vm = makeViewModel(dependencies: StubDependencies())
        await vm.detect(.codex)

        XCTAssertEqual(vm.cliDetection[.codex], .notFound)
    }

    // MARK: - Smoke test

    func testEnableCurrentProviderRunsSmokeTestAndAdvancesOnSuccess() async {
        let vm = makeViewModel(
            dependencies: StubDependencies(smokeTestResult: .success)
        )
        vm.continueFromIntro()
        XCTAssertEqual(vm.card, .provider(.claude))

        await vm.enableCurrentProviderWithSmokeTest()

        XCTAssertEqual(vm.smokeTest[.claude], .succeeded)
        XCTAssertTrue(vm.enabledProviders.contains(.claude))
        XCTAssertEqual(vm.card, .provider(.codex))
    }

    func testEnableCurrentProviderStaysOnCardOnFailure() async {
        let vm = makeViewModel(
            dependencies: StubDependencies(smokeTestResult: .failure("boom"))
        )
        vm.continueFromIntro()

        await vm.enableCurrentProviderWithSmokeTest()

        XCTAssertEqual(vm.smokeTest[.claude], .failed("boom"))
        XCTAssertFalse(vm.enabledProviders.contains(.claude))
        XCTAssertEqual(vm.card, .provider(.claude))
    }

    // MARK: - Ollama probe

    func testProbeOllamaLocalMarksFoundWithModels() async {
        let vm = makeViewModel(
            dependencies: StubDependencies(
                ollamaResult: .success(["llama3.2:1b", "qwen2.5:7b"])
            )
        )
        await vm.probeOllamaLocal()

        XCTAssertEqual(vm.ollamaProbe, .foundLocal(models: ["llama3.2:1b", "qwen2.5:7b"]))
        XCTAssertEqual(vm.providerModels[.ollama], "llama3.2:1b")
    }

    func testProbeOllamaLocalMarksMissingOnFailure() async {
        let vm = makeViewModel(
            dependencies: StubDependencies(ollamaResult: .failure(.connectionRefused))
        )
        await vm.probeOllamaLocal()

        XCTAssertEqual(vm.ollamaProbe, .localMissing)
    }

    func testRemoteOllamaProbeRoutesThroughOllamaProbeOnSuccess() async {
        let vm = makeViewModel(
            dependencies: StubDependencies(
                ollamaResult: .success(["mistral:7b"])
            )
        )
        vm.setRemoteOllamaEnabled(true)
        vm.remoteOllama.host = "studio.local"
        vm.remoteOllama.port = "11434"

        await vm.probeOllamaRemote()

        XCTAssertEqual(vm.ollamaProbe, .foundRemote(models: ["mistral:7b"]))
        XCTAssertEqual(vm.remoteOllama.selectedModel, "mistral:7b")
        XCTAssertNil(vm.remoteOllama.validationError)
    }

    func testRemoteOllamaProbeRejectsDisallowedURL() async {
        let vm = makeViewModel(dependencies: StubDependencies())
        vm.setRemoteOllamaEnabled(true)
        vm.remoteOllama.host = "evil.com"
        vm.remoteOllama.port = "80"

        await vm.probeOllamaRemote()

        XCTAssertEqual(vm.ollamaProbe, .remoteFailed(.invalidURL))
        XCTAssertNotNil(vm.remoteOllama.validationError)
    }

    func testRemoteOllamaProbeSurfacesProbeError() async {
        let vm = makeViewModel(
            dependencies: StubDependencies(ollamaResult: .failure(.timeout))
        )
        vm.setRemoteOllamaEnabled(true)
        vm.remoteOllama.host = "studio.local"
        vm.remoteOllama.port = "11434"

        await vm.probeOllamaRemote()

        XCTAssertEqual(vm.ollamaProbe, .remoteFailed(.timeout))
    }

    // MARK: - Persistence

    func testFinishWithZeroEnabledProvidersWritesNothing() throws {
        let (store, llm, _) = makeStores()
        let vm = AIAssistantOnboardingViewModel(
            dependencies: StubDependencies(),
            aiAssistantStore: store,
            llmConfigStore: llm
        )
        let payload = try vm.finish()

        XCTAssertNil(payload.aiAssistantConfig)
        XCTAssertNil(payload.ollamaProviderConfig)
        XCTAssertNil(store.load())
        XCTAssertNil(llm.savedConfig)
    }

    func testFinishWithSingleEnabledProviderWritesAIAssistantConfig() async throws {
        let (store, llm, _) = makeStores()
        let vm = AIAssistantOnboardingViewModel(
            dependencies: StubDependencies(smokeTestResult: .success),
            aiAssistantStore: store,
            llmConfigStore: llm
        )
        vm.continueFromIntro()
        await vm.enableCurrentProviderWithSmokeTest() // claude
        // Skip the rest to reach defaultPicker
        vm.skipCurrentProvider() // codex
        vm.skipCurrentProvider() // gemini
        vm.skipCurrentProvider() // ollama
        XCTAssertEqual(vm.card, .defaultPicker)
        XCTAssertEqual(vm.defaultProvider, .claude)

        let payload = try vm.finish()
        let saved = try XCTUnwrap(payload.aiAssistantConfig)
        XCTAssertEqual(saved.provider, .claude)
        XCTAssertEqual(saved.enabledProviders, ["claude"])
        XCTAssertNil(payload.ollamaProviderConfig)
        XCTAssertNotNil(store.load())
    }

    func testFinishWithLocalOllamaFanOutsToBothStores() async throws {
        let (store, llm, _) = makeStores()
        let vm = AIAssistantOnboardingViewModel(
            dependencies: StubDependencies(
                ollamaResult: .success(["gemma3:4b"])
            ),
            aiAssistantStore: store,
            llmConfigStore: llm
        )

        vm.continueFromIntro() // claude
        vm.skipCurrentProvider() // codex
        vm.skipCurrentProvider() // gemini
        vm.skipCurrentProvider() // ollama
        XCTAssertEqual(vm.card, .provider(.ollama))

        await vm.probeOllamaLocal()
        await vm.enableCurrentProviderWithSmokeTest() // ollama
        XCTAssertEqual(vm.card, .defaultPicker)
        XCTAssertEqual(vm.defaultProvider, .ollama)

        let payload = try vm.finish()
        let aiAssistant = try XCTUnwrap(payload.aiAssistantConfig)
        XCTAssertEqual(aiAssistant.provider, .ollama)
        XCTAssertEqual(aiAssistant.enabledProviders, ["ollama"])

        let llmConfig = try XCTUnwrap(payload.ollamaProviderConfig)
        XCTAssertEqual(llmConfig.id, .ollama)
        XCTAssertEqual(llmConfig.modelName, "gemma3:4b")
        XCTAssertEqual(llmConfig.baseURL, URL(string: "http://localhost:11434"))
        XCTAssertNotNil(llm.savedConfig)
    }

    func testFinishWithRemoteOllamaPersistsRemoteEndpoint() async throws {
        let (store, llm, _) = makeStores()
        let vm = AIAssistantOnboardingViewModel(
            dependencies: StubDependencies(
                ollamaResult: .success(["qwen3:14b"])
            ),
            aiAssistantStore: store,
            llmConfigStore: llm
        )

        vm.continueFromIntro()
        vm.skipCurrentProvider() // codex
        vm.skipCurrentProvider() // gemini
        vm.skipCurrentProvider() // ollama
        vm.setRemoteOllamaEnabled(true)
        vm.remoteOllama.host = "studio.local"
        vm.remoteOllama.port = "11434"

        await vm.probeOllamaRemote()
        await vm.enableCurrentProviderWithSmokeTest()
        XCTAssertEqual(vm.card, .defaultPicker)

        let payload = try vm.finish()
        let llmConfig = try XCTUnwrap(payload.ollamaProviderConfig)
        XCTAssertEqual(llmConfig.baseURL, URL(string: "http://studio.local:11434"))
        XCTAssertEqual(llmConfig.modelName, "qwen3:14b")
        XCTAssertEqual(llm.savedConfig?.baseURL, URL(string: "http://studio.local:11434"))
    }

    // MARK: - Rerun-setup prefill invariant

    func testRerunPrefillsFromSavedAIAssistantConfig() throws {
        let (store, llm, _) = makeStores()
        let saved = AIAssistantConfig(
            provider: .codex,
            commandTemplate: "codex exec --custom-flag",
            modelName: "gpt-5.2",
            timeoutSeconds: 90,
            enabledProviders: ["codex", "gemini"],
            providerCommandTemplates: ["gemini": "gemini --custom"],
            providerModelNames: ["gemini": "gemini-2.5-pro"]
        )
        try store.save(saved)

        let vm = AIAssistantOnboardingViewModel(
            dependencies: StubDependencies(),
            aiAssistantStore: store,
            llmConfigStore: llm
        )

        XCTAssertTrue(vm.enabledProviders.contains(.codex))
        XCTAssertTrue(vm.enabledProviders.contains(.gemini))
        XCTAssertEqual(vm.defaultProvider, .codex)
        XCTAssertEqual(vm.providerCommandTemplates[.codex], "codex exec --custom-flag")
        XCTAssertEqual(vm.providerCommandTemplates[.gemini], "gemini --custom")
        XCTAssertEqual(vm.providerModels[.codex], "gpt-5.2")
        XCTAssertEqual(vm.providerModels[.gemini], "gemini-2.5-pro")
    }

    func testRerunPrefillsRemoteOllamaFromSavedLLMConfig() {
        let (store, llm, _) = makeStores()
        llm.savedConfig = LLMProviderConfig.ollama(
            model: "llama3.3:70b",
            baseURL: URL(string: "http://node-7.my-tailnet.ts.net:11434")!
        )

        let vm = AIAssistantOnboardingViewModel(
            dependencies: StubDependencies(),
            aiAssistantStore: store,
            llmConfigStore: llm
        )

        XCTAssertTrue(vm.remoteOllama.enabled)
        XCTAssertEqual(vm.remoteOllama.host, "node-7.my-tailnet.ts.net")
        XCTAssertEqual(vm.remoteOllama.port, "11434")
        XCTAssertEqual(vm.remoteOllama.selectedModel, "llama3.3:70b")
        XCTAssertEqual(vm.providerModels[.ollama], "llama3.3:70b")
    }
}

// MARK: - Test doubles

private struct StubDependencies: AIAssistantOnboardingDependencies {
    var resolvedBinaries: [String: URL] = [:]
    var ollamaResult: Result<[String], OllamaReachability.ProbeError> = .failure(.connectionRefused)
    var smokeTestResult: SmokeTestOutcome = .failure("not configured in stub")

    func resolveBinary(_ name: String) -> URL? { resolvedBinaries[name] }
    func probeOllama(baseURL: URL) async -> Result<[String], OllamaReachability.ProbeError> {
        ollamaResult
    }
    func smokeTestCLI(config: LocalCLIConfig) async -> SmokeTestOutcome {
        smokeTestResult
    }
}

private final class OnboardingMockLLMConfigStore: LLMConfigStoreProtocol, @unchecked Sendable {
    var savedConfig: LLMProviderConfig?
    var apiKeys: [LLMProviderID: String] = [:]

    func loadConfig() throws -> LLMProviderConfig? { savedConfig }
    func saveConfig(_ config: LLMProviderConfig) throws { savedConfig = config }
    func deleteConfig() throws { savedConfig = nil }
    func loadAPIKey() throws -> String? {
        guard let id = savedConfig?.id else { return nil }
        return apiKeys[id]
    }
    func loadAPIKey(for provider: LLMProviderID) throws -> String? { apiKeys[provider] }
    func saveAPIKey(_ key: String) throws {
        guard let id = savedConfig?.id else { return }
        apiKeys[id] = key
    }
    func deleteAPIKey() throws {
        guard let id = savedConfig?.id else { return }
        apiKeys.removeValue(forKey: id)
    }
    func updateModelName(_ modelName: String) throws {
        guard let existing = savedConfig else { return }
        savedConfig = LLMProviderConfig(
            id: existing.id,
            baseURL: existing.baseURL,
            apiKey: existing.apiKey,
            modelName: modelName,
            isLocal: existing.isLocal
        )
    }
}
