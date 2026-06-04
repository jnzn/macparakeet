import Foundation

/// Decides which microphone words in a dual-stream meeting transcript are
/// acoustic echoes of the far-end (system) audio and should be dropped.
///
/// The microphone always picks up the far-end playing through the speakers, so
/// the far-end gets transcribed twice: once cleanly from the system stream and
/// once — degraded — from the raw mic. Because the echo is lower-fidelity audio,
/// its transcription DIVERGES from the clean copy on a word here and there
/// ("team" → "Tim", "deploying" → "replying", "aggregates" → "advocates").
/// Matching whole runs or single words *exactly* therefore misses most echo, and
/// the far-end ends up doubled across the transcript ("Hey Hey Tim team good good
/// morning morning").
///
/// Instead we classify at the level of a contiguous microphone RUN: a run is
/// echo when most of its words line up — in time and in (fuzzy) content — with a
/// far-end word. A run that tracks the far-end is dropped in full, divergent
/// words included; a run that does not (the local speaker saying something
/// genuinely different) is kept in full. This is the "balanced" rule: clearly
/// distinct local speech survives, near-copies of the far-end do not.
///
/// The far-end (system) stream is the authoritative copy, so only microphone
/// words are ever dropped — never the clean system transcription.
enum MeetingMicrophoneEchoClassifier {
    /// Largest silent gap (ms) tolerated inside a single microphone run. Matches
    /// the saved-transcript noise filter so both layers segment runs identically.
    static let runGapMs = 1_200

    /// A microphone word's echo is transcribed within this many ms of its clean
    /// system source: the acoustic round-trip (~100–300 ms speaker→air→mic) plus
    /// per-stream chunk/STT timestamp jitter. Wide enough to pair an echo with
    /// its source, narrow enough that an unrelated far-end word elsewhere in the
    /// meeting does not count as a match.
    static let echoTimeWindowMs = 700

    /// Fraction of a run's words that must pair with the far-end for the run to
    /// count as echo. High enough that a short genuine reply sharing a word or
    /// two with the far-end ("the code" vs "the data") survives; low enough that
    /// a handful of ASR divergences inside a real echo run don't rescue it.
    static let coverageThreshold = 0.6

    /// Microphone-word indices that are acoustic echoes of `systemWords` and
    /// should be dropped. Indices are into the supplied `microphoneWords` array.
    static func echoIndices(
        microphoneWords: [WordTimestamp],
        systemWords: [WordTimestamp]
    ) -> Set<Int> {
        guard !microphoneWords.isEmpty, !systemWords.isEmpty else { return [] }

        let systemTokens = systemWords
            .compactMap { word -> TokenAt? in
                guard let token = normalizedToken(word.word) else { return nil }
                return TokenAt(token: token, startMs: word.startMs)
            }
            .sorted { $0.startMs < $1.startMs }
        guard !systemTokens.isEmpty else { return [] }

        var dropped = Set<Int>()

        // Primary: drop whole runs that track an overlapping far-end run, so the
        // handful of degraded-echo divergences inside the run ("team" → "Tim")
        // go with it instead of surviving as doubled words.
        for run in contiguousRuns(microphoneWords)
        where isEchoRun(run.words, systemTokens: systemTokens) {
            dropped.formUnion(run.indexes)
        }

        // Floor: also drop any single word that exactly echoes the far-end in
        // time. This catches one-word echoes that land inside an otherwise-local
        // run — the rapid back-and-forth tail of a call — and so never reach the
        // run-coverage bar. Exact-only here keeps it conservative: genuine local
        // speech is only dropped when it is verbatim the far-end's word.
        for (index, word) in microphoneWords.enumerated() where !dropped.contains(index) {
            guard let token = normalizedToken(word.word) else { continue }
            if hasFarEndMatch(token: token, startMs: word.startMs, systemTokens: systemTokens, requireExact: true) {
                dropped.insert(index)
            }
        }

        return dropped
    }

    // MARK: - Run classification

    private static func isEchoRun(_ run: [WordTimestamp], systemTokens: [TokenAt]) -> Bool {
        var considered = 0
        var matched = 0
        for word in run {
            guard let token = normalizedToken(word.word) else { continue }
            considered += 1
            if hasFarEndMatch(token: token, startMs: word.startMs, systemTokens: systemTokens) {
                matched += 1
            }
        }
        guard considered > 0 else { return false }
        return Double(matched) / Double(considered) >= coverageThreshold
    }

