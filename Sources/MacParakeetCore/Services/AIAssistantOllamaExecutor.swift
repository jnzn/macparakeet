import Foundation
import OSLog

public enum AIAssistantOllamaExecutorError: Error, LocalizedError, Sendable {
    case notConfigured
    case emptyOutput

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Ollama isn't configured. Open Settings -> AI Provider to set the URL and model."
        case .emptyOutput:
            return "Ollama returned an empty response."
        }
    }
}

/// HTTP-backed Ollama executor for the AI Assistant bubble. Reuses the
/// formatter's stored Ollama URL + model from `LLMConfigStore` so the bubble
/// can talk to remote Ollama instances (for example over Tailscale) without
/// requiring an `ollama` binary on the local PATH.
public final class AIAssistantOllamaExecutor: AIAssistantExecuting, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "AIAssistantOllamaExecutor")
    private let configStore: LLMConfigStoreProtocol
    private let session: URLSession

    public init(
        configStore: LLMConfigStoreProtocol = LLMConfigStore(),
        session: URLSession = .shared
    ) {
        self.configStore = configStore
        self.session = session
    }

    public func execute(
        systemPrompt: String,
        userPrompt: String,
        config: LocalCLIConfig
    ) async throws -> String {
        guard let providerConfig = try configStore.loadConfig(),
              providerConfig.id == .ollama else {
            throw AIAssistantOllamaExecutorError.notConfigured
        }

        let request = try buildRequest(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            providerConfig: providerConfig,
            timeout: config.timeoutSeconds
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LLMError.connectionFailed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.connectionFailed("Invalid response.")
        }

        guard (200...299).contains(http.statusCode) else {
            throw mapError(statusCode: http.statusCode, data: data, modelName: providerConfig.modelName)
        }

        guard let ollamaResponse = try? JSONDecoder().decode(OllamaChatResponse.self, from: data) else {
            throw LLMError.invalidResponse
        }

        let stripped = AIFormatter.stripThinkingDelimiters(ollamaResponse.message.content)
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            logger.warning("execute_empty_output model=\(providerConfig.modelName, privacy: .public)")
            throw AIAssistantOllamaExecutorError.emptyOutput
        }
        return trimmed
    }

    private func buildRequest(
        systemPrompt: String,
        userPrompt: String,
        providerConfig: LLMProviderConfig,
        timeout: Double
    ) throws -> URLRequest {
        let url = try ollamaChatURL(from: providerConfig.baseURL)

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = OllamaChatRequest(
            model: providerConfig.modelName,
            messages: [
                OllamaMessage(role: ChatMessage.Role.system.rawValue, content: systemPrompt),
                OllamaMessage(role: ChatMessage.Role.user.rawValue, content: userPrompt),
            ],
            stream: false,
            think: false,
            keep_alive: "5m",
            options: OllamaRequestOptions(num_ctx: 8192)
        )

        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private func ollamaChatURL(from baseURL: URL) throws -> URL {
        var baseString = baseURL.absoluteString
        if baseString.hasSuffix("/v1") {
            baseString = String(baseString.dropLast(3))
        } else if baseString.hasSuffix("/v1/") {
            baseString = String(baseString.dropLast(4))
        }
        guard let normalized = URL(string: baseString) else {
            throw LLMError.connectionFailed("Invalid Ollama base URL: \(baseString)")
        }
        return normalized.appendingPathComponent("api/chat")
    }

    private func mapError(statusCode: Int, data: Data, modelName: String) -> Error {
        if let error = try? JSONDecoder().decode(StreamErrorResponse.self, from: data),
           let message = error.error,
           !message.isEmpty {
            if statusCode == 404 {
                return LLMError.modelNotFound(modelName)
            }
            return LLMError.providerError(message)
        }

        if let openAIError = try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data) {
            if statusCode == 404 {
                return LLMError.modelNotFound(modelName)
            }
            return LLMError.providerError(openAIError.error.message)
        }

        let detail = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if statusCode == 404 {
            return LLMError.modelNotFound(modelName)
        }

        if let detail, !detail.isEmpty {
            return LLMError.providerError(detail)
        }

        return LLMError.providerError("HTTP \(statusCode)")
    }
}
