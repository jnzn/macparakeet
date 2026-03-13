import Foundation
import MacParakeetCore

@MainActor
@Observable
public final class LLMSettingsViewModel {
    public enum ConnectionTestState: Equatable {
        case idle
        case testing
        case success
        case error(String)
    }

    public var selectedProviderID: LLMProviderID = .openai {
        didSet {
            if oldValue != selectedProviderID {
                modelName = Self.defaultModelName(for: selectedProviderID)
                baseURLOverride = ""
                if !requiresAPIKey { apiKeyInput = "" }
            }
        }
    }
    public var apiKeyInput: String = ""
    public var modelName: String = "gpt-4o"
    public var baseURLOverride: String = ""
    public var connectionTestState: ConnectionTestState = .idle

    public var isConfigured: Bool {
        configStore != nil && (try? configStore?.loadConfig()) != nil
    }

    public var requiresAPIKey: Bool {
        !selectedProviderID.isLocal
    }

    public var onConfigurationChanged: (() -> Void)?

    private var configStore: LLMConfigStoreProtocol?
    private var llmClient: LLMClientProtocol?

    public init() {}

    public func configure(
        configStore: LLMConfigStoreProtocol,
        llmClient: LLMClientProtocol
    ) {
        self.configStore = configStore
        self.llmClient = llmClient
        loadExistingConfig()
    }

    public func saveConfiguration() {
        guard let configStore else { return }
        let config = buildConfig()
        do {
            try configStore.saveConfig(config)
            connectionTestState = .idle
            onConfigurationChanged?()
        } catch {
            connectionTestState = .error(error.localizedDescription)
        }
    }

    public func testConnection() {
        guard let llmClient else { return }
        connectionTestState = .testing
        let config = buildConfig()
        Task {
            do {
                try await llmClient.testConnection(config: config)
                connectionTestState = .success
            } catch {
                connectionTestState = .error(error.localizedDescription)
            }
        }
    }

    public func clearConfiguration() {
        guard let configStore else { return }
        try? configStore.deleteConfig()
        apiKeyInput = ""
        modelName = Self.defaultModelName(for: selectedProviderID)
        baseURLOverride = ""
        connectionTestState = .idle
        onConfigurationChanged?()
    }

    // MARK: - Private

    private func loadExistingConfig() {
        guard let configStore, let config = try? configStore.loadConfig() else { return }
        selectedProviderID = config.id
        apiKeyInput = config.apiKey ?? ""
        modelName = config.modelName

        let defaultURL = Self.defaultBaseURL(for: config.id)
        if config.baseURL.absoluteString != defaultURL {
            baseURLOverride = config.baseURL.absoluteString
        }
    }

    private func buildConfig() -> LLMProviderConfig {
        let baseURL: URL
        if !baseURLOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let override = URL(string: baseURLOverride.trimmingCharacters(in: .whitespacesAndNewlines)) {
            baseURL = override
        } else {
            baseURL = URL(string: Self.defaultBaseURL(for: selectedProviderID))!
        }

        let apiKey = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)

        return LLMProviderConfig(
            id: selectedProviderID,
            baseURL: baseURL,
            apiKey: apiKey.isEmpty ? nil : apiKey,
            modelName: modelName.trimmingCharacters(in: .whitespacesAndNewlines),
            isLocal: selectedProviderID.isLocal
        )
    }

    static func defaultModelName(for provider: LLMProviderID) -> String {
        switch provider {
        case .anthropic: return "claude-sonnet-4-20250514"
        case .openai: return "gpt-4o"
        case .gemini: return "gemini-2.0-flash"
        case .ollama: return "llama3.2"
        case .lmstudio: return ""
        case .custom: return ""
        }
    }

    private static func defaultBaseURL(for provider: LLMProviderID) -> String {
        switch provider {
        case .anthropic: return "https://api.anthropic.com/v1"
        case .openai: return "https://api.openai.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .ollama: return "http://localhost:11434/v1"
        case .lmstudio: return "http://localhost:1234/v1"
        case .custom: return ""
        }
    }
}
