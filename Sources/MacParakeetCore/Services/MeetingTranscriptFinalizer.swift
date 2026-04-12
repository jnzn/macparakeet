import Foundation

struct MeetingTranscriptFinalizer {
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

        var mergedWords: [WordTimestamp] = []
        mergedWords.reserveCapacity(normalized.reduce(0) { $0 + $1.result.words.count })

        for sourceTranscript in normalized {
            let sourceWords = shiftedWords(
                for: sourceTranscript.result,
                source: sourceTranscript.source,
                offsetMs: sourceTranscript.startOffsetMs
            )
            if sourceTranscript.source == .system, let systemDiarization {
                mergedWords.append(
                    contentsOf: SpeakerMerger.mergeWordTimestampsWithSpeakers(
                        words: sourceWords,
                        segments: systemDiarization.segments
                    )
                )
            } else {
                mergedWords.append(contentsOf: sourceWords)
            }
        }

        mergedWords.sort {
            if $0.startMs == $1.startMs {
                return sourceOrder(id: $0.speakerId) < sourceOrder(id: $1.speakerId)
            }
            return $0.startMs < $1.startMs
        }

        let speakers = activeSpeakers(from: mergedWords, systemDiarization: systemDiarization)
        let diarizationSegments = buildDiarizationSegments(from: mergedWords)
        let rawTranscript: String
        if mergedWords.isEmpty {
            rawTranscript = fallbackTranscriptText(from: normalized)
        } else {
            rawTranscript = transcriptText(from: mergedWords)
        }

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

        if let systemDiarization {
            for speaker in systemDiarization.speakers where activeIDs.contains(speaker.id) {
                speakers.append(speaker)
            }
        } else if activeIDs.contains(AudioSource.system.rawValue) {
            speakers.append(SpeakerInfo(id: AudioSource.system.rawValue, label: AudioSource.system.displayLabel))
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

    private static func fallbackTranscriptText(from sourceTranscripts: [SourceTranscript]) -> String {
        sourceTranscripts
            .map(\.result.text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private static func shouldAttachWithoutLeadingSpace(_ token: String) -> Bool {
        guard let first = token.first else { return false }
        return ",.!?;:%)]}".contains(first)
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
