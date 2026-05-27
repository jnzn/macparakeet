import Foundation

/// Cleans up LLM output into a short, file-safe transcript title.
///
/// Models often wrap titles in quotes, prefix them with "Title:", emit a
/// markdown heading, or add a trailing period. This strips that noise down to
/// a single concise line suitable for `Transcription.fileName`.
public enum TitleSanitizer {
    /// System prompt used when asking an LLM to title a transcript.
    public static let titleSystemPrompt = """
    You generate a title for a meeting or audio transcript. \
    Reply with ONLY the title and nothing else: 3-7 words, Title Case, \
    no surrounding quotes, no markdown, no trailing punctuation, no preamble \
    like "Title:".
    """

    /// Maximum title length; longer output is truncated on a word boundary.
    static let maxLength = 60

    public static func sanitize(_ raw: String) -> String {
        // Take the first non-empty line — models sometimes add explanation below.
        let firstLine = raw
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? ""

        var title = firstLine

        // Drop a leading "Title:" / "Title -" style label if present.
        if let range = title.range(of: #"^\s*title\s*[:\-–]\s*"#, options: [.regularExpression, .caseInsensitive]) {
            title.removeSubrange(range)
        }

        // Strip leading markdown heading markers and list bullets.
        title = title.replacingOccurrences(
            of: #"^[#>\-\*\s]+"#,
            with: "",
            options: .regularExpression
        )

        // Strip matched surrounding quotes/backticks (straight or curly).
        title = stripMatchingWrappers(title)

        // Collapse internal whitespace.
        title = title.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )

        // Trim trailing sentence punctuation.
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: " .,;:!"))

        // Clamp length on a word boundary.
        if title.count > maxLength {
            let clamped = String(title.prefix(maxLength))
            if let lastSpace = clamped.lastIndex(of: " ") {
                title = String(clamped[..<lastSpace])
            } else {
                title = clamped
            }
            title = title.trimmingCharacters(in: .whitespaces)
        }

        return title
    }

    /// Removes a single pair of matching wrapping characters (e.g. "…", '…',
    /// `…`, “…”) if both ends match. Repeats so `"'x'"` fully unwraps.
    private static func stripMatchingWrappers(_ input: String) -> String {
        var result = input.trimmingCharacters(in: .whitespaces)
        let pairs: [(Character, Character)] = [
            ("\"", "\""), ("'", "'"), ("`", "`"), ("\u{201C}", "\u{201D}"), ("\u{2018}", "\u{2019}"),
        ]
        var changed = true
        while changed {
            changed = false
            guard let first = result.first, let last = result.last, result.count >= 2 else { break }
            for (open, close) in pairs where first == open && last == close {
                result = String(result.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                changed = true
                break
            }
        }
        return result
    }
}
