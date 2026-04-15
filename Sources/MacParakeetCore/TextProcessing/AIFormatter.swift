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

    /// Previous conservative-cleanup default (was the default before V4).
    /// Returned too-timid results when paired with models that see Parakeet's
    /// already-decent output and decline to change much — swap users to V4
    /// which prescribes the transformations explicitly.
    static let legacyDefaultPromptTemplateV3 = """
        Clean up ASR-transcribed text. Output ONLY the corrected text. No preamble, no reasoning, no explanations, no `<channel|>` tags, no markdown.

        Rules:
        - Fix punctuation and capitalization.
        - Fix obvious word confusions (e.g., wood/would, their/there, two/to).
        - Collapse ASR stutter where the same word repeats back-to-back unnaturally (e.g., "the the cat" → "the cat", "whisper whisper whisper flow" → "whisper flow"). Keep repetition that is clearly intentional for emphasis (e.g., "no no no", "very very slowly").
        - Remove filler sounds like "um", "uh", "like" only when they're clearly filler, not when they carry meaning.
        - Preserve the speaker's wording, tone, and meaning exactly.
        - Do NOT paraphrase, summarize, or add content.
        - If already correct, return unchanged.

        Input: {{TRANSCRIPT}}
        """

    /// Previous 12-rule default (paragraph-aware version). Upgraders who never
    /// customized their prompt should migrate silently to the current default
    /// that prioritizes conservative "fix typos only" semantics for ASR cleanup.
    static let legacyDefaultPromptTemplateV2 = """
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

    public static let defaultPromptTemplate = """
        Clean up ASR-transcribed speech. Output ONLY the corrected text — no preamble, no reasoning, no explanations, no `<channel|>` tags, no markdown.

        Required transformations (do these every time, even if input looks OK):
        - Split the run-on transcript into proper sentences. End each with `.` `?` or `!`.
        - Capitalize the first word of every sentence.
        - Capitalize proper nouns, product names, acronyms, and first-person "I".
        - Insert commas where natural speech rhythm + English grammar demand them (lists, appositives, after intro phrases, before "but" / "and" in compound sentences).
        - Fix obvious homophone errors from speech-to-text (wood↔would, their↔there↔they're, two↔to↔too, its↔it's, etc.).
        - Collapse ASR stutter ("the the cat" → "the cat", "whisper whisper flow" → "whisper flow"). Keep intentional repetition ("no no no", "very very").
        - Remove filler words ("um", "uh", sometimes "like") only when clearly filler, not when they carry meaning.

        Preserve:
        - The speaker's wording, word order, phrasing, and tone.
        - The substance and order of ideas.

        Never:
        - Paraphrase, summarize, shorten, or add content.
        - Change word choices beyond homophone correction.
        - Explain your changes or output anything other than the cleaned text.

        Input: {{TRANSCRIPT}}
        """

    public static func normalizedPromptTemplate(_ promptTemplate: String) -> String {
        let trimmed = promptTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultPromptTemplate }
        if trimmed == legacyDefaultPromptTemplateV1 {
            return defaultPromptTemplate
        }
        if trimmed == legacyDefaultPromptTemplateV2.trimmingCharacters(in: .whitespacesAndNewlines) {
            return defaultPromptTemplate
        }
        if trimmed == legacyDefaultPromptTemplateV3.trimmingCharacters(in: .whitespacesAndNewlines) {
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
