import Foundation

/// A selectable LLM provider for the live Ask surface. `context == nil` means
/// "use the app's global default provider"; a non-nil context is a per-Ask
/// override that does NOT touch the global config (dictation cleanup, other
/// chat surfaces stay on the global provider).
public struct AskProviderOption: Identifiable, Sendable, Equatable {
    public let id: String
    public let displayName: String
    /// Override execution context, or nil for the global default.
    public let context: LLMExecutionContext?
    public let isDefault: Bool

    public init(id: String, displayName: String, context: LLMExecutionContext?, isDefault: Bool) {
        self.id = id
        self.displayName = displayName
        self.context = context
        self.isDefault = isDefault
    }
}

/// Enumerates the LLM providers the user has already set up, so the Ask tab can
/// offer a per-conversation provider override. "Set up" means: the global
/// default (always), any cloud provider with a saved API key, and any local CLI
/// tool (Claude Code / Codex) whose binary resolves on PATH.
///
/// Building options touches the Keychain and probes PATH, so callers should
/// invoke `availableOptions()` off the main actor and cache the result.
public struct AskProviderCatalog: Sendable {
    private let configStore: LLMConfigStoreProtocol
    /// Returns true if a bare binary name (e.g. "claude") resolves on PATH.
    private let cliResolver: @Sendable (String) -> Bool

    /// Cloud providers eligible for an Ask override when they have a saved key.
    private static let cloudProviders: [LLMProviderID] = [.anthropic, .openai, .gemini, .openrouter]

    public init(
        configStore: LLMConfigStoreProtocol,
        cliResolver: @escaping @Sendable (String) -> Bool
    ) {
        self.configStore = configStore
        self.cliResolver = cliResolver
    }

    public func availableOptions() -> [AskProviderOption] {
        var options: [AskProviderOption] = []
        let globalConfig = try? configStore.loadConfig()
        let globalID = globalConfig?.id

        // 1. Global default — always present, no override context.
        let defaultName = globalConfig.map { Self.displayName(for: $0.id) } ?? "Default"
        options.append(AskProviderOption(
            id: "default",
            displayName: "\(defaultName) (default)",
            context: nil,
            isDefault: true
        ))

        // 2. Cloud providers with a saved API key (skip the active default).
        for providerID in Self.cloudProviders where providerID != globalID {
            // `try?` flattens the throwing `String?` to a single optional.
            guard let key = try? configStore.loadAPIKey(for: providerID),
                  !key.isEmpty else { continue }
            guard let config = Self.cloudConfig(for: providerID, apiKey: key) else { continue }
            options.append(AskProviderOption(
                id: providerID.rawValue,
                displayName: providerID.displayName,
                context: LLMExecutionContext(providerConfig: config),
                isDefault: false
            ))
        }

        // 3. Local CLI tools detected on PATH (Claude Code, Codex).
        for template in LocalCLITemplate.allCases {
            let binary = Self.binaryName(for: template)
            guard cliResolver(binary) else { continue }
            let context = LLMExecutionContext(
                providerConfig: .localCLI(),
                localCLIConfig: template.defaultConfig
            )
            options.append(AskProviderOption(
                id: "cli_\(template.rawValue)",
                displayName: template.displayName,
                context: context,
                isDefault: false
            ))
        }

        return options
    }

    private static func displayName(for id: LLMProviderID) -> String {
        id.displayName
    }

    private static func binaryName(for template: LocalCLITemplate) -> String {
        template.defaultCommand
            .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? template.rawValue
    }

    private static func cloudConfig(for id: LLMProviderID, apiKey: String) -> LLMProviderConfig? {
        switch id {
        case .anthropic: return .anthropic(apiKey: apiKey)
        case .openai: return .openai(apiKey: apiKey)
        case .gemini: return .gemini(apiKey: apiKey)
        case .openrouter: return .openrouter(apiKey: apiKey)
        default: return nil
        }
    }
}
