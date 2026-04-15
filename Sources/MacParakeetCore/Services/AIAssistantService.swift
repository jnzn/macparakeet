import Foundation
import OSLog

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

        public var displayName: String {
            switch self {
            case .claude: return "Claude Code"
            case .codex: return "Codex"
            }
        }

        /// Default invocation template with skip-permissions flags baked in,
        /// per the agreed V1 spec. Users can override in Settings.
        public var defaultCommandTemplate: String {
            switch self {
            case .claude:
                return "claude --dangerously-skip-permissions -p"
            case .codex:
                return "codex exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check"
            }
        }

        public var defaultModel: String {
            switch self {
            case .claude: return "sonnet"
            case .codex: return "gpt-5.2"
            }
        }
    }

    public let provider: Provider
    public let commandTemplate: String
    public let modelName: String
    public let timeoutSeconds: Double

    public static let minimumTimeout: Double = 5
    public static let defaultTimeout: Double = 120

    public init(
        provider: Provider,
        commandTemplate: String? = nil,
        modelName: String? = nil,
        timeoutSeconds: Double = Self.defaultTimeout
    ) {
        self.provider = provider
        self.commandTemplate = commandTemplate ?? provider.defaultCommandTemplate
        self.modelName = modelName ?? provider.defaultModel
        self.timeoutSeconds = max(Self.minimumTimeout, timeoutSeconds)
    }

    public static var defaultClaude: AIAssistantConfig {
        AIAssistantConfig(provider: .claude)
    }

    public static var defaultCodex: AIAssistantConfig {
        AIAssistantConfig(provider: .codex)
    }

    /// The effective command passed to the shell, combining the user-editable
    /// template with the selected model (if the template doesn't already
    /// specify one — presence of "--model" wins).
    public var effectiveCommandTemplate: String {
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

    public init(selection: String, question: String, history: [AIAssistantTurn] = []) {
        self.selection = selection
        self.question = question
        self.history = history
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
    private let configProvider: @Sendable () -> AIAssistantConfig?

    public init(
        executor: any AIAssistantExecuting = LocalCLIExecutor(),
        configProvider: @escaping @Sendable () -> AIAssistantConfig?
    ) {
        self.executor = executor
        self.configProvider = configProvider
    }

    public func ask(_ request: AIAssistantRequest) async throws -> String {
        guard let config = configProvider() else {
            throw LocalCLIError.commandNotConfigured
        }
        let cliConfig = LocalCLIConfig(
            commandTemplate: config.effectiveCommandTemplate,
            timeoutSeconds: config.timeoutSeconds
        )
        let system = Self.renderSystemPrompt(selection: request.selection)
        let user = Self.renderUserPrompt(history: request.history, question: request.question)
        logger.info(
            "ask provider=\(config.provider.rawValue, privacy: .public) selectionChars=\(request.selection.count) questionChars=\(request.question.count) historyTurns=\(request.history.count)"
        )
        let output = try await executor.execute(
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
