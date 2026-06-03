import Foundation

public struct MeetingTranscriptUpdate: Sendable, Equatable {
    public let words: [WordTimestamp]
    public let speakers: [SpeakerInfo]
    /// `true` when live-preview chunks were recently dropped due to STT backpressure.
    /// The UI can use this to show a "transcription lagging" indicator.
    public let isTranscriptionLagging: Bool

    public init(words: [WordTimestamp], speakers: [SpeakerInfo], isTranscriptionLagging: Bool = false) {
        self.words = words
        self.speakers = speakers
        self.isTranscriptionLagging = isTranscriptionLagging
    }
}

public struct MeetingRealtimeTranscript: Sendable, Equatable {
    public let rawTranscript: String
    public let words: [WordTimestamp]
    public let speakerCount: Int
    public let speakers: [SpeakerInfo]
    public let diarizationSegments: [DiarizationSegmentRecord]
    public let durationMs: Int?

    public init(
        rawTranscript: String,
        words: [WordTimestamp],
        speakerCount: Int,
        speakers: [SpeakerInfo],
        diarizationSegments: [DiarizationSegmentRecord],
        durationMs: Int?
    ) {
        self.rawTranscript = rawTranscript
        self.words = words
        self.speakerCount = speakerCount
        self.speakers = speakers
        self.diarizationSegments = diarizationSegments
        self.durationMs = durationMs
    }
}

struct MeetingTranscriptAssembler {
    private static let orderedSources: [AudioSource] = [.microphone, .system]

    /// Time window (ms) for matching a microphone word to a system word when
    /// stripping acoustic echo. The far-end plays through the speakers and
    /// leaks into the raw (un-cancelled) mic a short, variable delay later, so
    /// the echo's transcribed timestamp sits close to — but slightly after —
    /// the clean system copy. Wide enough to absorb the acoustic round-trip and
    /// chunk-boundary jitter, narrow enough to spare genuine repeated words.
    private static let crossSourceEchoWindowMs = 500

    private var wordsBySource: [AudioSource: [WordTimestamp]] = [:]
    private var lastCommittedEndMs: [AudioSource: Int] = [:]

    mutating func reset() {
        wordsBySource = [:]
        lastCommittedEndMs = [:]
    }

    mutating func apply(
        result: STTResult,
        chunk: AudioChunker.AudioChunk,
        source: AudioSource
    ) -> MeetingTranscriptUpdate {
        let offsetWords = result.words.map {
            WordTimestamp(
                word: $0.word,
                startMs: $0.startMs + chunk.startMs,
                endMs: $0.endMs + chunk.startMs,
                confidence: $0.confidence,
                speakerId: source.rawValue
            )
        }

        let cutoff = lastCommittedEndMs[source] ?? Int.min
        let deduplicated = offsetWords.filter { $0.endMs > cutoff }

        if !deduplicated.isEmpty {
            wordsBySource[source, default: []].append(contentsOf: deduplicated)
            lastCommittedEndMs[source] = deduplicated.last?.endMs
        }

        return currentUpdate
    }

    var currentUpdate: MeetingTranscriptUpdate {
        let words = normalizedWords()
        return MeetingTranscriptUpdate(words: words, speakers: activeSpeakers(for: words))
    }

    func finalizedTranscript(durationMs: Int?) -> MeetingRealtimeTranscript? {
        let words = normalizedWords()
        guard !words.isEmpty else { return nil }

        let speakers = activeSpeakers(for: words)
        let diarizationSegments = buildDiarizationSegments(from: words)

        return MeetingRealtimeTranscript(
            rawTranscript: transcriptText(from: words),
            words: words,
            speakerCount: speakers.count,
            speakers: speakers,
            diarizationSegments: diarizationSegments,
            durationMs: durationMs ?? words.last?.endMs
        )
    }

    private func mergedWords() -> [WordTimestamp] {
        let merged = Self.orderedSources
            .flatMap { wordsBySource[$0] ?? [] }
            .sorted {
                if $0.startMs == $1.startMs {
                    return ($0.speakerId ?? "") < ($1.speakerId ?? "")
                }
                return $0.startMs < $1.startMs
            }
        return dropMicrophoneEchoes(from: merged)
    }

