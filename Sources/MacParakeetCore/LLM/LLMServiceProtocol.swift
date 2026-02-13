import Foundation

public struct LLMGenerationOptions: Sendable {
    public var temperature: Float
    public var topP: Float
    public var maxTokens: Int?
    public var timeoutSeconds: TimeInterval?

    public init(
        temperature: Float = 0.6,
        topP: Float = 0.95,
        maxTokens: Int? = 512,
        timeoutSeconds: TimeInterval? = 120
    ) {
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct LLMRequest: Sendable {
    public var prompt: String
    public var systemPrompt: String?
    public var options: LLMGenerationOptions

    public init(
        prompt: String,
        systemPrompt: String? = nil,
        options: LLMGenerationOptions = .init()
    ) {
        self.prompt = prompt
        self.systemPrompt = systemPrompt
        self.options = options
    }
}

public struct LLMResponse: Sendable {
    public var text: String
    public var modelID: String
    public var durationSeconds: TimeInterval

    public init(text: String, modelID: String, durationSeconds: TimeInterval) {
        self.text = text
        self.modelID = modelID
        self.durationSeconds = durationSeconds
    }
}

public enum LLMServiceError: Error, LocalizedError, Sendable {
    case invalidPrompt
    case timedOut(seconds: TimeInterval)
    case emptyResponse
    case generationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPrompt:
            return "Prompt is empty."
        case .timedOut(let seconds):
            return "Local model generation timed out after \(Int(seconds))s."
        case .emptyResponse:
            return "Local model returned an empty response."
        case .generationFailed(let message):
            return "Local model generation failed: \(message)"
        }
    }
}

public protocol LLMServiceProtocol: Sendable {
    func generate(request: LLMRequest) async throws -> LLMResponse
}
