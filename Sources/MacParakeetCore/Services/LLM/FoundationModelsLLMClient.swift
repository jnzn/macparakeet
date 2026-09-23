import Foundation
import OSLog

#if canImport(FoundationModels)
import FoundationModels
#endif

/// LLM client backed by Apple's on-device Foundation Models framework
/// (`SystemLanguageModel`), available starting macOS 26.0. No network
/// request, no bundled/downloaded model — the model is owned, sized, and
/// updated by the OS, not by MacParakeet. Conforms to `LLMClientProtocol` so
/// it plugs into `LLMService` via `RoutingLLMClient` like any other provider.
public final class FoundationModelsLLMClient: LLMClientProtocol, Sendable {
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "FoundationModelsLLMClient")

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

    /// Tokens the on-device model holds per session, prompt and reply together.
    /// The OS reports it (4096 through macOS 26.3); the fallback is that same
    /// figure for builds where the framework isn't available.
    public static var contextWindowTokens: Int {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.contextSize
        }
        #endif
        return 4096
    }

    /// Tokens held back for the reply; it is capped at this via
    /// `maximumResponseTokens`, so prompt + reply cannot overflow the window.
    static let responseReserveTokens = 1_024

    private func streamDeltas(
        messages: [ChatMessage],
        emit: @Sendable (String) -> Void
    ) async throws {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else {
            throw LLMError.providerError("Apple on-device AI requires macOS 26 or later.")
        }
        try await ensureAvailable()

        let inputs = await Self.fitToContextWindow(Self.buildSessionInputs(from: messages))
        let session = LanguageModelSession(instructions: inputs.instructions)
        // Cap the reply so prompt + reply always fit the session window; the
        // prompt side is budgeted by `LLMService.appleOnDeviceContextBudget`.
        let options = GenerationOptions(maximumResponseTokens: Self.responseReserveTokens)
        var accumulator = SnapshotDeltaAccumulator()
        do {
            for try await partial in session.streamResponse(to: inputs.prompt, options: options) {
                switch accumulator.delta(for: partial.content) {
                case .append(let text):
                    emit(text)
                case .unchanged:
                    break
                case .diverged:
                    logger.notice("apple_stream_snapshot_diverged sent=\(accumulator.emitted.count, privacy: .public)")
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.mapSessionError(error)
        }
        #else
        throw LLMError.providerError("Apple on-device AI is not available on this build.")
        #endif
    }

    /// Guarantees the prompt fits, using the model's own tokenizer where it has
    /// one (macOS 26.4+). `LLMService` already trims to a character budget, but
    /// characters-per-token swings with content — timestamps, digits and
    /// non-English text tokenize far worse than English prose — so this measures
    /// the real thing and trims the middle of the instructions (which hold the
    /// transcript; the rules at the head and the latest speech at the tail stay)
    /// until prompt + reply reserve fit. Earlier releases keep the character budget.
    static func fitToContextWindow(
        _ inputs: (instructions: String?, prompt: String)
    ) async -> (instructions: String?, prompt: String) {
        #if canImport(FoundationModels)
        guard #available(macOS 26.4, *), var instructions = inputs.instructions else { return inputs }
        let model = SystemLanguageModel.default
        let allowance = contextWindowTokens - responseReserveTokens
        guard allowance > 0, let promptTokens = try? await model.tokenCount(for: inputs.prompt) else { return inputs }

        for _ in 0..<4 {
            guard let instructionTokens = try? await model.tokenCount(for: instructions) else { break }
            let used = instructionTokens + promptTokens
            if used <= allowance { break }
            // Scale to the overshoot, with a margin so one pass usually lands.
            let keepFraction = Double(max(0, allowance - promptTokens)) / Double(max(1, instructionTokens)) * 0.92
            let newLimit = Int(Double(instructions.count) * keepFraction)
            guard newLimit > 0, newLimit < instructions.count else { break }
            instructions = LLMService.truncateMiddle(instructions, limit: newLimit)
        }
        return (instructions, inputs.prompt)
        #else
        return inputs
        #endif
    }

    /// Context-window overflow becomes the app's own `contextTooLong` (the raw
    /// framework text differs by OS release and reads like a crash); everything
    /// else keeps its description.
    static func mapSessionError(_ error: Error) -> LLMError {
        isContextWindowError(error)
            ? .contextTooLong
            : .streamingError(error.localizedDescription)
    }

    /// Matches the overflow error across OS releases without naming the
    /// SDK-specific types: macOS 26 throws `GenerationError.exceededContextWindowSize`
    /// ("Exceeded model context window size"), macOS 27 throws
    /// `LanguageModelError.contextSizeExceeded` ("…exceeded the model's context
    /// size"). The case names survive localization; the prose check covers the rest.
    static func isContextWindowError(_ error: Error) -> Bool {
        let caseName = String(describing: error)
        if caseName.contains("exceededContextWindowSize") || caseName.contains("contextSizeExceeded") {
            return true
        }
        let text = error.localizedDescription.lowercased()
        return text.contains("context") && text.contains("exceed")
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

    /// Splits the message array into what Foundation Models actually
    /// distinguishes: session *instructions* (the system prompt, including any
    /// transcript reference material) and the *prompt* (the turn to answer).
    ///
    /// Sending everything as one prompt string made the model treat the
    /// system text and transcript as a document to continue, so a bare "hi"
    /// after a transcript got an invented question answered instead of a
    /// greeting. Multi-turn history is still flattened into the prompt with
    /// role labels, as before.
    static func buildSessionInputs(from messages: [ChatMessage]) -> (instructions: String?, prompt: String) {
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

        return (system.isEmpty ? nil : system, conversation)
    }
}

/// Turns Foundation Models' cumulative stream snapshots into append-only text
/// deltas.
///
/// The stream yields the *whole reply so far* each time, and repeats the
/// finished snapshot (observed: two or three identical trailing snapshots per
/// reply). Treating "not longer than before" as a revision and re-sending the
/// full text made the consumer append a complete extra copy per repeat, glued
/// on with no separator.
struct SnapshotDeltaAccumulator {
    enum Delta: Equatable {
        /// New text to append to what the consumer already has.
        case append(String)
        /// Nothing new — a repeated snapshot, or one already covered.
        case unchanged
        /// The reply changed something already sent. Deltas can't retract
        /// text, so this snapshot is skipped rather than re-sent.
        case diverged
    }

    /// Everything sent to the consumer so far.
    private(set) var emitted = ""

    mutating func delta(for snapshot: String) -> Delta {
        if snapshot == emitted { return .unchanged }
        if snapshot.hasPrefix(emitted) {
            let text = String(snapshot.dropFirst(emitted.count))
            emitted = snapshot
            return .append(text)
        }
        // A shorter prefix of what's already been sent: wait for it to grow back.
        if emitted.hasPrefix(snapshot) { return .unchanged }
        return .diverged
    }
}
