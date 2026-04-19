import Foundation
import MacParakeetCore

// MARK: - Dependencies

/// Injectable seam for the four side-effects the onboarding step needs:
/// resolving CLI binaries on PATH, probing an Ollama daemon over HTTP,
/// running a per-provider smoke test, and reading the existing LLM-config
/// store so the Ollama card can prefill its host/port/model fields.
public protocol AIAssistantOnboardingDependencies: Sendable {
    func resolveBinary(_ name: String) -> URL?
    func probeOllama(baseURL: URL) async -> Result<[String], OllamaReachability.ProbeError>
    func smokeTestCLI(config: LocalCLIConfig) async -> SmokeTestOutcome
}

public enum SmokeTestOutcome: Sendable, Equatable {
    case success
    case failure(String)
}

public struct DefaultAIAssistantOnboardingDependencies: AIAssistantOnboardingDependencies {
    private let executor: LocalCLIExecutor

    public init(executor: LocalCLIExecutor = LocalCLIExecutor()) {
        self.executor = executor
    }

    public func resolveBinary(_ name: String) -> URL? {
        executor.resolve(binary: name)
    }

    public func probeOllama(baseURL: URL) async -> Result<[String], OllamaReachability.ProbeError> {
        await OllamaReachability.check(baseURL: baseURL)
    }

