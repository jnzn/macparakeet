import XCTest
@testable import MacParakeetCore

final class AskProviderCatalogTests: XCTestCase {
    /// Minimal in-memory config store: a global config + per-provider keys.
    private final class StubConfigStore: LLMConfigStoreProtocol, @unchecked Sendable {
        var global: LLMProviderConfig?
        var keys: [LLMProviderID: String] = [:]

        func loadConfig() throws -> LLMProviderConfig? { global }
        func saveConfig(_ config: LLMProviderConfig) throws { global = config }
        func deleteConfig() throws { global = nil }
        func loadAPIKey() throws -> String? { global.flatMap { keys[$0.id] } }
        func loadAPIKey(for provider: LLMProviderID) throws -> String? { keys[provider] }
        func saveAPIKey(_ key: String) throws {}
        func deleteAPIKey() throws {}
        func updateModelName(_ modelName: String) throws {}
    }

    /// All existing tests pin Apple On-Device availability to `false` so
    /// they stay deterministic regardless of the running machine's actual
    /// OS version / Apple Intelligence state (see testAppleOnDevice* below
    /// for that behavior specifically).
    private func makeCatalog(
        store: StubConfigStore,
        cliResolver: @escaping @Sendable (String) -> Bool = { _ in false },
        appleOnDeviceAvailable: @escaping @Sendable () -> Bool = { false }
    ) -> AskProviderCatalog {
        AskProviderCatalog(
            configStore: store,
            cliResolver: cliResolver,
            appleOnDeviceAvailable: appleOnDeviceAvailable
        )
    }

    func testDefaultOptionAlwaysFirst() {
        let store = StubConfigStore()
        store.global = .ollama()
        let catalog = makeCatalog(store: store)

        let options = catalog.availableOptions()

        XCTAssertEqual(options.first?.id, "default")
        XCTAssertTrue(options.first?.isDefault == true)
        XCTAssertNil(options.first?.context, "Default option uses the global config, not an override")
        XCTAssertTrue(options.first?.displayName.contains("Ollama") == true)
    }

    func testCloudProviderWithKeyIsOffered() {
        let store = StubConfigStore()
        store.global = .ollama()
        store.keys[.anthropic] = "sk-test"
        let catalog = makeCatalog(store: store)

        let options = catalog.availableOptions()
        let anthropic = options.first(where: { $0.id == LLMProviderID.anthropic.rawValue })

        XCTAssertNotNil(anthropic)
        XCTAssertEqual(anthropic?.context?.providerConfig.id, .anthropic)
        XCTAssertEqual(anthropic?.context?.providerConfig.apiKey, "sk-test")
    }

    func testActiveGlobalProviderNotDuplicatedInCloudList() {
        let store = StubConfigStore()
        store.global = .anthropic(apiKey: "sk-test")
        store.keys[.anthropic] = "sk-test"
        let catalog = makeCatalog(store: store)

        let options = catalog.availableOptions()
        let anthropicOverrides = options.filter { $0.id == LLMProviderID.anthropic.rawValue }

        XCTAssertTrue(anthropicOverrides.isEmpty, "Active provider is the default; no duplicate override row")
        XCTAssertEqual(options.count, 1, "Only the default option when no other provider is set up")
    }

    func testProviderWithoutKeyIsExcluded() {
        let store = StubConfigStore()
        store.global = .ollama()
        // No keys saved for any cloud provider.
        let catalog = makeCatalog(store: store)

        let options = catalog.availableOptions()

        XCTAssertEqual(options.count, 1)
        XCTAssertEqual(options.first?.id, "default")
    }

