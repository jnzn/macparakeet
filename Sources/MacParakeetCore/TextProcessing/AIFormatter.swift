import Foundation

public enum AIFormatter {
    public static let transcriptPlaceholder = "{{TRANSCRIPT}}"
    static let legacyDefaultPromptTemplateV1 = """
        You are a transcription cleanup assistant.

        Convert the following raw transcript into polished, readable text.

        Instructions:
        1. Add punctuation and capitalization.
        2. Split the text into proper sentences and paragraphs.
        3. Fix obvious speech-to-text errors.
        4. Remove repeated words and filler sounds when unnecessary.
        5. Keep the original meaning, tone, and wording as close as possible.
        6. Do not summarize, shorten, or add content.
        7. Do not explain your edits.
        8. Output only the final cleaned text.

        Raw transcript:
        {{TRANSCRIPT}}
        """

    public static let defaultPromptTemplate = """
        You are a transcription cleanup assistant.

        Convert the following raw transcript into polished, readable text.

        Instructions:
        1. Add punctuation and capitalization.
        2. Split the text into natural sentences.
        3. Break the text into readable paragraphs whenever the speaker moves into a new topic, example, action taken, or result.
        4. Prefer short paragraphs of 1 to 3 sentences.
        5. For medium-length monologues, favor multiple paragraphs over one dense block when the ideas naturally separate.
        6. Use real paragraph breaks in the cleaned text. If you need a new paragraph, put it in the text itself instead of writing the characters \\n.
        7. Fix obvious speech-to-text errors.
        8. Remove repeated words and filler sounds when unnecessary.
        9. Keep the original meaning, tone, and wording as close as possible.
        10. Do not summarize, shorten, or add content.
        11. Do not explain your edits.
        12. Output only the final cleaned text.

        Raw transcript:
        {{TRANSCRIPT}}
        """

    public static func normalizedPromptTemplate(_ promptTemplate: String) -> String {
        let trimmed = promptTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultPromptTemplate }
        if trimmed == legacyDefaultPromptTemplateV1 {
            return defaultPromptTemplate
        }
        return trimmed
    }

    public static func renderPrompt(template promptTemplate: String, transcript: String) -> String {
        let normalizedTemplate = normalizedPromptTemplate(promptTemplate)
        let normalizedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        guard normalizedTemplate.contains(transcriptPlaceholder) else {
            guard !normalizedTranscript.isEmpty else { return normalizedTemplate }
            return normalizedTemplate + "\n\nRaw transcript:\n" + normalizedTranscript
        }

        return normalizedTemplate.replacingOccurrences(
            of: transcriptPlaceholder,
            with: normalizedTranscript
        )
    }

    public static func normalizedFormattedOutput(_ output: String) -> String {
        // Strip chain-of-thought / "thinking" delimiters that hybrid-thinking
        // models (Gemma 4, Qwen3, DeepSeek-R1, etc.) leak into final output when
        // thinking mode isn't fully suppressed by the chat template. We take
        // everything after the LAST delimiter in each family — the final answer
        // lives there by convention.
        let stripped = stripThinkingDelimiters(output)
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        var normalized = trimmed.replacingOccurrences(of: "\r\n", with: "\n")
        normalized = normalized.replacingOccurrences(of: "\\r\\n", with: "\\n")

        if normalized.contains("\\n\\n") {
            normalized = normalized.replacingOccurrences(of: "\\n\\n", with: "\n\n")
        }

        if normalized.contains("\\n") {
            normalized = normalized.replacingOccurrences(of: "\\n", with: "\n\n")
        }

        while normalized.contains("\n\n\n") {
            normalized = normalized.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }

        return normalized
    }

    /// Strip chain-of-thought delimiters from model output. Hybrid-thinking models
    /// (Gemma 4 E2B/E4B, Qwen3, DeepSeek-R1) emit patterns like:
    ///   `<channel|>reasoning text<channel|>final answer`
    ///   `<think>reasoning</think>final answer`
    ///   `<|think|>reasoning<|/think|>final answer`
    /// For each family, the final answer lives after the LAST delimiter occurrence.
    /// Returns the tail as-is if any pattern matches; otherwise returns input unchanged.
    static func stripThinkingDelimiters(_ output: String) -> String {
        // Heuristic for hybrid-thinking model output cleanup:
        // - 2+ tag occurrences: convention is answer is in last channel (after
        //   the last tag). Slice after.
        // - 1 tag occurrence:
        //     - if text after is non-empty: it's the answer. Slice after.
        //     - if text after is empty/whitespace: the tag is a dangling
        //       artifact appended after the answer. Slice before.
        //   (Gemma 4 E2B emits `answer<channel|>` with a trailing tag even
        //    when `think: false` is set on the native /api/chat endpoint.)
        // - 0 occurrences: leave as-is.
        let patterns = [
            "<channel|>",
            "<|channel|>",
            "</think>",
            "<|/think|>",
            "<|think|>",
        ]
        var result = output
        for pattern in patterns {
            let occurrences = countOccurrences(of: pattern, in: result)
            if occurrences == 0 { continue }
            guard let lastRange = result.range(of: pattern, options: .backwards) else { continue }
            let after = String(result[lastRange.upperBound...])
            let afterTrim = after.trimmingCharacters(in: .whitespacesAndNewlines)
            if !afterTrim.isEmpty {
                result = after
            } else if occurrences == 1 {
                // Single trailing tag with no content after — keep the text before it.
                result = String(result[..<lastRange.lowerBound])
            }
            // Multi-tag with empty last-channel: fall through (leaves result
            // as the whole string; another pattern may catch it or final
            // empty-response fallback applies).
        }
        return result
    }

    private static func countOccurrences(of needle: String, in haystack: String) -> Int {
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, range: searchRange) {
            count += 1
            searchRange = found.upperBound..<haystack.endIndex
        }
        return count
    }
}
