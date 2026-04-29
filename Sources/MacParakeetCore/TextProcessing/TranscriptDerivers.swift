import Foundation

/// Pure-function deriver that produces a display-ready title string from a raw
/// transcript. The first substantive sentence (filler-stripped) becomes the row
/// title in the Meetings list. Falls back through several tiers so that even
/// short or filler-heavy transcripts get a usable title.
///
/// Deterministic and synchronous — runs on the transcription completion path
/// and persists into `Transcription.derivedTitle`.
public enum TitleDeriver {
    /// Maximum characters in a derived title. Tuned for two-line row layout
    /// (title doesn't wrap, snippet sits below it).
    public static let maxLength = 80

    /// Minimum character count for a sentence to be considered "substantive".
    /// Below this it's almost certainly a greeting or one-word reply.
    public static let minSubstantiveLength = 20

    public static func derive(from transcript: String?) -> String? {
        guard let raw = transcript?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }

        let sentences = TranscriptScanner.headSentences(raw, scanFraction: 0.10, minScan: 1500)

        if let pick = sentences.first(where: {
            $0.count >= minSubstantiveLength && $0.count <= maxLength
        }) {
            return clean(pick)
        }

        if let pick = sentences.first(where: { $0.count >= minSubstantiveLength }) {
            return clean(TranscriptScanner.truncate(pick, max: maxLength))
        }

        if let pick = sentences.first {
            return clean(pick)
        }

        return nil
    }

    private static func clean(_ raw: String) -> String {
        var result = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let trailing = CharacterSet(charactersIn: ".,;:!?-—…")
        while let last = result.unicodeScalars.last, trailing.contains(last) {
            result = String(result.unicodeScalars.dropLast())
        }
        guard let first = result.first else { return result }
        return first.uppercased() + result.dropFirst()
    }
}

/// Pure-function deriver that produces a display-ready snippet (preview line)
/// from a raw transcript. Picks a substantive sentence near the head of the
/// transcript, biased toward the [40, 140] character range that fits a single
/// row line cleanly.
///
/// Deterministic and synchronous — runs on the transcription completion path
/// and persists into `Transcription.derivedSnippet`.
public enum SnippetDeriver {
    public static let preferredMin = 40
    public static let preferredMax = 140

    public static func derive(from transcript: String?, excluding excludedTitle: String? = nil) -> String? {
        guard let raw = transcript?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }

        let normalizedExclude = excludedTitle.map(normalizeForCompare)
        let headSentences = TranscriptScanner.headSentences(raw, scanFraction: 0.10, minScan: 2000)
            .filter { !matchesExcluded($0, normalizedExclude: normalizedExclude) }

        let inRange = headSentences.filter { $0.count >= preferredMin && $0.count <= preferredMax }
        if let pick = inRange.max(by: { $0.count < $1.count }) {
            return pick
        }

        let widerSentences = TranscriptScanner.headSentences(raw, scanFraction: 0.30, minScan: 4000)
            .filter { !matchesExcluded($0, normalizedExclude: normalizedExclude) }
        if let pick = widerSentences.max(by: { $0.count < $1.count }), pick.count >= 30 {
            return TranscriptScanner.truncate(pick, max: preferredMax)
        }

        let head = String(raw.prefix(2000))
        return TranscriptScanner.truncate(head, max: 120)
    }

    private static func matchesExcluded(_ sentence: String, normalizedExclude: String?) -> Bool {
        guard let normalizedExclude, !normalizedExclude.isEmpty else { return false }
        return normalizeForCompare(sentence) == normalizedExclude
    }

    private static func normalizeForCompare(_ s: String) -> String {
        s.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
    }
}

// MARK: - Shared scanner

enum TranscriptScanner {
    static let leadingFillers: Set<String> = [
        "so", "yeah", "yep", "yes", "no", "okay", "ok", "and", "but",
        "um", "uh", "like", "well", "right", "sure", "alright",
        "anyway", "hey", "hi", "hello", "look", "listen"
    ]

    static func headSentences(_ text: String, scanFraction: Double, minScan: Int) -> [String] {
        let scanLength = max(minScan, Int(Double(text.count) * scanFraction))
        let head = String(text.prefix(min(scanLength, text.count)))
        return splitIntoSentences(head)
            .map(stripLeadingFillers)
            .filter { !$0.isEmpty }
    }

    static func splitIntoSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { substring, _, _, _ in
            let trimmed = substring?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                sentences.append(trimmed)
            }
        }
        return sentences
    }

    static func stripLeadingFillers(_ sentence: String) -> String {
        var words = sentence.split(whereSeparator: \.isWhitespace).map(String.init)
        let punctuation = CharacterSet.punctuationCharacters
        while let first = words.first {
            let normalized = first
                .lowercased()
                .unicodeScalars
                .filter { !punctuation.contains($0) }
                .reduce(into: "") { $0.append(Character($1)) }
            if leadingFillers.contains(normalized) {
                words.removeFirst()
            } else {
                break
            }
        }
        return words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func truncate(_ s: String, max: Int) -> String {
        guard s.count > max else { return s }
        let endIdx = s.index(s.startIndex, offsetBy: max)
        let prefix = s[..<endIdx]
        if let lastSpace = prefix.lastIndex(of: " ") {
            return String(prefix[..<lastSpace]) + "…"
        }
        return String(prefix) + "…"
    }
}
