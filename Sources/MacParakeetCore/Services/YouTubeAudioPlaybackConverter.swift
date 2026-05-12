import Foundation
import os

/// Errors specific to playback-conversion. Conversion failures are
/// non-fatal at the transcription-pipeline level — they just mean the
/// saved audio file stays in its original format and the in-app scrubber
/// will be inert for that file (the user can still use Show Video, which
/// re-extracts a streamable URL via yt-dlp).
public enum YouTubeAudioPlaybackConverterError: Error, Sendable {
    case ffmpegUnavailable(String)
    case conversionFailed(String)
    case sourceMissing(String)
}

public protocol YouTubeAudioPlaybackConverting: Sendable {
    /// Convert `inputPath` to an AVPlayer-compatible `.m4a` if needed.
    /// Returns the path of the playable file. If the input is already
    /// playable, returns the input path unchanged.
    func convertToPlayableM4AIfNeeded(inputPath: String) async throws -> String
}

/// Transcodes yt-dlp downloads that AVPlayer can't decode (WebM/Opus/Ogg)
/// into a `.m4a` AAC file for the in-app audio scrubber. Built so we can
/// keep using yt-dlp's higher-bitrate Opus stream for transcription (which
/// measurably improves Parakeet accuracy — see issue #237) without
/// stranding the saved audio in a container macOS can't play.
public final class YouTubeAudioPlaybackConverter: YouTubeAudioPlaybackConverting, Sendable {
    public init() {}

    /// Extensions yt-dlp produces that AVPlayer on macOS cannot decode.
    /// AVFoundation has no native WebM container demuxer and no native
    /// Opus/Vorbis decoder; the resulting `AVPlayer` is silent at play()
    /// with no surfaced error. See memory: reference_avplayer_codec_limits.
    public static let unplayableExtensions: Set<String> = [
        "webm", "opus", "ogg", "mkv"
    ]

    /// Cheap pre-check so callers can avoid spinning up an ffmpeg process
    /// for files that are already playable.
    public static func needsConversion(forPath path: String) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return unplayableExtensions.contains(ext)
    }

    private let logger = Logger(subsystem: "com.macparakeet", category: "PlaybackConverter")

    public func convertToPlayableM4AIfNeeded(inputPath: String) async throws -> String {
        guard Self.needsConversion(forPath: inputPath) else {
            return inputPath
        }

        let inputURL = URL(fileURLWithPath: inputPath)
        guard FileManager.default.fileExists(atPath: inputPath) else {
            throw YouTubeAudioPlaybackConverterError.sourceMissing(inputPath)
        }

        // Write next to the source so storage retention rules (clear cache,
        // Settings > Downloaded YouTube audio) keep applying without any
        // path-rewriting elsewhere in the app.
        let outputURL = inputURL
            .deletingPathExtension()
            .appendingPathExtension("m4a")

        let ffmpegPath = try findFFmpeg()

        // ffmpeg arguments: AAC 192k mono/stereo (passthrough channel
        // layout), faststart for streaming-friendly seeks, no video. 192k
        // is well above the WAV downsample floor Parakeet sees, so any
        // re-transcribe from this m4a stays within accuracy noise. We
        // explicitly drop video tracks (`-vn`) because yt-dlp's webm may
        // still contain a thumbnail image stream that AAC encoders won't
        // accept.
        try await runFFmpeg(
            ffmpegPath: ffmpegPath,
            inputURL: inputURL,
            outputURL: outputURL
        )

        // Source is no longer needed for playback; remove it so retention
        // accounting matches reality. If the user disabled
        // `saveTranscriptionAudio`, this is moot because the caller never
        // invokes us; we run only when keepDownloadedAudio is true.
        do {
            try FileManager.default.removeItem(at: inputURL)
        } catch {
            // Log but don't fail — the m4a is already on disk and that's
            // the contract the caller cares about.
            logger.warning("Failed to remove source webm at \(inputPath, privacy: .private): \(error.localizedDescription, privacy: .public)")
        }

        return outputURL.path
    }

    /// Build the ffmpeg argument vector. Exposed for testing.
    public static func ffmpegArguments(inputPath: String, outputPath: String) -> [String] {
        [
            "-nostdin",
            "-i", inputPath,
            "-vn",
            "-c:a", "aac",
            "-b:a", "192k",
            "-movflags", "+faststart",
            "-y",
            outputPath
        ]
    }

    // MARK: - Private

    private func findFFmpeg() throws -> String {
        do {
            return try BinaryBootstrap.requireRuntimeFFmpegPath()
        } catch {
            throw YouTubeAudioPlaybackConverterError.ffmpegUnavailable(
                "FFmpeg is unavailable for this runtime."
            )
        }
    }

    private func runFFmpeg(
        ffmpegPath: String,
        inputURL: URL,
        outputURL: URL
    ) async throws {
        var succeeded = false
        defer {
            if !succeeded {
                try? FileManager.default.removeItem(at: outputURL)
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = Self.ffmpegArguments(
            inputPath: inputURL.path,
            outputPath: outputURL.path
        )

        // Mirror AudioFileConverter's stderr handling — ffmpeg's verbose
        // progress can fill the 64KB pipe buffer and deadlock both ends.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet", isDirectory: true)
        if !FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        }
        let stderrURL = tempDir
            .appendingPathComponent("ffmpeg-playback-stderr-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: stderrURL) }
        FileManager.default.createFile(atPath: stderrURL.path, contents: Data())
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer { stderrHandle.closeFile() }

        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrHandle

        try process.run()
        try await ChildProcessWaiter.waitUntilExit(
            process,
            timeout: 600,
            timeoutError: YouTubeAudioPlaybackConverterError.conversionFailed(
                "FFmpeg playback conversion timed out"
            )
        )

        if process.terminationStatus != 0 {
            stderrHandle.synchronizeFile()
            let stderrStr = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? "Unknown error"
            throw YouTubeAudioPlaybackConverterError.conversionFailed(
                Self.tailForError(stderrStr)
            )
        }

        succeeded = true
    }

    /// ffmpeg's startup banner is long; surface only the final lines where
    /// the actual error lives. Matches AudioFileConverter's behavior so
    /// telemetry stays consistent if/when we add it.
    private static func tailForError(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = 384
        guard trimmed.count > limit else { return trimmed }
        let start = trimmed.index(trimmed.endIndex, offsetBy: -limit)
        return "...\(trimmed[start...])"
    }
}
