import Foundation
import OSLog

// MARK: - CodableColor

/// UI-free color representation. Stored in the Core layer (which must not
/// depend on SwiftUI) and bridged to/from `SwiftUI.Color` in the app target.
/// Components are sRGB 0.0–1.0; opacity is 0.0–1.0.
public struct CodableColor: Codable, Sendable, Equatable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let opacity: Double

    public init(red: Double, green: Double, blue: Double, opacity: Double) {
        self.red = Self.clamp(red)
        self.green = Self.clamp(green)
        self.blue = Self.clamp(blue)
        self.opacity = Self.clamp(opacity)
    }

    private static func clamp(_ value: Double) -> Double {
        min(1.0, max(0.0, value))
    }
}

// MARK: - Config

/// Configuration for the AI Assistant hotkey — the second, separate-from-dictation
/// hotkey that ships selected text + a voice instruction to an agentic CLI
/// (Claude Code or OpenAI Codex) and renders the response in a floating bubble.
///
/// V1: persisted as a single JSON blob under `ai_assistant_config` via
/// `AIAssistantConfigStore`. Command template is user-editable so flag changes
/// in the upstream CLIs don't require a code release.
public struct AIAssistantConfig: Codable, Sendable, Equatable {
    public enum Provider: String, Codable, Sendable, CaseIterable {
        case claude
        case codex
        case gemini
        case ollama

        public var displayName: String {
            switch self {
            case .claude: return "Claude Code"
            case .codex: return "Codex"
            case .gemini: return "Gemini"
            case .ollama: return "Ollama"
            }
        }

        /// SF Symbol name used as the provider's icon in the bubble's
        /// switcher row. Stand-in for each vendor's actual logo (which
        /// is trademarked and not shippable without licensing).
        public var iconSystemName: String {
            switch self {
            case .claude: return "sparkles"
            case .codex: return "chevron.left.forwardslash.chevron.right"
            case .gemini: return "sparkle"
            case .ollama: return "cpu"
            }
        }

        /// Approximate brand color for the icon chip. Light-mode friendly;
        /// the bubble's foreground contrast handles dark mode.
        public var brandColorComponents: (red: Double, green: Double, blue: Double) {
            switch self {
            case .claude: return (0.85, 0.46, 0.34)   // Anthropic-ish warm orange
            case .codex:  return (0.10, 0.65, 0.40)   // OpenAI-ish green
            case .gemini: return (0.33, 0.54, 0.93)   // Gemini blue
            case .ollama: return (0.36, 0.40, 0.48)   // Neutral slate
            }
        }

        /// Ollama bakes the model name directly into the command
        /// (`ollama run MODEL`) rather than taking a `--model` flag, so
        /// `effectiveCommandTemplate` should not append `--model` for it.
        /// Other providers follow the append convention.
        public var bakesModelIntoCommand: Bool {
            self == .ollama
        }

        /// Default invocation template with skip-permissions flags baked in,
        /// per the agreed V1 spec. Users can override in Settings.
        public var defaultCommandTemplate: String {
            switch self {
            case .claude:
                return "claude --dangerously-skip-permissions -p"
            case .codex:
                return "codex exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check"
            case .gemini:
                // `--yolo` is the Gemini CLI's skip-permissions equivalent
                // (auto-accept all actions). Unlike Claude's `-p` which
                // reads stdin, Gemini's `--prompt` requires an explicit
                // string argument — but it APPENDS stdin to that argument
                // when stdin is a pipe. Passing `--prompt ""` lets the
                // prompt come entirely from stdin via LocalCLIExecutor's
                // standard pipe mechanism.
                return "gemini --yolo --prompt \"\""
            case .ollama:
                // Kept as a legacy placeholder for the AI Assistant
                // config model, but the runtime Ollama path now ignores
                // this template and talks to the configured Ollama HTTP
                // endpoint from Settings -> AI Provider instead.
                return "ollama run gemma4:e2b"
            }
        }

        public var defaultModel: String {
            switch self {
            case .claude: return "sonnet"
            case .codex: return "gpt-5.2"
            case .gemini: return "gemini-2.5-pro"
            case .ollama: return "gemma4:e2b"
            }
        }
    }