    func testDetectedCLIToolsAreOffered() {
        let store = StubConfigStore()
        store.global = .ollama()
        // Resolver claims both claude and codex are installed.
        let catalog = makeCatalog(store: store, cliResolver: { _ in true })

        let options = catalog.availableOptions()
        let claude = options.first(where: { $0.id == "cli_\(LocalCLITemplate.claudeCode.rawValue)" })
        let codex = options.first(where: { $0.id == "cli_\(LocalCLITemplate.codex.rawValue)" })

        XCTAssertNotNil(claude)
        XCTAssertNotNil(codex)
        XCTAssertEqual(claude?.context?.providerConfig.id, .localCLI)
        XCTAssertNotNil(claude?.context?.localCLIConfig)
        XCTAssertEqual(claude?.displayName, "Claude Code")
    }

    func testUndetectedCLIToolsAreExcluded() {
        let store = StubConfigStore()
        store.global = .ollama()
        // Only "claude" resolves; "codex" does not.
        let catalog = makeCatalog(store: store, cliResolver: { $0 == "claude" })

        let options = catalog.availableOptions()

        XCTAssertNotNil(options.first(where: { $0.id == "cli_\(LocalCLITemplate.claudeCode.rawValue)" }))
        XCTAssertNil(options.first(where: { $0.id == "cli_\(LocalCLITemplate.codex.rawValue)" }))
    }

    func testAppleOnDeviceOfferedWhenAvailable() {
        let store = StubConfigStore()
        store.global = .ollama()
        let catalog = makeCatalog(store: store, appleOnDeviceAvailable: { true })

        let options = catalog.availableOptions()
        let apple = options.first(where: { $0.id == LLMProviderID.appleOnDevice.rawValue })

        XCTAssertNotNil(apple)
        XCTAssertEqual(apple?.context?.providerConfig.id, .appleOnDevice)
    }

    /// Apple On-Device is a choice, never the default: its ~4K-token window
    /// can't hold a long transcript, so the global config keeps the
    /// "(default)" label and flag whether or not Apple is offered.
    func testGlobalConfigStaysTheLabeledDefaultWhenAppleIsOffered() {
        let store = StubConfigStore()
        store.global = .ollama()
        let catalog = makeCatalog(store: store, appleOnDeviceAvailable: { true })

        let options = catalog.availableOptions()
        let apple = options.first(where: { $0.id == LLMProviderID.appleOnDevice.rawValue })
        let global = options.first(where: { $0.id == "default" })

        XCTAssertTrue(global?.isDefault == true)
        XCTAssertEqual(global?.displayName, "Ollama (default)")
        XCTAssertNotNil(apple)
        XCTAssertFalse(apple?.isDefault == true)
        XCTAssertFalse(apple?.displayName.contains("(default)") == true)
    }

    func testGlobalConfigIsLabeledDefaultWhenAppleUnavailable() {
        let store = StubConfigStore()
        store.global = .ollama()
        let catalog = makeCatalog(store: store, appleOnDeviceAvailable: { false })

        let options = catalog.availableOptions()
        let global = options.first(where: { $0.id == "default" })

        XCTAssertTrue(global?.isDefault == true)
        XCTAssertTrue(global?.displayName.contains("(default)") == true)
    }

    /// If Apple *is* the global provider, the default row already is Apple;
    /// listing it a second time would be a duplicate.
    func testAppleIsNotListedTwiceWhenItIsTheGlobalProvider() {
        let store = StubConfigStore()
        store.global = .appleOnDevice()
        let catalog = makeCatalog(store: store, appleOnDeviceAvailable: { true })

        let options = catalog.availableOptions()

        XCTAssertEqual(options.filter { $0.displayName.contains("Apple") }.count, 1)
        XCTAssertNil(options.first(where: { $0.id == LLMProviderID.appleOnDevice.rawValue }))
    }

    func testAppleOnDeviceExcludedWhenUnavailable() {
        let store = StubConfigStore()
        store.global = .ollama()
        let catalog = makeCatalog(store: store, appleOnDeviceAvailable: { false })

        let options = catalog.availableOptions()

        XCTAssertNil(options.first(where: { $0.id == LLMProviderID.appleOnDevice.rawValue }))
    }
}
