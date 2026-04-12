import Foundation

struct MeetingTranscriptFinalizer {
    private struct WordRun {
        let words: [WordTimestamp]

        var startMs: Int { words.first?.startMs ?? 0 }
        var endMs: Int { words.last?.endMs ?? 0 }
    }

    struct SourceTranscript: Sendable {
        let source: AudioSource
        let result: STTResult
        let startOffsetMs: Int
    }

    struct SystemDiarization: Sendable {
        let speakers: [SpeakerInfo]
        let segments: [SpeakerSegment]
    }

    struct FinalizedTranscript: Sendable {
        let rawTranscript: String
        let words: [WordTimestamp]
        let speakers: [SpeakerInfo]
        let diarizationSegments: [DiarizationSegmentRecord]
        let durationMs: Int?
    }

    private static let runGapThresholdMs = 1_500
    private static let echoLeadToleranceMs = 150
    private static let echoLagThresholdMs = 1_200
    private static let minimumEchoTokenMatches = 2
    private static let minimumEchoCoverage = 0.6

    static func finalize(
        sourceTranscripts: [SourceTranscript],
        systemDiarization: SystemDiarization? = nil
    ) -> FinalizedTranscript {
        let normalized = sourceTranscripts.sorted { lhs, rhs in
            if lhs.startOffsetMs == rhs.startOffsetMs {
                return sourceOrder(lhs.source) < sourceOrder(rhs.source)
            }
            return lhs.startOffsetMs < rhs.startOffsetMs
        }

        let shiftedWordsBySource = Dictionary(uniqueKeysWithValues: normalized.map { sourceTranscript in
            (
                sourceTranscript.source,
                shiftedWords(
                    for: sourceTranscript.result,
                    source: sourceTranscript.source,
                    offsetMs: sourceTranscript.startOffsetMs
                )
            )
        })

        let systemWords = shiftedWordsBySource[.system] ?? []
        let microphoneWords = suppressMicrophoneEchoDuplicates(
            microphoneWords: shiftedWordsBySource[.microphone] ?? [],
            systemWords: systemWords
        )
        let finalizedSystemWords: [WordTimestamp]
        if let systemDiarization {
            finalizedSystemWords = SpeakerMerger.mergeWordTimestampsWithSpeakers(
                words: systemWords,
                segments: systemDiarization.segments
            )
        } else {
            finalizedSystemWords = systemWords
        }

        var mergedWords = microphoneWords + finalizedSystemWords

        mergedWords.sort {
            if $0.startMs == $1.startMs {
                return sourceOrder(id: $0.speakerId) < sourceOrder(id: $1.speakerId)
            }
            return $0.startMs < $1.startMs
        }

        let speakers = activeSpeakers(from: mergedWords, systemDiarization: systemDiarization)
        let diarizationSegments = buildDiarizationSegments(from: mergedWords)
        let rawTranscript = finalTranscriptText(from: normalized, mergedWords: mergedWords)

        return FinalizedTranscript(
            rawTranscript: rawTranscript,
            words: mergedWords,
            speakers: speakers,
            diarizationSegments: diarizationSegments,
            durationMs: mergedWords.last?.endMs
        )
    }

    private static func shiftedWords(
        for result: STTResult,
        source: AudioSource,
        offsetMs: Int
    ) -> [WordTimestamp] {
        result.words.map {
            WordTimestamp(
                word: $0.word,
                startMs: $0.startMs + offsetMs,
                endMs: $0.endMs + offsetMs,
                confidence: $0.confidence,
                speakerId: source.rawValue
            )
        }
    }

    private static func activeSpeakers(
        from words: [WordTimestamp],
        systemDiarization: SystemDiarization?
    ) -> [SpeakerInfo] {
        let activeIDs = Set(words.compactMap(\.speakerId))
        var speakers: [SpeakerInfo] = []

        if activeIDs.contains(AudioSource.microphone.rawValue) {
            speakers.append(SpeakerInfo(id: AudioSource.microphone.rawValue, label: AudioSource.microphone.displayLabel))
        }

        if activeIDs.contains(AudioSource.system.rawValue) {
            speakers.append(SpeakerInfo(id: AudioSource.system.rawValue, label: AudioSource.system.displayLabel))
        }

        if let systemDiarization {
            for speaker in systemDiarization.speakers where activeIDs.contains(speaker.id) {
                speakers.append(speaker)
            }
        }

        return speakers
    }

