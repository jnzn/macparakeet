import Foundation

/// Merges word-level timestamps with speaker diarization segments.
/// Both inputs must be sorted by start time. Uses a two-pointer O(W+S) algorithm.
public enum SpeakerMerger {

    /// Assign a speakerId to each word based on which diarization segment has the most time overlap.
    /// Tie-breaking: earlier segment wins. No overlap → speakerId = nil.
    public static func mergeWordTimestampsWithSpeakers(
        words: [WordTimestamp],
        segments: [SpeakerSegment]
    ) -> [WordTimestamp] {
        guard !words.isEmpty, !segments.isEmpty else { return words }

        var result = words
        var segIdx = 0

        for (wordIdx, word) in words.enumerated() {
            // Advance segment pointer past segments that end before this word starts
            while segIdx > 0 && segments[segIdx - 1].endMs > word.startMs {
                // Don't advance past — we may need earlier segments for overlap
                break
            }

            var bestSpeaker: String? = nil
            var bestOverlap = 0

            // Check segments starting from where they could overlap with this word
            var s = segIdx
            // Rewind to find first possible overlapping segment
            while s > 0 && segments[s - 1].endMs > word.startMs {
                s -= 1
            }

            while s < segments.count {
                let seg = segments[s]
                if seg.startMs >= word.endMs {
                    break // No more segments can overlap
                }

                let overlapStart = max(word.startMs, seg.startMs)
                let overlapEnd = min(word.endMs, seg.endMs)
                let overlap = overlapEnd - overlapStart

                if overlap > bestOverlap {
                    bestOverlap = overlap
                    bestSpeaker = seg.speakerId
                }
                // Tie-breaking: earlier segment wins (first match with same overlap kept)

                s += 1
            }

            if bestOverlap > 0 {
                result[wordIdx].speakerId = bestSpeaker
            }

            // Advance segIdx for efficiency: skip segments that can't overlap future words
            while segIdx < segments.count && segments[segIdx].endMs <= word.startMs {
                segIdx += 1
            }
        }

        return result
    }
}
