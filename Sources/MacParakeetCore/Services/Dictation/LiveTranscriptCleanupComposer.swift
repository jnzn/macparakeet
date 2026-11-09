import Foundation

/// Combines the latest AI-cleaned live preview with raw words spoken since
/// that cleanup. Display-only: the pasted text always comes from the final
/// recorded-file transcription.
public struct LiveTranscriptCleanupComposer: Sendable, Equatable {
    private var cleanedText: String?
    private var rawBaseline: String?

    public init() {}

    public mutating func record(cleaned: String, forRaw raw: String) {
        cleanedText = cleaned
        rawBaseline = raw
    }

    public mutating func reset() {
        cleanedText = nil
        rawBaseline = nil
    }

    public func compose(_ raw: String) -> String {
        guard let cleanedText, let rawBaseline else { return raw }
        let rawTrimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let baselineTrimmed = rawBaseline.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawTrimmed.hasPrefix(baselineTrimmed) {
            let tail = rawTrimmed.dropFirst(baselineTrimmed.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return tail.isEmpty ? cleanedText : cleanedText + " " + tail
        }
        // The recognizer revised earlier words, so fall back to a word count.
        let rawWords = rawTrimmed.split(whereSeparator: \.isWhitespace)
        let baselineWords = baselineTrimmed.split(whereSeparator: \.isWhitespace)
        guard rawWords.count > baselineWords.count else { return cleanedText }
        return cleanedText + " " + rawWords.dropFirst(baselineWords.count).joined(separator: " ")
    }
}
