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

    public enum SaveState: Equatable {
        case idle
        case saved
        case error(String)
    }

    public var selectedProviderID: LLMProviderID = .openai {
        didSet {
            if oldValue != selectedProviderID {
                suppressStatusReset = true
                modelName = Self.defaultModelName(for: selectedProviderID)
                baseURLOverride = ""
                useCustomModel = false
                customModelName = ""
                // Load stored key for the new provider (or clear for local)
                if requiresAPIKey {
                    apiKeyInput = (try? configStore?.loadAPIKey(for: selectedProviderID)) ?? ""
                } else {
                    apiKeyInput = ""
                }
                suppressStatusReset = false
                connectionTestState = .idle
                saveState = .idle
            }
        }
    }
    public var apiKeyInput: String = "" {
        didSet { if !suppressStatusReset && oldValue != apiKeyInput { connectionTestState = .idle; saveState = .idle } }
    }
    public var modelName: String = "gpt-5.4" {
        didSet { if !suppressStatusReset && oldValue != modelName { connectionTestState = .idle; saveState = .idle } }
    }
    public var baseURLOverride: String = "" {
        didSet { if !suppressStatusReset && oldValue != baseURLOverride { connectionTestState = .idle; saveState = .idle } }
    }
    public var connectionTestState: ConnectionTestState = .idle
    public var saveState: SaveState = .idle
    public var useCustomModel: Bool = false {
        didSet {
            if !suppressStatusReset && oldValue != useCustomModel {
                connectionTestState = .idle
                saveState = .idle
                if useCustomModel {
                    customModelName = ""
                }
            }
        }
    }
    public var customModelName: String = "" {
        didSet { if !suppressStatusReset && oldValue != customModelName { connectionTestState = .idle; saveState = .idle } }
    }

    /// Suppresses status resets in property didSet during programmatic updates.
    private var suppressStatusReset = false

    public var isConfigured: Bool {
        configStore != nil && (try? configStore?.loadConfig()) != nil
    }

    public var requiresAPIKey: Bool {
        !selectedProviderID.isLocal
    }

    /// Curated models shown in the picker.
    public var availableModels: [String] {
        Self.suggestedModels(for: selectedProviderID)
    }

    /// The effective model name used for configuration (picker selection or custom text).
    public var effectiveModelName: String {
        useCustomModel ? customModelName : modelName
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
            saveState = .saved
            onConfigurationChanged?()
        } catch {
            saveState = .error(error.localizedDescription)
        }
    }

    public func testConnection() {
        guard let llmClient else { return }
        connectionTestState = .testing
        let config = buildConfig()
        let capturedProvider = selectedProviderID
        Task {
            do {
                try await llmClient.testConnection(config: config)
                guard selectedProviderID == capturedProvider else { return }
                connectionTestState = .success
            } catch {
                guard selectedProviderID == capturedProvider else { return }
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
        saveState = .idle
        onConfigurationChanged?()
    }

    // MARK: - Private

    private func loadExistingConfig() {
        guard let configStore, let config = try? configStore.loadConfig() else { return }
        suppressStatusReset = true
        selectedProviderID = config.id
        apiKeyInput = config.apiKey ?? ""

        let suggested = Self.suggestedModels(for: config.id)
        if suggested.contains(config.modelName) {
            modelName = config.modelName
            useCustomModel = false
        } else {
            modelName = Self.defaultModelName(for: config.id)
            useCustomModel = true
            customModelName = config.modelName
        }

        let defaultURL = Self.defaultBaseURL(for: config.id)
        if config.baseURL.absoluteString != defaultURL {
            baseURLOverride = config.baseURL.absoluteString
        }
        suppressStatusReset = false
    }

    private func buildConfig() -> LLMProviderConfig {
        let baseURL: URL
        if !baseURLOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let override = URL(string: baseURLOverride.trimmingCharacters(in: .whitespacesAndNewlines)) {
            baseURL = override
        } else if let defaultURL = URL(string: Self.defaultBaseURL(for: selectedProviderID)), !Self.defaultBaseURL(for: selectedProviderID).isEmpty {
            baseURL = defaultURL
        } else {
            // No URL available — use a placeholder that will fail at request time rather than crash
            baseURL = URL(string: "http://localhost")!
        }

        let apiKey = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)

        return LLMProviderConfig(
            id: selectedProviderID,
            baseURL: baseURL,
            apiKey: apiKey.isEmpty ? nil : apiKey,
            modelName: effectiveModelName.trimmingCharacters(in: .whitespacesAndNewlines),
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
        ]
        case .openai: return [
            "gpt-5.4",
            "gpt-5.4-pro",
            "gpt-5.3-chat-latest",
            "gpt-5-mini",
            "gpt-5-nano",
            "gpt-4.1",
            "gpt-4.1-mini",
        ]
        case .gemini: return [
            "gemini-3.1-pro-preview",
            "gemini-3-flash-preview",
            "gemini-3.1-flash-lite-preview",
            "gemini-2.5-pro",
            "gemini-2.5-flash",
        ]
        case .openrouter: return [
            // Anthropic
            "anthropic/claude-opus-4-6",
            "anthropic/claude-sonnet-4-6",
            "anthropic/claude-haiku-4-5",
            // OpenAI
            "openai/gpt-5.4",
            "openai/gpt-5.4-pro",
            "openai/gpt-5-mini",
            "openai/gpt-5-nano",
            "openai/gpt-4.1",
            "openai/gpt-4.1-mini",
            // Google
            "google/gemini-3.1-pro-preview",
            "google/gemini-3-flash-preview",
            "google/gemini-2.5-flash",
            // Open-source / value
            "deepseek/deepseek-v3.2",
            "meta-llama/llama-4-scout",
            "qwen/qwen3.5-72b",
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
        }
    }
}
