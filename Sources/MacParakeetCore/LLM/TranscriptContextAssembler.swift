import Foundation

public enum TranscriptContextAssembler {
    public static func assemble(
        transcript: String,
        maxCharacters: Int = 12_000
    ) -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxCharacters, maxCharacters > 64 else {
            return trimmed
        }

        // Keep both opening and ending context to preserve topic setup + latest details.
        let marker = "\n\n[...truncated...]\n\n"
        let budget = maxCharacters - marker.count
        let headCount = budget / 2
        let tailCount = budget - headCount
        let head = String(trimmed.prefix(headCount))
        let tail = String(trimmed.suffix(tailCount))
        return head + marker + tail
    }

    public static func chunk(
        transcript: String,
        chunkSize: Int = 3_000,
        overlap: Int = 300
    ) -> [String] {
        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, chunkSize > 0 else { return [] }

        let effectiveOverlap = min(max(overlap, 0), max(0, chunkSize - 1))
        let step = max(1, chunkSize - effectiveOverlap)
        let chars = Array(cleaned)

        var chunks: [String] = []
        var index = 0
        while index < chars.count {
            let end = min(chars.count, index + chunkSize)
            chunks.append(String(chars[index..<end]))
            if end == chars.count {
                break
            }
            index += step
        }

        return chunks
    }
}
