import ArgumentParser
import Foundation
import MacParakeetCore

struct LLMTransformCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transform",
        abstract: "Apply a custom LLM transform to text from a file or stdin."
    )

    @OptionGroup var llm: LLMInlineOptions

    @Argument(help: "Path to text file to transform. Use '-' for stdin.")
    var input: String

    @Option(name: .shortAndLong, help: "Transform instruction (e.g. 'Make it formal', 'Translate to Spanish').")
    var prompt: String

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
        let messages = [
            ChatMessage(role: .system, content: "You are a helpful assistant that transforms text according to user instructions. Apply the requested transformation to the provided text. Return only the transformed text without explanation."),
            ChatMessage(role: .user, content: "Transform the following text according to this instruction: \(prompt)\n\n---\n\n\(text)"),
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
