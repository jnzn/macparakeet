import Foundation

struct MeetingTranscriptNoiseFilter {
    struct CleanupResult: Sendable, Equatable {
        let microphoneWords: [WordTimestamp]
        let removedMicrophoneWordCount: Int
    }

    private struct IndexedRun {
        let indexes: [Int]
        let words: [WordTimestamp]
    }

    private static let fillerTokens: Set<String> = [
        "ah",
        "eh",
        "er",
        "hm",
        "hmm",
        "mm",
        "mhm",
        "mmhmm",
        "uh",
        "uhh",
        "um",
        "umm",
    ]
    private static let runGapMs = 1_200
    private static let allowedTokenCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'"))

    static func cleanFinalMicrophoneWords(
        microphoneWords: [WordTimestamp],
        systemWords: [WordTimestamp]
    ) -> CleanupResult {
        guard !microphoneWords.isEmpty else {
            return CleanupResult(microphoneWords: [], removedMicrophoneWordCount: 0)
        }

        var indexesToDrop = Set<Int>()
        for run in contiguousRuns(in: microphoneWords) where isFillerOnly(run.words) {
            indexesToDrop.formUnion(run.indexes)
        }

        // Acoustic echo of the far-end leaks into the raw mic and is transcribed
        // a second time. The echo is degraded, so it diverges from the clean
        // system copy on a word or two — which the old exact-token-sequence
        // matcher could not see through (one divergent word saved the whole
        // run). Classify whole mic runs by how well they track an overlapping
        // far-end run instead.
        indexesToDrop.formUnion(
            MeetingMicrophoneEchoClassifier.echoIndices(
                microphoneWords: microphoneWords,
                systemWords: systemWords
            )
        )

        guard !indexesToDrop.isEmpty else {
            return CleanupResult(microphoneWords: microphoneWords, removedMicrophoneWordCount: 0)
        }

        let cleaned = microphoneWords.enumerated().compactMap { index, word in
            indexesToDrop.contains(index) ? nil : word
        }
        return CleanupResult(
            microphoneWords: cleaned,
            removedMicrophoneWordCount: indexesToDrop.count
        )
    }

    private static func contiguousRuns(in words: [WordTimestamp]) -> [IndexedRun] {
        guard let first = words.first else { return [] }

        var runs: [IndexedRun] = []
        var currentIndexes = [0]
        var currentWords = [first]
        var lastEndMs = first.endMs

        for (index, word) in words.enumerated().dropFirst() {
            if word.startMs - lastEndMs > runGapMs {
                runs.append(IndexedRun(indexes: currentIndexes, words: currentWords))
                currentIndexes = [index]
                currentWords = [word]
            } else {
                currentIndexes.append(index)
                currentWords.append(word)
            }
            lastEndMs = word.endMs
        }

        runs.append(IndexedRun(indexes: currentIndexes, words: currentWords))
        return runs
    }

    private static func isFillerOnly(_ words: [WordTimestamp]) -> Bool {
        let tokens = normalizedTokens(words)
        return !tokens.isEmpty && tokens.allSatisfy { fillerTokens.contains($0) }
    }

    private static func normalizedTokens(_ words: [WordTimestamp]) -> [String] {
        words.compactMap { normalizedToken($0.word) }
    }

    private static func normalizedToken(_ token: String) -> String? {
        let normalized = String(token.lowercased().unicodeScalars.filter { allowedTokenCharacters.contains($0) })
        return normalized.isEmpty ? nil : normalized
    }
}
