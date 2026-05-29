import Foundation

/// Deterministic 5-step text processing pipeline.
/// Pure function: same input always produces same output.
///
/// Steps: Filler Removal → Custom Words → Terminal Symbol Expansion (terminal profiles only) → Trailing Action Extraction → Snippet Expansion → Whitespace Cleanup
public struct TextProcessingPipeline: Sendable {

    public init() {}

    /// Process raw STT text through the full pipeline.
    /// Pass `isTerminalProfile: true` when the frontmost app is a terminal emulator
    /// so that spoken symbol words ("slash", "tilde", etc.) are converted to their
    /// literal characters at paste time — without requiring an LLM API key.
    public func process(
        text: String,
        customWords: [CustomWord],
        snippets: [TextSnippet],
        isTerminalProfile: Bool = false
    ) -> TextProcessingResult {
        guard !text.isEmpty else {
            return TextProcessingResult(text: "")
        }

        let textSnippets = snippets.filter { $0.action == nil }
        let actionSnippets = snippets.filter { $0.action != nil }

        var result = text

        // Step 1: Filler removal
        result = removeFillers(from: result)

        // Step 2: Custom word replacements
        result = applyCustomWords(to: result, words: customWords)

        // Step 2.5: Terminal symbol expansion (only for terminal app profiles)
        if isTerminalProfile {
            result = expandTerminalSymbols(in: result)
        }

        // Step 3: Extract trailing action snippet (before expansion, so trigger isn't mangled)
        var actionIDs = Set<UUID>()
        var postPasteAction: KeyAction?
        let (actionCleanedText, matchedSnippet) = extractTrailingAction(
            from: result, actionSnippets: actionSnippets
        )
        if let matchedSnippet {
            result = actionCleanedText
            postPasteAction = matchedSnippet.action
            actionIDs.insert(matchedSnippet.id)
        }

        // Step 4: Text snippet expansion (text-type only)
        let (expandedText, expandedIDs) = expandSnippets(in: result, snippets: textSnippets)
        result = expandedText

        // Step 5: Whitespace cleanup — skip first-letter capitalisation for terminal
        result = cleanWhitespace(in: result, capitalizeFirst: !isTerminalProfile)

        return TextProcessingResult(
            text: result,
            expandedSnippetIDs: expandedIDs.union(actionIDs),
            postPasteAction: postPasteAction
        )
    }

    // MARK: - Step 1: Filler Removal

    /// Always-safe fillers (always removed)
    /// Only pure hesitation sounds — words that never carry meaning.
    private static let alwaysSafeFillers = [
        "um", "uh", "umm", "uhh"
    ]