    /// Removes microphone words that are acoustic echoes of far-end (system)
    /// speech. With no/weak echo cancellation the far-end is transcribed from
    /// both the system stream (clean) and the raw mic (echo), then interleaved
    /// by timestamp into doubled output (e.g. "Hey Hey Jensen Jensen"). The
    /// system stream is the authoritative copy of the far-end, so when a mic
    /// word matches a nearby system word we keep the system one and drop the
    /// mic echo. Mic words with no matching system word (the local speaker) are
    /// always preserved.
    private func dropMicrophoneEchoes(from words: [WordTimestamp]) -> [WordTimestamp] {
        let systemStartsByToken = systemWordStartsByToken()
        guard !systemStartsByToken.isEmpty else { return words }

        return words.filter { word in
            guard word.speakerId == AudioSource.microphone.rawValue else { return true }
            let token = Self.normalizedToken(word.word)
            guard !token.isEmpty, let systemStarts = systemStartsByToken[token] else { return true }
            return !systemStarts.contains { abs($0 - word.startMs) <= Self.crossSourceEchoWindowMs }
        }
    }

    private func systemWordStartsByToken() -> [String: [Int]] {
        var result: [String: [Int]] = [:]
        for word in wordsBySource[.system] ?? [] {
            let token = Self.normalizedToken(word.word)
            guard !token.isEmpty else { continue }
            result[token, default: []].append(word.startMs)
        }
        return result
    }

    /// Lower-cased, edge-punctuation-stripped form used to match the "same"
    /// word across sources ("Jensen," and "jensen" match). Keeps Unicode
    /// letters/digits so non-Latin transcripts (Korean, Japanese, Chinese)
    /// still match.
    private static func normalizedToken(_ raw: String) -> String {
        raw.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    private func normalizedWords() -> [WordTimestamp] {
        let words = mergedWords()
        guard let originMs = words.map(\.startMs).min(), originMs != 0 else {
            return words
        }

        return words.map { word in
            WordTimestamp(
                word: word.word,
                startMs: word.startMs - originMs,
                endMs: word.endMs - originMs,
                confidence: word.confidence,
                speakerId: word.speakerId
            )
        }
    }

    private func activeSpeakers(for words: [WordTimestamp]) -> [SpeakerInfo] {
        let activeIDs = Set(words.compactMap(\.speakerId))
        return Self.orderedSources.compactMap { source in
            guard activeIDs.contains(source.rawValue) else { return nil }
            return SpeakerInfo(id: source.rawValue, label: source.displayLabel)
        }
    }

    private func buildDiarizationSegments(from words: [WordTimestamp]) -> [DiarizationSegmentRecord] {
        guard let firstWord = words.first, let firstSpeaker = firstWord.speakerId else {
            return []
        }

        var segments: [DiarizationSegmentRecord] = []
        var currentSpeaker = firstSpeaker
        var currentStart = firstWord.startMs
        var currentEnd = firstWord.endMs

        for word in words.dropFirst() {
            guard let speakerId = word.speakerId else { continue }

            if speakerId == currentSpeaker, word.startMs - currentEnd <= 1500 {
                currentEnd = max(currentEnd, word.endMs)
            } else {
                segments.append(DiarizationSegmentRecord(
                    speakerId: currentSpeaker,
                    startMs: currentStart,
                    endMs: currentEnd
                ))
                currentSpeaker = speakerId
                currentStart = word.startMs
                currentEnd = word.endMs
            }
        }

        segments.append(DiarizationSegmentRecord(
            speakerId: currentSpeaker,
            startMs: currentStart,
            endMs: currentEnd
        ))
        return segments
    }

    private func transcriptText(from words: [WordTimestamp]) -> String {
        var parts: [String] = []
        parts.reserveCapacity(words.count)

        for word in words {
            let token = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }

            if parts.isEmpty || Self.shouldAttachWithoutLeadingSpace(token) {
                parts.append(token)
            } else {
                parts.append(" \(token)")
            }
        }

        return parts.joined()
    }

    private static func shouldAttachWithoutLeadingSpace(_ token: String) -> Bool {
        guard let first = token.first else { return false }
        return ",.!?;:%)]}".contains(first)
    }
}
