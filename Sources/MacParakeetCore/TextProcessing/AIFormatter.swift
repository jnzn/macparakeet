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

    /// Inject an `AppContext` hint block into a prompt template immediately
    /// before the line containing `{{TRANSCRIPT}}`. Returns the template
    /// unchanged when the context is nil/empty.
    ///
    /// The inserted block is clearly labeled as *context, not content to
    /// rewrite* so profile prompts that say "Preserve the speaker's wording"
    /// don't accidentally see the window title as text to clean.
    public static func injectContextIntoPrompt(
        template: String,
        context: AppContext?
    ) -> String {
        guard let context, !context.isEmpty else { return template }
        let block = context.asPromptBlock()
        guard !block.isEmpty else { return template }

        let preamble = """
            App context from the frontmost window. Treat names visible here as ground truth — override the "preserve the speaker's wording" rule ONLY to fix names. When a garbled or phonetically-odd segment of the transcript plausibly refers to a name shown below (even loosely — e.g. transcript says "just one" but window title is "Chat with Janet" → use "Janet"; transcript says "Sue Shan" but window shows "Sue Chan" → use "Sue Chan"), replace it with the correct spelling from this context. Do NOT copy this context block itself into your output — it is reference material, not content to clean.

            \(block)

            """

        // The transcript block in a prompt is always introduced by a label —
        // either `Input: {{TRANSCRIPT}}` (same line) or `Raw transcript:\n
        // {{TRANSCRIPT}}` (label on prior line). Walk back from the placeholder
        // and split the template into prefix + transcript-block at the label
        // boundary so the preamble lands *before* the label, never between it
        // and the transcript itself.
        guard let placeholderRange = template.range(of: transcriptPlaceholder) else {
            return "\(preamble)\n\(template)"
        }

        let labelMarkers = ["Input: ", "Raw transcript:"]
        let head = String(template[..<placeholderRange.lowerBound])
        var splitIndex = template.startIndex
        for marker in labelMarkers {
            if let markerRange = head.range(of: marker, options: .backwards) {
                splitIndex = markerRange.lowerBound
                break
            }
        }
        if splitIndex == template.startIndex {
            // No labeled boundary found — fall back to inserting before the
            // placeholder's own line so the preamble at least doesn't mangle
            // the surrounding markup.
            let priorNewline = template[..<placeholderRange.lowerBound].lastIndex(of: "\n")
            splitIndex = priorNewline.map { template.index(after: $0) } ?? template.startIndex
        }

        var updated = template
        updated.insert(contentsOf: preamble + "\n", at: splitIndex)
        return updated
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
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
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
}
