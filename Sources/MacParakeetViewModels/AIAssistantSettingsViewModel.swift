import Foundation
import MacParakeetCore

/// ViewModel for the AI Assistant settings card. Mirrors the shape of
/// `LLMSettingsViewModel` but writes to `AIAssistantConfigStore` and uses
/// `AIAssistantConfig` as its source of truth.
@MainActor
@Observable
public final class AIAssistantSettingsViewModel {
    // Stored identity.
    public var provider: AIAssistantConfig.Provider {
        didSet { if oldValue != provider { applyProviderDefaults() } }
    }
    public var commandTemplate: String
    public var modelName: String
    public var timeoutSeconds: Double

    /// Feedback surface for test-connection calls. Cleared as the user edits
    /// the command.
    public private(set) var testStatus: TestStatus = .idle

    public enum TestStatus: Equatable, Sendable {
        case idle
        case running
        case success
        case failure(String)
    }

    private let store: AIAssistantConfigStore
    private let executor: any AIAssistantExecuting

    public init(
        store: AIAssistantConfigStore = AIAssistantConfigStore(),
        executor: any AIAssistantExecuting = LocalCLIExecutor()
    ) {
        self.store = store
        self.executor = executor
        let loaded = store.load() ?? AIAssistantConfig.defaultClaude
        self.provider = loaded.provider
        self.commandTemplate = loaded.commandTemplate
        self.modelName = loaded.modelName
        self.timeoutSeconds = loaded.timeoutSeconds
    }

    public var currentConfig: AIAssistantConfig {
        AIAssistantConfig(
            provider: provider,
            commandTemplate: commandTemplate,
            modelName: modelName,
            timeoutSeconds: timeoutSeconds
        )
    }

    public func save() {
        try? store.save(currentConfig)
    }

    public func resetToProviderDefaults() {
        applyProviderDefaults()
        save()
    }

    /// Fire a minimal `Reply with OK`-style probe through the configured
    /// CLI. Surfaces failure messages verbatim so the user can diagnose
    /// "command not found" / bad flags etc.
    public func testConnection() async {
        testStatus = .running
        let config = currentConfig
        let cliConfig = LocalCLIConfig(
            commandTemplate: config.effectiveCommandTemplate,
            timeoutSeconds: min(30, config.timeoutSeconds)
        )
        do {
            let output = try await executor.execute(
                systemPrompt: "You are a connectivity test probe. Reply with the two letters OK and nothing else.",
                userPrompt: "Reply OK",
                config: cliConfig
            )
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            testStatus = trimmed.isEmpty ? .failure("Empty response from CLI.") : .success
        } catch {
            testStatus = .failure(error.localizedDescription)
        }
    }

    // MARK: - Private

    private func applyProviderDefaults() {
        commandTemplate = provider.defaultCommandTemplate
        modelName = provider.defaultModel
        timeoutSeconds = AIAssistantConfig.defaultTimeout
        testStatus = .idle
    }
}