    public let provider: Provider
    public let commandTemplate: String
    public let modelName: String
    public let timeoutSeconds: Double
    /// Global hotkey for activating the AI Assistant bubble (hold-to-talk).
    /// Nil means "use the shipped default" — resolved to
    /// `Self.defaultHotkeyTrigger` at read time. Stored separately so that
    /// existing configs without a hotkey field decode cleanly after upgrade.
    public let hotkeyTrigger: HotkeyTrigger?
    /// User-picked translucent background for the bubble. Nil means "use the
    /// shipped default" — resolved via `effectiveBubbleBackgroundColor`.
    /// Optional so older configs without this field decode cleanly after
    /// upgrade.
    public let bubbleBackgroundColor: CodableColor?
    /// When true, Claude's first response to the initial question auto-
    /// replaces the original selection in the source app via clipboard
    /// paste (Cmd+V simulation). Each response still has a manual
    /// "Replace selection" button regardless of this setting. Default
    /// false — non-destructive by default.
    public let autoReplaceSelection: Bool?
    /// Providers the user wants available as in-bubble switchable
    /// options. The `provider` field above is the default — the one
    /// used for the first turn. Nil means "use the fallback set"
    /// (all providers enabled). Stored as raw string values so the
    /// JSON stays readable.
    public let enabledProviders: [String]?
    /// Per-provider command template overrides. Keyed by provider raw
    /// value. Nil / missing key → use the provider's default template.
    /// Lets the user customize each CLI's invocation without losing
    /// the setting when they switch the default provider.
    public let providerCommandTemplates: [String: String]?
    /// Per-provider model overrides. Same pattern as
    /// `providerCommandTemplates`.
    public let providerModelNames: [String: String]?

    public static let minimumTimeout: Double = 5
    public static let defaultTimeout: Double = 120
    /// Shipped default trigger: Control+Option+Shift held together, no
    /// base key. Chosen because it doesn't collide with common app-level
    /// shortcuts (those almost always include Command) and is easy to
    /// reach with the left hand while the right hand holds the mouse.
    public static let defaultHotkeyTrigger: HotkeyTrigger = .modifierCombo(
        ["control", "option", "shift"]
    )
    /// Shipped default bubble tint — transparent, so the underlying liquid-
    /// glass material does the work (system-appropriate light/dark adapts
    /// automatically). Users pick a tint color via Settings to override;
    /// the color is layered on top of the material at the chosen opacity
    /// like a stained-glass pane.
    public static let defaultBubbleBackgroundColor = CodableColor(
        red: 0,
        green: 0,
        blue: 0,
        opacity: 0
    )

    public init(
        provider: Provider,
        commandTemplate: String? = nil,
        modelName: String? = nil,
        timeoutSeconds: Double = Self.defaultTimeout,
        hotkeyTrigger: HotkeyTrigger? = nil,
        bubbleBackgroundColor: CodableColor? = nil,
        autoReplaceSelection: Bool? = nil,
        enabledProviders: [String]? = nil,
        providerCommandTemplates: [String: String]? = nil,
        providerModelNames: [String: String]? = nil
    ) {
        self.provider = provider
        self.commandTemplate = commandTemplate ?? provider.defaultCommandTemplate
        self.modelName = modelName ?? provider.defaultModel
        self.timeoutSeconds = max(Self.minimumTimeout, timeoutSeconds)
        self.hotkeyTrigger = hotkeyTrigger
        self.bubbleBackgroundColor = bubbleBackgroundColor
        self.autoReplaceSelection = autoReplaceSelection
        self.enabledProviders = enabledProviders
        self.providerCommandTemplates = providerCommandTemplates
        self.providerModelNames = providerModelNames
    }

    /// Resolved set of providers to surface as switchable icons in the
    /// bubble. When nothing is stored, all providers are available; the
    /// default provider is always included regardless of the stored set
    /// (so the user can't lock themselves out of their own default).
    public var effectiveEnabledProviders: [Provider] {
        let raw = enabledProviders ?? Provider.allCases.map(\.rawValue)
        var set = Set(raw.compactMap(Provider.init(rawValue:)))
        set.insert(provider)
        return Provider.allCases.filter { set.contains($0) }
    }