    public func smokeTestCLI(config: LocalCLIConfig) async -> SmokeTestOutcome {
        do {
            try await executor.testConnection(config: config)
            return .success
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}

// MARK: - ViewModel

/// State machine driving the optional "Ask AI Assistant" onboarding step.
///
/// The card sequence is fixed:
///   intro -> claude -> codex -> gemini -> ollama -> defaultPicker -> finished
///
/// Each provider card detects its CLI / daemon, then offers Enable / Skip.
/// Enable runs a live smoke test before advancing — failure shows the error
/// inline with Try again / Skip. Skip silently drops the provider. Skip-all
/// (from intro) bypasses every card and persists nothing — leaving the
/// hotkey inactive so the user finds the providers later in Settings.
///
/// The Ollama card has a sub-branch: when the local probe fails the user
/// can flip "Is Ollama on another computer?" to expand host + port inputs
/// and re-probe a remote endpoint. One Ollama configuration fans out to
/// both `AIAssistantConfigStore` (for the bubble) and `LLMConfigStore`
/// (for the AI Formatter) on Finish.
@MainActor
@Observable
public final class AIAssistantOnboardingViewModel {

    // MARK: - Sub-state types

    public enum Card: Equatable, Sendable {
        case intro
        case provider(AIAssistantConfig.Provider)
        case defaultPicker
        case finished
    }

    public enum CLIDetection: Equatable, Sendable {
        case unknown
        case checking
        case found(URL)
        case notFound
    }

    public enum SmokeTest: Equatable, Sendable {
        case idle
        case running
        case succeeded
        case failed(String)
    }

    public enum OllamaProbe: Equatable, Sendable {
        case unknown
        case checking
        case foundLocal(models: [String])
        case foundRemote(models: [String])
        case localMissing
        case remoteFailed(OllamaReachability.ProbeError)
    }

    /// User-editable draft for the remote-Ollama branch. `enabled` flips on
    /// when the user clicks "Yes, Ollama is on another computer" — the host
    /// and port inputs only render once that's true.
    public struct RemoteOllamaDraft: Equatable, Sendable {
        public var enabled: Bool
        public var useHTTPS: Bool
        public var host: String
        public var port: String
        public var selectedModel: String?
        public var validationError: String?

        public init(
            enabled: Bool = false,
            useHTTPS: Bool = true,
            host: String = "",
            port: String = "11434",
            selectedModel: String? = nil,
            validationError: String? = nil
        ) {
            self.enabled = enabled
            self.useHTTPS = useHTTPS
            self.host = host
            self.port = port
            self.selectedModel = selectedModel
            self.validationError = validationError
        }

        /// Builds an `http://` or `https://` URL based on `useHTTPS` when
        /// host + port are valid and the validator accepts it. Sets
        /// `validationError` and returns nil otherwise so the UI can render
        /// the inline message. Defaults to HTTPS — Tailscale serves valid
        /// Let's Encrypt certs on `*.ts.net` via `tailscale serve`, and
        /// HTTPS sidesteps macOS App Transport Security entirely.
        mutating func resolveURL() -> URL? {
            let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedHost.isEmpty else {
                validationError = "Enter a host."
                return nil
            }
            guard let portValue = Int(trimmedPort), portValue > 0, portValue <= 65_535 else {
                validationError = "Enter a valid port (1-65535)."
                return nil
            }
            let scheme = useHTTPS ? "https" : "http"
            guard let url = URL(string: "\(scheme)://\(trimmedHost):\(portValue)") else {
                validationError = "Couldn't build a URL from that host and port."
                return nil
            }
            guard OllamaURLValidator.isAllowedBaseURL(url) else {
                validationError = "Only loopback, Tailscale (*.ts.net), .local, RFC1918, and HTTPS hosts are allowed."
                return nil
            }
            validationError = nil
            return url
        }
    }

    // MARK: - Observable state

    public private(set) var card: Card = .intro
    public private(set) var cliDetection: [AIAssistantConfig.Provider: CLIDetection] = [
        .claude: .unknown,
        .codex: .unknown,
        .gemini: .unknown,
        .ollama: .unknown,
    ]
    public private(set) var smokeTest: [AIAssistantConfig.Provider: SmokeTest] = [
        .claude: .idle,
        .codex: .idle,
        .gemini: .idle,
        .ollama: .idle,
    ]
    public private(set) var ollamaProbe: OllamaProbe = .unknown
    public var remoteOllama: RemoteOllamaDraft = RemoteOllamaDraft()

    /// Providers the user has Enabled (smoke test passed). Persisted as the
    /// `enabledProviders` set on `AIAssistantConfig`. The default provider
    /// is always included regardless of whether it's in this set.
    public private(set) var enabledProviders: Set<AIAssistantConfig.Provider> = []
    /// Per-provider model name. Only Ollama lets the user pick in onboarding;
    /// other providers carry their `Provider.defaultModel` until the user
    /// edits in Settings -> AI Assistant.
    public private(set) var providerModels: [AIAssistantConfig.Provider: String] = [:]
    /// Per-provider command template. Pre-populated from saved config on
    /// rerun-setup; otherwise each provider's `defaultCommandTemplate`.
    public private(set) var providerCommandTemplates: [AIAssistantConfig.Provider: String] = [:]
    public var defaultProvider: AIAssistantConfig.Provider?

    // MARK: - Card navigation order

    private static let cardOrder: [Card] = [
        .intro,
        .provider(.claude),
        .provider(.codex),
        .provider(.gemini),
        .provider(.ollama),
        .defaultPicker,
    ]

    // MARK: - Dependencies

    private let dependencies: AIAssistantOnboardingDependencies
    private let aiAssistantStore: AIAssistantConfigStore
    private let llmConfigStore: LLMConfigStoreProtocol

    public init(
        dependencies: AIAssistantOnboardingDependencies = DefaultAIAssistantOnboardingDependencies(),
        aiAssistantStore: AIAssistantConfigStore = AIAssistantConfigStore(),
        llmConfigStore: LLMConfigStoreProtocol = LLMConfigStore()
    ) {
        self.dependencies = dependencies
        self.aiAssistantStore = aiAssistantStore
        self.llmConfigStore = llmConfigStore
        prefillFromSavedConfig()
    }

    // MARK: - Card transitions

    public func continueFromIntro() {
        guard case .intro = card else { return }
        advanceCard()
    }

    /// Skip-all path. Discards any in-progress provider state and jumps to
    /// `.finished` without persisting anything — the hotkey stays inactive
    /// and the user can configure the providers later in Settings.
    public func skipAll() {
        enabledProviders.removeAll()
        defaultProvider = nil
        card = .finished
    }

    public func skipCurrentProvider() {
        guard case .provider(let provider) = card else { return }
        enabledProviders.remove(provider)
        smokeTest[provider] = .idle
        advanceCard()
    }

    public func goBack() {
        guard let index = Self.cardOrder.firstIndex(of: card), index > 0 else { return }
        card = Self.cardOrder[index - 1]
    }

    private func advanceCard() {
        if let index = Self.cardOrder.firstIndex(of: card),
           index + 1 < Self.cardOrder.count {
            card = Self.cardOrder[index + 1]
            if card == .defaultPicker {
                seedDefaultProviderIfNeeded()
            }
        } else {
            card = .finished
        }
    }

    // MARK: - Detection

    /// Probes the Claude / Codex / Gemini binary on the user's PATH.
    /// Ollama goes through `probeOllamaLocal` instead — the daemon, not the
    /// CLI, is what the bubble talks to.
    public func detect(_ provider: AIAssistantConfig.Provider) async {
        guard provider != .ollama else { return }
        cliDetection[provider] = .checking
        let binaryName = binaryNameForProvider(provider)
        let resolved = dependencies.resolveBinary(binaryName)
        if let resolved {
            cliDetection[provider] = .found(resolved)
        } else {
            cliDetection[provider] = .notFound
        }
    }

    public func probeOllamaLocal() async {
        ollamaProbe = .checking
        guard let url = URL(string: "http://localhost:11434") else {
            ollamaProbe = .localMissing
            return
        }
        let result = await dependencies.probeOllama(baseURL: url)
        switch result {
        case .success(let models):
            ollamaProbe = .foundLocal(models: models)
            providerModels[.ollama] = preferredModel(
                from: models,
                current: providerModels[.ollama]
            )
        case .failure:
            ollamaProbe = .localMissing
        }
    }

    /// Probes the user-entered remote endpoint. Validates host + port,
    /// runs the same `/api/tags` call, then switches `ollamaProbe` to
    /// `.foundRemote` on success or `.remoteFailed(error)` on failure.
    public func probeOllamaRemote() async {
        guard let url = remoteOllama.resolveURL() else {
            ollamaProbe = .remoteFailed(.invalidURL)
            return
        }
        ollamaProbe = .checking
        let result = await dependencies.probeOllama(baseURL: url)
        switch result {
        case .success(let models):
            ollamaProbe = .foundRemote(models: models)
            remoteOllama.selectedModel = preferredModel(
                from: models,
                current: remoteOllama.selectedModel
            )
        case .failure(let error):
            ollamaProbe = .remoteFailed(error)
        }
    }

    /// Keeps the user's saved / previously-selected model when the daemon
    /// reports it as installed; otherwise falls back to the first model
    /// returned by `/api/tags`. Returns nil only if both `current` is nil
    /// and the model list is empty.
    private func preferredModel(from models: [String], current: String?) -> String? {
        if let current, !current.isEmpty, models.contains(current) {
            return current
        }
        return models.first
    }

    public func setOllamaModel(_ name: String) {
        switch ollamaProbe {
        case .foundRemote:
            remoteOllama.selectedModel = name
        default:
            providerModels[.ollama] = name
        }
    }

    public func setRemoteOllamaEnabled(_ enabled: Bool) {
        remoteOllama.enabled = enabled
        if !enabled {
            remoteOllama.validationError = nil
        }
    }

    // MARK: - Enable / smoke test

    /// Enable button for CLI providers. Runs a live smoke test using the
    /// effective command template; on success adds the provider to
    /// `enabledProviders` and advances. On failure leaves the user on the
    /// card with an inline error so they can Try again or Skip.
    public func enableCurrentProviderWithSmokeTest() async {
        guard case .provider(let provider) = card else { return }

        if provider == .ollama {
            enableOllamaIfReady()
            if enabledProviders.contains(.ollama) {
                advanceCard()
            }
            return
        }

        smokeTest[provider] = .running
        let template = providerCommandTemplates[provider] ?? provider.defaultCommandTemplate
        let model = providerModels[provider] ?? provider.defaultModel
        let commandLine = composeCommandLine(template: template, model: model, provider: provider)
        let config = LocalCLIConfig(commandTemplate: commandLine, timeoutSeconds: 30)

        let result = await dependencies.smokeTestCLI(config: config)
        switch result {
        case .success:
            smokeTest[provider] = .succeeded
            enabledProviders.insert(provider)
            providerCommandTemplates[provider] = template
            providerModels[provider] = model
            advanceCard()
        case .failure(let message):
            smokeTest[provider] = .failed(message)
        }
    }

    /// The Ollama card has no separate smoke test — `/api/tags` succeeding
    /// during detection is enough. Just records the chosen model and adds
    /// Ollama to the enabled set.
    private func enableOllamaIfReady() {
        switch ollamaProbe {
        case .foundLocal(let models):
            let model = providerModels[.ollama] ?? models.first
            guard let model, !model.isEmpty else { return }
            providerModels[.ollama] = model
            enabledProviders.insert(.ollama)
            smokeTest[.ollama] = .succeeded
        case .foundRemote(let models):
            let model = remoteOllama.selectedModel ?? models.first
            guard let model, !model.isEmpty else { return }
            remoteOllama.selectedModel = model
            providerModels[.ollama] = model
            enabledProviders.insert(.ollama)
            smokeTest[.ollama] = .succeeded
        default:
            return
        }
    }

    public func setDefaultProvider(_ provider: AIAssistantConfig.Provider) {
        guard enabledProviders.contains(provider) else { return }
        defaultProvider = provider
    }

    // MARK: - Persistence

    public struct PersistencePayload: Equatable, Sendable {
        public let aiAssistantConfig: AIAssistantConfig?
        public let ollamaProviderConfig: LLMProviderConfig?
    }

    /// Final commit. Returns the payload that was written so callers can
    /// telemetry-trace it. Writing nothing (zero enabled providers, or
    /// skip-all) returns a payload with both fields nil.
    @discardableResult
    public func finish() throws -> PersistencePayload {
        defer { card = .finished }

        guard let chosen = defaultProvider, enabledProviders.contains(chosen) else {
            return PersistencePayload(aiAssistantConfig: nil, ollamaProviderConfig: nil)
        }

        let enabledRaw = AIAssistantConfig.Provider.allCases
            .filter { enabledProviders.contains($0) }
            .map(\.rawValue)
        let templates = providerCommandTemplates.reduce(into: [String: String]()) { result, entry in
            result[entry.key.rawValue] = entry.value
        }
        let models = providerModels.reduce(into: [String: String]()) { result, entry in
            result[entry.key.rawValue] = entry.value
        }

        let config = AIAssistantConfig(
            provider: chosen,
            commandTemplate: providerCommandTemplates[chosen],
            modelName: providerModels[chosen],
            timeoutSeconds: AIAssistantConfig.defaultTimeout,
            hotkeyTrigger: nil,
            bubbleBackgroundColor: nil,
            autoReplaceSelection: nil,
            enabledProviders: enabledRaw,
            providerCommandTemplates: templates.isEmpty ? nil : templates,
            providerModelNames: models.isEmpty ? nil : models
        )
        try aiAssistantStore.save(config)

        var ollamaProviderConfig: LLMProviderConfig?
        if enabledProviders.contains(.ollama),
           let endpoint = ollamaEndpointForPersistence(),
           let model = providerModels[.ollama], !model.isEmpty {
            let providerConfig = LLMProviderConfig.ollama(model: model, baseURL: endpoint)
            try llmConfigStore.saveConfig(providerConfig)
            ollamaProviderConfig = providerConfig
        }

        return PersistencePayload(
            aiAssistantConfig: config,
            ollamaProviderConfig: ollamaProviderConfig
        )
    }

    // MARK: - Helpers

    private func ollamaEndpointForPersistence() -> URL? {
        switch ollamaProbe {
        case .foundRemote:
            var draft = remoteOllama
            return draft.resolveURL()
        case .foundLocal:
            return URL(string: "http://localhost:11434")
        default:
            return nil
        }
    }

    /// Determines the `Provider.allCases`-relative card order so we can
    /// derive previous / next without leaking enum ordering elsewhere.
    private func seedDefaultProviderIfNeeded() {
        guard defaultProvider == nil else { return }
        defaultProvider = AIAssistantConfig.Provider.allCases
            .first(where: { enabledProviders.contains($0) })
    }

    /// Bare CLI binary name to look up on PATH for each provider. Ollama is
    /// not in this map — it goes through HTTP detection.
    private func binaryNameForProvider(_ provider: AIAssistantConfig.Provider) -> String {
        switch provider {
        case .claude: return "claude"
        case .codex: return "codex"
        case .gemini: return "gemini"
        case .ollama: return "ollama"
        }
    }

    /// Stitches `--model` onto the template for providers that don't bake
    /// the model into the command (everything except Ollama). Mirrors
    /// `AIAssistantConfig.effectiveCommandTemplate(for:)`.
    private func composeCommandLine(
        template: String,
        model: String,
        provider: AIAssistantConfig.Provider
    ) -> String {
        if provider.bakesModelIntoCommand { return template }
        if template.contains("--model") { return template }
        let trimmedTemplate = template.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTemplate.isEmpty, !trimmedModel.isEmpty else { return template }
        return "\(trimmedTemplate) --model \(trimmedModel)"
    }

    /// Pulls the user's existing AIAssistantConfig + Ollama LLMProviderConfig
    /// (if any) so the rerun-setup invariant holds: every field pre-populates
    /// from saved values; the user never silently loses customization.
    private func prefillFromSavedConfig() {
        if let saved = aiAssistantStore.load() {
            for provider in AIAssistantConfig.Provider.allCases {
                providerCommandTemplates[provider] = saved.commandTemplate(for: provider)
                providerModels[provider] = saved.modelName(for: provider)
            }
            enabledProviders = Set(saved.effectiveEnabledProviders)
            defaultProvider = saved.provider
        } else {
            for provider in AIAssistantConfig.Provider.allCases {
                providerCommandTemplates[provider] = provider.defaultCommandTemplate
                providerModels[provider] = provider.defaultModel
            }
        }

        if let llm = try? llmConfigStore.loadConfig(), llm.id == .ollama {
            seedRemoteOllamaFromLLMConfig(llm)
            providerModels[.ollama] = llm.modelName
        }
    }

    private func seedRemoteOllamaFromLLMConfig(_ config: LLMProviderConfig) {
        let baseURL = config.baseURL
        let isLocalhost = baseURL.host == "localhost"
            || baseURL.host == "127.0.0.1"
            || baseURL.host == "::1"
        let isHTTPS = (baseURL.scheme?.lowercased() ?? "https") == "https"
        if isLocalhost {
            remoteOllama = RemoteOllamaDraft(
                enabled: false,
                useHTTPS: isHTTPS,
                host: "",
                port: baseURL.port.map(String.init) ?? "11434",
                selectedModel: config.modelName
            )
            return
        }
        remoteOllama = RemoteOllamaDraft(
            enabled: true,
            useHTTPS: isHTTPS,
            host: baseURL.host ?? "",
            port: baseURL.port.map(String.init) ?? "11434",
            selectedModel: config.modelName
        )
    }
}
