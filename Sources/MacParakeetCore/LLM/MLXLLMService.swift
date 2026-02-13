import Foundation
import MLXLLM
import MLXLMCommon

public actor MLXLLMService: LLMServiceProtocol {
    public static let defaultModelID = "mlx-community/Qwen3-8B-4bit"

    private let modelID: String
    private let revision: String
    private var modelContainer: ModelContainer?

    public init(
        modelID: String = MLXLLMService.defaultModelID,
        revision: String = "main"
    ) {
        self.modelID = modelID
        self.revision = revision
    }

    public func unload() {
        modelContainer = nil
    }

    public func generate(request: LLMRequest) async throws -> LLMResponse {
        let trimmedPrompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw LLMServiceError.invalidPrompt
        }

        let container = try await ensureModelLoaded()
        let startedAt = Date()
        let parameters = GenerateParameters(
            maxTokens: request.options.maxTokens,
            temperature: request.options.temperature,
            topP: request.options.topP
        )
        let session = ChatSession(
            container,
            instructions: request.systemPrompt,
            generateParameters: parameters
        )

        let output = try await withTimeout(seconds: request.options.timeoutSeconds) {
            try await session.respond(to: trimmedPrompt)
        }

        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw LLMServiceError.emptyResponse
        }

        return LLMResponse(
            text: text,
            modelID: modelID,
            durationSeconds: Date().timeIntervalSince(startedAt)
        )
    }

    private func ensureModelLoaded() async throws -> ModelContainer {
        if let modelContainer {
            return modelContainer
        }

        let loaded = try await loadModelContainer(id: modelID, revision: revision)
        modelContainer = loaded
        return loaded
    }

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval?,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard let seconds, seconds > 0 else {
            return try await operation()
        }

        let timeoutNs = UInt64(max(0, seconds) * 1_000_000_000)

        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNs)
                throw LLMServiceError.timedOut(seconds: seconds)
            }

            let result = try await group.next()
            group.cancelAll()
            guard let result else {
                throw LLMServiceError.generationFailed("No result returned.")
            }
            return result
        }
    }
}
