import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// LLM client backed by Apple's on-device Foundation Models framework
/// (`SystemLanguageModel`), available starting macOS 26.0. No network
/// request, no bundled/downloaded model — the model is owned, sized, and
/// updated by the OS, not by MacParakeet. Conforms to `LLMClientProtocol` so
/// it plugs into `LLMService` via `RoutingLLMClient` like any other provider.
public final class FoundationModelsLLMClient: LLMClientProtocol, Sendable {
    public init() {}

    public func chatCompletion(
        messages: [ChatMessage],
        context: LLMExecutionContext,
        options: ChatCompletionOptions
    ) async throws -> ChatCompletionResponse {
        try options.validateInferenceSettings(for: context.providerConfig)
        var full = ""
        for try await delta in chatCompletionStream(messages: messages, context: context, options: options) {
            full += delta
        }
        return ChatCompletionResponse(content: full, model: Self.modelIdentifier)
    }

    public func chatCompletionStream(
        messages: [ChatMessage],
        context: LLMExecutionContext,
        options: ChatCompletionOptions
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.streamDeltas(messages: messages) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func chatCompletionDetailedStream(
        messages: [ChatMessage],
        context: LLMExecutionContext,
        options: ChatCompletionOptions
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.streamDeltas(messages: messages) { continuation.yield(.text($0)) }
                    continuation.yield(.completed(LLMStreamTerminal(
                        provider: context.providerConfig.id.rawValue,
                        model: Self.modelIdentifier
                    )))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func testConnection(context: LLMExecutionContext) async throws {
        try await ensureAvailable()
    }

    public func listModels(context: LLMExecutionContext) async throws -> [String] {
        [Self.modelIdentifier]
    }

    /// Synchronous, non-throwing availability check for callers (e.g.
    /// `AskProviderCatalog`) that need to decide whether to *offer* this
    /// provider before any conversation starts. Mirrors `ensureAvailable()`'s
    /// logic without the throw.
    public static var isAvailable: Bool {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return false }
        switch SystemLanguageModel.default.availability {
        case .available: return true
        default: return false
        }
        #else
        return false
        #endif
    }

    // MARK: - Private

    static let modelIdentifier = "apple-on-device"

    private func streamDeltas(
        messages: [ChatMessage],
        emit: @Sendable (String) -> Void
    ) async throws {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else {
            throw LLMError.providerError("Apple on-device AI requires macOS 26 or later.")
        }
        try await ensureAvailable()

        let session = LanguageModelSession()
        let prompt = Self.buildPrompt(from: messages)
        var previous = ""
        do {
            for try await partial in session.streamResponse(to: prompt) {
                let current = partial.content
                guard current.count > previous.count, current.hasPrefix(previous) else {
                    // Non-append revision (rare) — replace what we've sent so far.
                    if !current.isEmpty { emit(current) }
                    previous = current
                    continue
                }
                let delta = String(current.dropFirst(previous.count))
                previous = current
                if !delta.isEmpty {
                    emit(delta)
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LLMError.streamingError(error.localizedDescription)
        }
        #else
        throw LLMError.providerError("Apple on-device AI is not available on this build.")
        #endif
    }

    private func ensureAvailable() async throws {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else {
            throw LLMError.providerError("Apple on-device AI requires macOS 26 or later.")
        }
        switch SystemLanguageModel.default.availability {
        case .available:
            return
        case .unavailable(let reason):
            throw LLMError.modelNotFound("Apple on-device AI is unavailable: \(reason).")
        @unknown default:
            throw LLMError.modelNotFound("Apple on-device AI is unavailable.")
        }
        #else
        throw LLMError.providerError("Apple on-device AI is not available on this build.")
        #endif
    }

    /// Flattens the message array into a single prompt string — Foundation
    /// Models' session API takes plain text, not a role-tagged messages
    /// array. Mirrors `LocalCLILLMClient.extractPrompts`'s approach.
    static func buildPrompt(from messages: [ChatMessage]) -> String {
        let system = messages
            .filter { $0.role == .system }
            .map(\.content)
            .joined(separator: "\n\n")

        let nonSystem = messages.filter { $0.role != .system }
        let conversation: String
        if nonSystem.count == 1 {
            conversation = nonSystem[0].content
        } else {
            conversation = nonSystem.map { msg in
                let label = msg.role == .user ? "User" : "Assistant"
                return "\(label): \(msg.content)"
            }.joined(separator: "\n\n")
        }

        guard !system.isEmpty else { return conversation }
        return "\(system)\n\n\(conversation)"
    }
}
