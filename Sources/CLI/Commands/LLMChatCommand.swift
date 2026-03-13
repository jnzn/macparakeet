import ArgumentParser
import Foundation
import MacParakeetCore

struct LLMChatCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "chat",
        abstract: "Ask a question about a transcript using an LLM provider."
    )

    @OptionGroup var llm: LLMInlineOptions

    @Argument(help: "Path to transcript text file. Use '-' for stdin.")
    var input: String

    @Option(name: .shortAndLong, help: "Question to ask about the transcript.")
    var question: String

    @Flag(name: .long, help: "Stream the response token by token.")
    var stream: Bool = false

    func run() async throws {
        let text = try readInput(input)

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            print("Input is empty.")
            throw ExitCode.failure
        }

        let config = try llm.buildConfig()
        let client = LLMClient()
        let systemPrompt = "You are a helpful assistant. The user will ask questions about the following transcript. Answer based on the transcript content. If the answer isn't in the transcript, say so.\n\n---\nTranscript:\n\(text)"

        let messages = [
            ChatMessage(role: .system, content: systemPrompt),
            ChatMessage(role: .user, content: question),
        ]

        if stream {
            let tokenStream = client.chatCompletionStream(messages: messages, config: config, options: .default)
            for try await token in tokenStream {
                print(token, terminator: "")
            }
            print()
        } else {
            let response = try await client.chatCompletion(messages: messages, config: config, options: .default)
            print(response.content)
        }
    }
}
