import Foundation

/// Unambiguous spoken symbol words → symbols. "hashtag"/"pound sign" prefix
/// the next word; "hyphen" joins its neighbors; the rest stand alone.
/// Ambiguous words (dash, plus, pipe, slash, equals) are deliberately NOT
/// here — users opt into those via Custom Words.
public enum SymbolNormalizer {
    public static func normalize(_ text: String) -> String {
        var result = text
        // Prefix symbols: attach to the following word.
        result = NormalizerRegex.replace(result, pattern: #"\b(?:hashtag|pound sign) (\w+)"#) { g in "#\(g[1])" }
        // Hyphen joins adjacent words: "self hyphen aware" → "self-aware"
        result = NormalizerRegex.replace(result, pattern: #"(\w+) hyphen (\w+)"#) { g in "\(g[1])-\(g[2])" }
        // Two-word standalone symbols.
        let twoWord: [(String, String)] = [
            ("at sign", "@"), ("pound sign", "#"), ("dollar sign", "$"), ("percent sign", "%"),
        ]
        for (spoken, symbol) in twoWord {
            result = result.replacingOccurrences(of: spoken, with: symbol)
        }
        // One-word unambiguous symbols.
        let oneWord: [(String, String)] = [
            ("hashtag", "#"), ("ampersand", "&"), ("asterisk", "*"),
            ("underscore", "_"), ("tilde", "~"), ("backslash", "\\"),
        ]
        for (spoken, symbol) in oneWord {
            result = NormalizerRegex.replace(result, pattern: "\\b\(spoken)\\b") { _ in symbol }
        }
        return result
    }
}
