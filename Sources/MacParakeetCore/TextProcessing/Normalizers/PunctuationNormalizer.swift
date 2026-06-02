import Foundation

/// Spoken punctuation commands. Multi-word/unambiguous commands always
/// convert and attach to the preceding word. "period"/"comma" convert ONLY
/// as the final word of the text (the classic "…send it today period"
/// pattern) — mid-text occurrences are real words and stay untouched.
public enum PunctuationNormalizer {
    public static func normalize(_ text: String) -> String {
        var result = text

        // Always-safe commands: attach to the preceding word.
        let always: [(String, String)] = [
            ("question mark", "?"), ("exclamation point", "!"), ("exclamation mark", "!"),
            ("semicolon", ";"),
        ]
        for (spoken, mark) in always {
            result = NormalizerRegex.replace(result, pattern: "(\\S) \(spoken)\\b") { g in "\(g[1])\(mark)" }
        }

        // Quotes: open quote X close quote → "X"
        result = NormalizerRegex.replace(result, pattern: #"open quote (.+?) close quote"#) { g in "\"\(g[1])\"" }

        // End-of-text-only commands.
        let trimmed = result.trimmingCharacters(in: .whitespaces)
        for (spoken, mark) in [("period", "."), ("comma", ",")] {
            if trimmed.lowercased().hasSuffix(" \(spoken)") {
                let head = String(trimmed.dropLast(spoken.count + 1))
                result = "\(head)\(mark)"
                break
            }
        }
        return result
    }
}
