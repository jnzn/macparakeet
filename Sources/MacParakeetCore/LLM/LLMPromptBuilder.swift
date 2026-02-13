import Foundation

public enum LLMRefinementMode: String, CaseIterable, Sendable {
    case formal
    case email
    case code
}

public enum LLMTask: Sendable {
    case refine(mode: LLMRefinementMode, input: String)
    case commandTransform(command: String, selectedText: String)
    case transcriptChat(question: String, transcript: String)
}

public enum LLMPromptBuilder {
    public static func systemPrompt(for task: LLMTask) -> String {
        switch task {
        case .refine(let mode, _):
            switch mode {
            case .formal:
                return """
                You are a concise professional editor. Improve clarity and tone while preserving meaning.
                Return only the rewritten text.
                """
            case .email:
                return """
                You are an email writing assistant. Produce a clean, professional email body.
                Return only the rewritten email text.
                """
            case .code:
                return """
                You are a technical editor. Preserve code identifiers, symbols, and formatting intent.
                Return only the rewritten text.
                """
            }
        case .commandTransform:
            return """
            You execute text-editing commands. Apply the command exactly to the provided text.
            Return only the transformed text.
            """
        case .transcriptChat:
            return """
            You answer questions using only the provided transcript context.
            If context is insufficient, say so briefly.
            """
        }
    }

    public static func userPrompt(for task: LLMTask) -> String {
        switch task {
        case .refine(let mode, let input):
            let label: String
            switch mode {
            case .formal:
                label = "Rewrite in a formal professional tone."
            case .email:
                label = "Rewrite as a polished email."
            case .code:
                label = "Rewrite while preserving technical/code semantics."
            }
            return """
            Task: \(label)

            Text:
            \(input)
            """
        case .commandTransform(let command, let selectedText):
            return """
            Command:
            \(command)

            Selected text:
            \(selectedText)
            """
        case .transcriptChat(let question, let transcript):
            return """
            Transcript:
            \(transcript)

            Question:
            \(question)
            """
        }
    }
}