    /// Pre-compiled filler regexes — avoids recompilation on every dictation.
    private static let fillerRegexes: [NSRegularExpression] = alwaysSafeFillers.compactMap { filler in
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: filler))\\b"
        return try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }

    func removeFillers(from text: String) -> String {
        var result = text

        for regex in Self.fillerRegexes {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }

        return result
    }

    // MARK: - Step 2: Custom Word Replacements

    func applyCustomWords(to text: String, words: [CustomWord]) -> String {
        var result = text

        for word in words {
            guard word.isEnabled else { continue }

            let replacement = word.replacement ?? word.word
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: word.word))\\b"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: NSRegularExpression.escapedTemplate(for: replacement)
                )
            }
        }

        return result
    }

    // MARK: - Step 3: Trailing Action Extraction

    func extractTrailingAction(
        from text: String,
        actionSnippets: [TextSnippet]
    ) -> (String, TextSnippet?) {
        guard !actionSnippets.isEmpty else { return (text, nil) }

        // Sort longest-trigger-first (same as expandSnippets)
        let sorted = actionSnippets
            .filter { $0.isEnabled }
            .sorted { $0.trigger.count > $1.trigger.count }

        for snippet in sorted {
            // Punctuation-tolerant: match trigger at end with optional trailing punctuation.
            // Normalize literal spaces to \s+ so filler removal gaps (double spaces) still match.
            let escaped = NSRegularExpression.escapedPattern(for: snippet.trigger)
            let spaceNormalized = escaped.replacingOccurrences(of: " ", with: "\\s+")
            let pattern = "\\b\(spaceNormalized)[.!?,;:]*\\s*$"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
                continue
            }
            let range = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, range: range) {
                let cleaned = (text as NSString).replacingCharacters(in: match.range, with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return (cleaned, snippet)
            }
        }

        return (text, nil)
    }

    // MARK: - Step 4: Snippet Expansion

    func expandSnippets(
        in text: String,
        snippets: [TextSnippet]
    ) -> (String, Set<UUID>) {
        guard !snippets.isEmpty else { return (text, []) }

        var result = text
        var expandedIDs = Set<UUID>()

        // Sort longest-trigger-first to prevent partial matches
        let sorted = snippets
            .filter { $0.isEnabled }
            .sorted { $0.trigger.count > $1.trigger.count }

        for snippet in sorted {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: snippet.trigger))\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
                continue
            }

            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            if !matches.isEmpty {
                expandedIDs.insert(snippet.id)
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: NSRegularExpression.escapedTemplate(for: snippet.expansion)
                )
            }
        }

        return (result, expandedIDs)
    }

    // MARK: - Step 5: Whitespace Cleanup

    func cleanWhitespace(in text: String, capitalizeFirst: Bool = true) -> String {
        var result = text

        // 5a: Collapse multiple spaces
        if let regex = try? NSRegularExpression(pattern: " {2,}") {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: " "
            )
        }

        // 5a2: Clean spaces around newlines, preserving newline count
        // "Hello, \n world" → "Hello,\nworld"
        // "Hello, \n\n world" → "Hello,\n\nworld" (paragraph break preserved)
        if let regex = try? NSRegularExpression(pattern: " *(\n+) *") {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1"
            )
        }

        // 5b: Remove space before punctuation (only horizontal space, preserve newlines)
        if let regex = try? NSRegularExpression(pattern: " +([.!?,;:])") {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1"
            )
        }

        // 5c: Trim
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        // 5d: Capitalize first letter (skipped for terminal profiles)
        if capitalizeFirst, let first = result.first, first.isLowercase {
            result = first.uppercased() + result.dropFirst()
        }

        return result
    }

    // MARK: - Step 2.5: Terminal Symbol Expansion

    private static let terminalSymbolMap: [(pattern: String, replacement: String)] = [
        ("backslash", "\\"),
        ("slash",     "/"),
        ("tilde",     "~"),
        ("underscore", "_"),
        ("dollar sign", "$"),
        ("dollar",    "$"),
        ("at sign",   "@"),
        ("at",        "@"),
        ("hash",      "#"),
        ("pound sign", "#"),
        ("pound",     "#"),
        ("asterisk",  "*"),
        ("star",      "*"),
        ("pipe",      "|"),
        ("ampersand", "&"),
        ("plus",      "+"),
        ("equals sign", "="),
        ("equals",    "="),
        ("colon",     ":"),
        ("semicolon", ";"),
        ("question mark", "?"),
        ("bang",      "!"),
        ("exclamation mark", "!"),
        ("exclamation", "!"),
        ("backtick",  "`"),
        ("open paren", "("),
        ("close paren", ")"),
        ("open bracket", "["),
        ("close bracket", "]"),
        ("open brace", "{"),
        ("close brace", "}"),
        ("less than", "<"),
        ("left angle", "<"),
        ("greater than", ">"),
        ("right angle", ">"),
        ("dash",      "-"),
        ("hyphen",    "-"),
        ("dot",       "."),
        ("period",    "."),
        ("percent",   "%"),
        ("caret",     "^"),
    ]

    func expandTerminalSymbols(in text: String) -> String {
        var result = text

        for (spoken, literal) in Self.terminalSymbolMap {
            let escaped = NSRegularExpression.escapedPattern(for: spoken)
            let pattern = "(?i)\\b\(escaped)\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let literalEscaped = NSRegularExpression.escapedTemplate(for: literal)
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: literalEscaped
            )
        }

        // Compact path-forming separators that sit between two word characters.
        // "foo / bar" → "foo/bar", "readme . md" → "readme.md", "50 % done" → "50%done"
        // Shell metacharacters (- * $ # | &) are left with their surrounding spaces
        // because they carry meaning as flag prefixes, globs, or redirects.
        let pathSeparators = #"[/\\._~@%]"#  // \\ = literal backslash in the char class
        let pathCompact = #"(\w) (\#(pathSeparators)) (\w)"#
        if let regex = try? NSRegularExpression(pattern: pathCompact) {
            var keepGoing = true
            while keepGoing {
                let before = result
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: "$1$2$3"
                )
                keepGoing = result != before
            }
        }

        // Tilde home-dir prefix: "~ / dev" → "~/dev"
        if let regex = try? NSRegularExpression(pattern: #"~\s+/\s*"#) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "~/"
            )
        }

        return result
    }
}