    /// Command template to use for a given provider. Falls back to the
    /// stored `commandTemplate` when asking for the default provider, and
    /// to each provider's `defaultCommandTemplate` otherwise.
    public func commandTemplate(for provider: Provider) -> String {
        if provider == self.provider {
            return commandTemplate
        }
        return providerCommandTemplates?[provider.rawValue]
            ?? provider.defaultCommandTemplate
    }

    /// Model name for a given provider. Mirrors `commandTemplate(for:)`.
    public func modelName(for provider: Provider) -> String {
        if provider == self.provider {
            return modelName
        }
        return providerModelNames?[provider.rawValue]
            ?? provider.defaultModel
    }

    /// Effective command + model stitched together for a non-default
    /// provider. Same rule as `effectiveCommandTemplate`: if the user's
    /// template already contains `--model`, respect it; otherwise append
    /// the configured model.
    public func effectiveCommandTemplate(for provider: Provider) -> String {
        let template = commandTemplate(for: provider)
        if provider.bakesModelIntoCommand { return template }
        if template.contains("--model") { return template }
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return template }
        let model = modelName(for: provider).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return template }
        return "\(trimmed) --model \(model)"
    }

    /// Effective value for `autoReplaceSelection` — false by default so
    /// existing configs without the field decode cleanly and don't
    /// suddenly start replacing selections in source apps.
    public var effectiveAutoReplaceSelection: Bool {
        autoReplaceSelection ?? false
    }

    public static var defaultClaude: AIAssistantConfig {
        AIAssistantConfig(provider: .claude)
    }

    public static var defaultCodex: AIAssistantConfig {
        AIAssistantConfig(provider: .codex)
    }

    /// Resolves `hotkeyTrigger` to the shipped default when nil, so callers
    /// don't need to branch on presence.
    public var effectiveHotkeyTrigger: HotkeyTrigger {
        hotkeyTrigger ?? Self.defaultHotkeyTrigger
    }

    /// Resolves `bubbleBackgroundColor` to the shipped default when nil, so
    /// callers don't need to branch on presence.
    public var effectiveBubbleBackgroundColor: CodableColor {
        bubbleBackgroundColor ?? Self.defaultBubbleBackgroundColor
    }

    /// The effective command passed to the shell, combining the user-editable
    /// template with the selected model (if the template doesn't already
    /// specify one — presence of "--model" wins). Providers that bake the
    /// model directly into the command line (Ollama) skip the append.
    public var effectiveCommandTemplate: String {
        if provider.bakesModelIntoCommand { return commandTemplate }
        if commandTemplate.contains("--model") {
            return commandTemplate
        }
        let trimmed = commandTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return commandTemplate }
        let modelToken = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelToken.isEmpty else { return commandTemplate }
        return "\(trimmed) --model \(modelToken)"
    }
}

// MARK: - Config store

/// Persists the AI Assistant config to `UserDefaults` as a JSON blob, mirroring
/// the pattern of `LocalCLIConfigStore`. Reading the config never throws — a
/// corrupt or absent blob simply resolves to `nil`, which the service treats as
/// "hotkey disabled."
public final class AIAssistantConfigStore: @unchecked Sendable {
    public static let configKey = "ai_assistant_config"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> AIAssistantConfig? {
        guard let data = defaults.data(forKey: Self.configKey) else { return nil }
        return try? JSONDecoder().decode(AIAssistantConfig.self, from: data)
    }

    public func save(_ config: AIAssistantConfig) throws {
        let data = try JSONEncoder().encode(config)
        defaults.set(data, forKey: Self.configKey)
    }

    public func delete() {
        defaults.removeObject(forKey: Self.configKey)
    }
}

// MARK: - Request / Turn

/// One round-trip in an AI Assistant bubble session. V1 sends the full history
/// on each subsequent call so the CLI sees the running thread. Responses are
/// collected in a non-streaming way — the bubble renders once the CLI exits.
public struct AIAssistantTurn: Sendable, Equatable {
    public let question: String
    public let response: String

    public init(question: String, response: String) {
        self.question = question
        self.response = response
    }
}

public struct AIAssistantRequest: Sendable {
    public let selection: String
    public let question: String
    public let history: [AIAssistantTurn]
    /// Optional per-turn provider override. When nil, the service uses
    /// the config's default provider. The bubble's provider-switcher
    /// sets this per ask so subsequent turns stay on the chosen CLI.
    public let providerOverride: AIAssistantConfig.Provider?