    /// True when some far-end token within the echo time window matches `token`
    /// exactly or as a degraded near-miss. `systemTokens` must be sorted by
    /// `startMs`; only the words inside the window are inspected, so cost is
    /// bounded by how many far-end words fall in ~1.4 s, not the whole meeting.
    private static func hasFarEndMatch(
        token: String,
        startMs: Int,
        systemTokens: [TokenAt],
        requireExact: Bool = false
    ) -> Bool {
        let upperBound = startMs + echoTimeWindowMs
        var index = firstIndexAtOrAfter(systemTokens, startMs: startMs - echoTimeWindowMs)
        while index < systemTokens.count, systemTokens[index].startMs <= upperBound {
            let candidate = systemTokens[index].token
            if requireExact ? (token == candidate) : tokensMatch(token, candidate) {
                return true
            }
            index += 1
        }
        return false
    }

    /// First index whose `startMs` is >= the target (binary search).
    private static func firstIndexAtOrAfter(_ tokens: [TokenAt], startMs target: Int) -> Int {
        var low = 0
        var high = tokens.count
        while low < high {
            let mid = low + (high - low) / 2
            if tokens[mid].startMs < target {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    // MARK: - Token matching

    /// The same normalized token, or a near-miss produced when degraded echo
    /// audio is transcribed slightly differently ("deploying" / "replying",
    /// "morning" / "mornin"). Fuzzy matching is reserved for tokens that are
    /// *both* five characters or longer: at four or fewer an edit-distance
    /// allowance collides between common words ("the"/"them", "what"/"that",
    /// "you"/"your") and would inflate coverage for genuine local speech. Short
    /// divergent echoes are instead recovered from their run's neighbours.
    /// Inputs are expected to be already normalized via ``normalizedToken``.
    static func tokensMatch(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        guard min(lhs.count, rhs.count) >= 5 else { return false }
        let budget = max(1, Int(0.3 * Double(max(lhs.count, rhs.count))))
        return levenshteinWithinBudget(Array(lhs), Array(rhs), budget: budget)
    }

    /// Levenshtein distance with early exit: returns whether `lhs` and `rhs` are
    /// within `budget` edits without computing the full distance when it can't be.
    private static func levenshteinWithinBudget(
        _ lhs: [Character],
        _ rhs: [Character],
        budget: Int
    ) -> Bool {
        if abs(lhs.count - rhs.count) > budget { return false }
        guard !lhs.isEmpty, !rhs.isEmpty else { return lhs.count + rhs.count <= budget }

        var previousRow = Array(0...rhs.count)
        var currentRow = [Int](repeating: 0, count: rhs.count + 1)
        for i in 1...lhs.count {
            currentRow[0] = i
            var rowMin = currentRow[0]
            for j in 1...rhs.count {
                let substitutionCost = lhs[i - 1] == rhs[j - 1] ? 0 : 1
                currentRow[j] = Swift.min(
                    previousRow[j] + 1,
                    currentRow[j - 1] + 1,
                    previousRow[j - 1] + substitutionCost
                )
                rowMin = Swift.min(rowMin, currentRow[j])
            }
            if rowMin > budget { return false }
            swap(&previousRow, &currentRow)
        }
        return previousRow[rhs.count] <= budget
    }

    // MARK: - Tokenization & run segmentation

    private static let allowedTokenScalars =
        CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'"))

    /// Lower-cased, punctuation-stripped form used to compare words across
    /// sources. Keeps Unicode letters/digits so non-Latin transcripts (Korean,
    /// Japanese, Chinese) still match.
    static func normalizedToken(_ raw: String) -> String? {
        let scalars = raw.lowercased().unicodeScalars.filter { allowedTokenScalars.contains($0) }
        let token = String(String.UnicodeScalarView(scalars))
        return token.isEmpty ? nil : token
    }

    private struct TokenAt {
        let token: String
        let startMs: Int
    }

    private struct IndexedRun {
        let indexes: [Int]
        let words: [WordTimestamp]
    }

    private static func contiguousRuns(_ words: [WordTimestamp]) -> [IndexedRun] {
        guard let first = words.first else { return [] }

        var runs: [IndexedRun] = []
        var indexes = [0]
        var current = [first]
        var lastEndMs = first.endMs

        for (index, word) in words.enumerated().dropFirst() {
            if word.startMs - lastEndMs > runGapMs {
                runs.append(IndexedRun(indexes: indexes, words: current))
                indexes = [index]
                current = [word]
            } else {
                indexes.append(index)
                current.append(word)
            }
            lastEndMs = word.endMs
        }

        runs.append(IndexedRun(indexes: indexes, words: current))
        return runs
    }
}
