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
                fetchedModels = []
                isFetchingModels = false
                if !requiresAPIKey { apiKeyInput = "" }
            }
        }
    }
    public var apiKeyInput: String = ""
    public var modelName: String = "gpt-4.1"
    public var baseURLOverride: String = ""
    public var connectionTestState: ConnectionTestState = .idle
    public var saveError: String?
    public var fetchedModels: [String] = []
    public var isFetchingModels: Bool = false

    public var isConfigured: Bool {
        configStore != nil && (try? configStore?.loadConfig()) != nil
    }

    public var requiresAPIKey: Bool {
        !selectedProviderID.isLocal
    }

    /// Models to show in the picker: fetched from API if available, otherwise hardcoded suggestions.
    public var availableModels: [String] {
        fetchedModels.isEmpty ? Self.suggestedModels(for: selectedProviderID) : fetchedModels
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
        saveError = nil
        do {
            try configStore.saveConfig(config)
            connectionTestState = .idle
            onConfigurationChanged?()
        } catch {
            saveError = error.localizedDescription
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
                // Also fetch models on successful connection
                await fetchModelsQuietly(config: config)
            } catch {
                connectionTestState = .error(error.localizedDescription)
            }
        }
    }

    public func fetchModels() {
        guard let llmClient else { return }
        isFetchingModels = true
        let config = buildConfig()
        Task {
            await fetchModelsQuietly(config: config)
        }
    }

    private func fetchModelsQuietly(config: LLMProviderConfig) async {
        guard let llmClient else { return }
        isFetchingModels = true
        let currentModel = modelName
        do {
            let allModels = try await llmClient.listModels(config: config)
            // Filter to chat-capable models (exclude embeddings, tts, image-only, etc.)
            let chatModels = Self.filterChatModels(allModels, provider: config.id)
            fetchedModels = chatModels
            // Preserve current selection if it exists in fetched list;
            // otherwise fall back to the provider's default model, then first in list
            if !chatModels.contains(currentModel) {
                let defaultModel = Self.defaultModelName(for: config.id)
                if chatModels.contains(defaultModel) {
                    modelName = defaultModel
                } else if let first = chatModels.first {
                    modelName = first
                }
            }
        } catch {
            fetchedModels = []
        }
        isFetchingModels = false
    }

    private static func filterChatModels(_ models: [String], provider: LLMProviderID) -> [String] {
        let excluded = ["embed", "tts", "whisper", "dall-e", "moderation", "aqa",
                        "imagen", "veo", "chirp", "code-gecko", "-vision", "search"]
        return models.filter { model in
            let lower = model.lowercased()
            return !excluded.contains(where: { lower.contains($0) })
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
        } else if let defaultURL = URL(string: Self.defaultBaseURL(for: selectedProviderID)), !Self.defaultBaseURL(for: selectedProviderID).isEmpty {
            baseURL = defaultURL
        } else {
            // .custom provider with no URL — use a placeholder that will fail at request time
            // rather than crash here
            baseURL = URL(string: "http://localhost")!
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

    /// Popular models for each provider. Empty means free-text input.
    public static func suggestedModels(for provider: LLMProviderID) -> [String] {
        switch provider {
        case .anthropic: return [
            "claude-sonnet-4-6",
            "claude-opus-4-6",
            "claude-haiku-4-5-20251001",
            "claude-sonnet-4-5-20250929",
        ]
        case .openai: return [
            "gpt-4.1",
            "gpt-4.1-mini",
            "gpt-4.1-nano",
            "gpt-4o",
            "gpt-4o-mini",
            "o3",
            "o3-mini",
            "o4-mini",
        ]
        case .gemini: return [
            "gemini-2.5-flash",
            "gemini-2.5-pro",
            "gemini-2.0-flash",
        ]
        case .openrouter: return [
            "anthropic/claude-sonnet-4",
            "openai/gpt-4.1",
            "google/gemini-2.5-flash",
        ]
        case .ollama: return [
            "qwen3.5:4b",
            "qwen3.5:9b",
            "llama4:8b",
            "gemma3:4b",
            "deepseek-v3.2",
            "qwen3:8b",
            "mistral",
        ]
        case .custom: return []
        }
    }

    static func defaultModelName(for provider: LLMProviderID) -> String {
        suggestedModels(for: provider).first ?? ""
    }

    private static func defaultBaseURL(for provider: LLMProviderID) -> String {
        switch provider {
        case .anthropic: return "https://api.anthropic.com/v1"
        case .openai: return "https://api.openai.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .openrouter: return "https://openrouter.ai/api/v1"
        case .ollama: return "http://localhost:11434/v1"
        case .custom: return ""
        }
    }
}
