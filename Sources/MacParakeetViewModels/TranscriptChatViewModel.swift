import Foundation
import MacParakeetCore

public struct ChatDisplayMessage: Identifiable, Equatable {
    public let id: UUID
    public let role: ChatMessage.Role
    public var content: String
    public var isStreaming: Bool

    public init(id: UUID = UUID(), role: ChatMessage.Role, content: String, isStreaming: Bool = false) {
        self.id = id
        self.role = role
        self.content = content
        self.isStreaming = isStreaming
    }
}

@MainActor
@Observable
public final class TranscriptChatViewModel {
    public var messages: [ChatDisplayMessage] = []
    public var inputText: String = ""
    public var isStreaming: Bool = false
    public var errorMessage: String?

    private var llmService: LLMServiceProtocol?
    private var transcriptText: String = ""
    private var chatHistory: [ChatMessage] = []
    private var streamingTask: Task<Void, Never>?

    public init() {}

    public func configure(llmService: LLMServiceProtocol, transcriptText: String) {
        self.llmService = llmService
        self.transcriptText = transcriptText
    }

    public func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming, let llmService else { return }

        inputText = ""
        errorMessage = nil

        let userMessage = ChatDisplayMessage(role: .user, content: text)
        messages.append(userMessage)

        let assistantID = UUID()
        let assistantMessage = ChatDisplayMessage(id: assistantID, role: .assistant, content: "", isStreaming: true)
        messages.append(assistantMessage)
        isStreaming = true

        let history = chatHistory
        let transcript = transcriptText

        streamingTask = Task {
            var accumulated = ""
            do {
                let stream = llmService.chatStream(
                    question: text,
                    transcript: transcript,
                    history: history
                )
                for try await token in stream {
                    accumulated += token
                    if let idx = messages.firstIndex(where: { $0.id == assistantID }) {
                        messages[idx].content = accumulated
                    }
                }

                if let idx = messages.firstIndex(where: { $0.id == assistantID }) {
                    messages[idx].isStreaming = false
                }

                chatHistory.append(ChatMessage(role: .user, content: text))
                chatHistory.append(ChatMessage(role: .assistant, content: accumulated))
            } catch {
                if let idx = messages.firstIndex(where: { $0.id == assistantID }) {
                    messages[idx].isStreaming = false
                    if accumulated.isEmpty {
                        messages.remove(at: idx)
                    }
                }
                errorMessage = error.localizedDescription
            }
            isStreaming = false
        }
    }

    public func cancelStreaming() {
        streamingTask?.cancel()
        streamingTask = nil
        isStreaming = false
        if let lastIdx = messages.indices.last, messages[lastIdx].isStreaming {
            messages[lastIdx].isStreaming = false
        }
    }

    public func updateTranscript(_ text: String) {
        transcriptText = text
        clearHistory()
    }

    public func clearHistory() {
        messages.removeAll()
        chatHistory.removeAll()
        errorMessage = nil
        inputText = ""
    }
}