    private static func buildDiarizationSegments(from words: [WordTimestamp]) -> [DiarizationSegmentRecord] {
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

    private static func finalTranscriptText(
        from sourceTranscripts: [SourceTranscript],
        mergedWords: [WordTimestamp]
    ) -> String {
        let nonEmptyTexts = sourceTranscripts
            .map(\.result.text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if nonEmptyTexts.count == 1 {
            return nonEmptyTexts[0]
        }

        if mergedWords.isEmpty {
            return nonEmptyTexts.joined(separator: "\n\n")
        }

        return transcriptText(from: mergedWords)
    }

    private static func transcriptText(from words: [WordTimestamp]) -> String {
        var parts: [String] = []
        parts.reserveCapacity(words.count)

        for word in words {
            let token = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }

            if parts.isEmpty || shouldAttachWithoutLeadingSpace(token) {
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

    private static func suppressMicrophoneEchoDuplicates(
        microphoneWords: [WordTimestamp],
        systemWords: [WordTimestamp]
    ) -> [WordTimestamp] {
        guard !microphoneWords.isEmpty, !systemWords.isEmpty else { return microphoneWords }

        let systemRuns = buildRuns(from: systemWords)
        let microphoneRuns = buildRuns(from: microphoneWords)

        return microphoneRuns
            .filter { run in
                !systemRuns.contains { systemRun in
                    shouldSuppressMicrophoneRun(run, against: systemRun)
                }
            }
            .flatMap(\.words)
    }

    private static func buildRuns(from words: [WordTimestamp]) -> [WordRun] {
        guard let firstWord = words.first else { return [] }

        var runs: [WordRun] = []
        var currentWords = [firstWord]

        for word in words.dropFirst() {
            if word.startMs - (currentWords.last?.endMs ?? word.startMs) <= runGapThresholdMs {
                currentWords.append(word)
            } else {
                runs.append(WordRun(words: currentWords))
                currentWords = [word]
            }
        }

        runs.append(WordRun(words: currentWords))
        return runs
    }

    private static func shouldSuppressMicrophoneRun(
        _ microphoneRun: WordRun,
        against systemRun: WordRun
    ) -> Bool {
        guard microphoneRun.startMs >= systemRun.startMs - echoLeadToleranceMs else { return false }
        guard microphoneRun.startMs <= systemRun.endMs + echoLagThresholdMs else { return false }
        guard microphoneRun.endMs <= systemRun.endMs + echoLagThresholdMs else { return false }

        let microphoneTokens = normalizedTokens(from: microphoneRun.words)
        let systemTokens = normalizedTokens(from: systemRun.words)
        guard microphoneTokens.count >= minimumEchoTokenMatches else { return false }

        let matchedTokenCount = multisetOverlap(lhs: microphoneTokens, rhs: systemTokens)
        guard matchedTokenCount >= minimumEchoTokenMatches else { return false }

        let coverage = Double(matchedTokenCount) / Double(max(microphoneTokens.count, systemTokens.count))
        return coverage >= minimumEchoCoverage
    }

    private static func normalizedTokens(from words: [WordTimestamp]) -> [String] {
        words
            .map(\.word)
            .map { token in
                token
                    .lowercased()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: .punctuationCharacters)
            }
            .filter { !$0.isEmpty }
    }

    private static func multisetOverlap(lhs: [String], rhs: [String]) -> Int {
        var rhsCounts: [String: Int] = [:]
        for token in rhs {
            rhsCounts[token, default: 0] += 1
        }

        var overlap = 0
        for token in lhs {
            guard let count = rhsCounts[token], count > 0 else { continue }
            overlap += 1
            rhsCounts[token] = count - 1
        }
        return overlap
    }

    private static func sourceOrder(_ source: AudioSource) -> Int {
        switch source {
        case .microphone:
            return 0
        case .system:
            return 1
        }
    }

    private static func sourceOrder(id: String?) -> Int {
        switch id {
        case AudioSource.microphone.rawValue:
            return 0
        case AudioSource.system.rawValue:
            return 1
        case let value? where value.hasPrefix("\(AudioSource.system.rawValue):"):
            return 2
        default:
            return 3
        }
    }
}
