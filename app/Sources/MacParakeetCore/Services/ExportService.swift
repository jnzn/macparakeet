import Foundation

public protocol ExportServiceProtocol: Sendable {
    func exportToTxt(transcription: Transcription, url: URL) throws
    func formatForClipboard(transcription: Transcription) -> String
}

/// Handles exporting transcriptions to files and clipboard.
public final class ExportService: ExportServiceProtocol, Sendable {
    public init() {}

    /// Export transcription as plain text file
    public func exportToTxt(transcription: Transcription, url: URL) throws {
        let content = formatPlainText(transcription: transcription)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Format transcription text for clipboard copy
    public func formatForClipboard(transcription: Transcription) -> String {
        transcription.rawTranscript ?? transcription.cleanTranscript ?? ""
    }

    // MARK: - Private

    private func formatPlainText(transcription: Transcription) -> String {
        var lines: [String] = []

        // Header
        lines.append(transcription.fileName)
        if let durationMs = transcription.durationMs {
            let duration = formatDuration(ms: durationMs)
            lines.append("Duration: \(duration)")
        }
        lines.append("")

        // Transcript
        if let text = transcription.rawTranscript ?? transcription.cleanTranscript {
            lines.append(text)
        }

        return lines.joined(separator: "\n")
    }

    private func formatDuration(ms: Int) -> String {
        let totalSeconds = ms / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
}