    public init(
        selection: String,
        question: String,
        history: [AIAssistantTurn] = [],
        providerOverride: AIAssistantConfig.Provider? = nil
    ) {
        self.selection = selection
        self.question = question
        self.history = history
        self.providerOverride = providerOverride
    }
}

// MARK: - Executor adapter (for tests)

/// Minimal protocol that `AIAssistantService` depends on. Concrete type is
/// `LocalCLIExecutor` in production; tests inject a mock that captures the
/// invocation + returns a canned response.
public protocol AIAssistantExecuting: Sendable {
    func execute(
        systemPrompt: String,
        userPrompt: String,
        config: LocalCLIConfig
    ) async throws -> String
}

extension LocalCLIExecutor: AIAssistantExecuting {}

// MARK: - Service

public protocol AIAssistantServiceProtocol: Sendable {
    func ask(_ request: AIAssistantRequest) async throws -> String
}

public final class AIAssistantService: AIAssistantServiceProtocol, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "AIAssistantService")
    private let executor: any AIAssistantExecuting
    private let ollamaExecutor: any AIAssistantExecuting
    private let configProvider: @Sendable () -> AIAssistantConfig?

    public init(
        executor: any AIAssistantExecuting = LocalCLIExecutor(),
        ollamaExecutor: any AIAssistantExecuting = AIAssistantOllamaExecutor(),
        configProvider: @escaping @Sendable () -> AIAssistantConfig?
    ) {
        self.executor = executor
        self.ollamaExecutor = ollamaExecutor
        self.configProvider = configProvider
    }

    public func ask(_ request: AIAssistantRequest) async throws -> String {
        guard let config = configProvider() else {
            throw LocalCLIError.commandNotConfigured
        }
        // Per-turn provider override lets the bubble switch CLIs mid-
        // conversation. When nil, use the config's default provider.
        let resolvedProvider = request.providerOverride ?? config.provider
        let resolvedTemplate = request.providerOverride == nil
            ? config.effectiveCommandTemplate
            : config.effectiveCommandTemplate(for: resolvedProvider)

        let cliConfig = LocalCLIConfig(
            commandTemplate: resolvedTemplate,
            timeoutSeconds: config.timeoutSeconds
        )
        let system = Self.renderSystemPrompt(selection: request.selection)
        let user = Self.renderUserPrompt(history: request.history, question: request.question)
        logger.info(
            "ask provider=\(resolvedProvider.rawValue, privacy: .public) override=\(request.providerOverride != nil, privacy: .public) selectionChars=\(request.selection.count) questionChars=\(request.question.count) historyTurns=\(request.history.count)"
        )
        let resolvedExecutor = resolvedProvider == .ollama ? ollamaExecutor : executor
        let output = try await resolvedExecutor.execute(
            systemPrompt: system,
            userPrompt: user,
            config: cliConfig
        )
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Prompt rendering

    /// The selection is pinned context for the whole bubble session. It lives
    /// in the system prompt so the CLI treats it as a stable reference.
    static func renderSystemPrompt(selection: String) -> String {
        let trimmedSelection = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
            You are an AI assistant embedded in a macOS dictation app. The user has selected text in another app and is asking questions about it. Respond directly and concisely without preamble. If the user asks you to rewrite or transform the selected text, output ONLY the transformed text — no explanation. If they ask a question about it, answer the question.

            Selected text (reference for every question in this session):
            \"\"\"
            \(trimmedSelection)
            \"\"\"
            """
    }

    /// User prompt assembly. History replays previous Q/A pairs so the CLI —
    /// which has no built-in session memory across `claude -p` / `codex exec`
    /// invocations — can thread the conversation. V1 does this via plain-text
    /// replay; providers with `--session-id`-style flags could swap to that in
    /// a later iteration.
    static func renderUserPrompt(history: [AIAssistantTurn], question: String) -> String {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !history.isEmpty else { return trimmedQuestion }
        var lines: [String] = ["Conversation so far:"]
        for (index, turn) in history.enumerated() {
            lines.append("")
            lines.append("Turn \(index + 1) question: \(turn.question)")
            lines.append("Turn \(index + 1) answer: \(turn.response)")
        }
        lines.append("")
        lines.append("New question: \(trimmedQuestion)")
        return lines.joined(separator: "\n")
    }
}
