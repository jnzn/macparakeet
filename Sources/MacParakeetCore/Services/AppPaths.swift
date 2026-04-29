import Foundation

/// Centralized path management for MacParakeet runtime files.
public enum AppPaths {
    /// Application Support directory
    public static var appSupportDir: String {
        let path = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .path
            ?? (NSHomeDirectory() + "/Library/Application Support")
        return path + "/MacParakeet"
    }

    /// Database file path
    public static var databasePath: String {
        "\(appSupportDir)/macparakeet.db"
    }

    /// Audio storage directory for dictations
    public static var dictationsDir: String {
        "\(appSupportDir)/dictations"
    }

    /// Audio storage directory for downloaded YouTube transcription audio
    public static var youtubeDownloadsDir: String {
        "\(appSupportDir)/youtube-downloads"
    }

    /// Audio storage directory for meeting recordings
    public static var meetingRecordingsDir: String {
        "\(appSupportDir)/meeting-recordings"
    }

    /// Directory for managed helper binaries (e.g. yt-dlp).
    public static var binDir: String {
        "\(appSupportDir)/bin"
    }

    /// WhisperKit CoreML model cache base.
    public static var whisperModelsDir: String {
        "\(appSupportDir)/models/stt/whisper"
    }

    /// Managed yt-dlp binary path.
    public static var ytDlpBinaryPath: String {
        "\(binDir)/yt-dlp"
    }

    /// Resolve bundled yt-dlp seed binary from app resources.
    /// Returns nil when running outside an app bundle or when yt-dlp is not present.
    public static func bundledYtDlpPath() -> String? {
        guard let resourcePath = Bundle.main.resourcePath else { return nil }
        let ytDlpPath = (resourcePath as NSString).appendingPathComponent("yt-dlp")
        return FileManager.default.isExecutableFile(atPath: ytDlpPath) ? ytDlpPath : nil
    }

    /// Cached discover feed
    public static var discoverCachePath: String {
        "\(appSupportDir)/discover-cache.json"
    }

    /// Thumbnail cache directory
    public static var thumbnailsDir: String {
        "\(appSupportDir)/thumbnails"
    }

    /// Temp directory for audio processing
    public static var tempDir: String {
        "\(NSTemporaryDirectory())macparakeet"
    }

    /// Ensure all required directories exist
    public static func ensureDirectories() throws {
        let fm = FileManager.default
        for dir in [appSupportDir, dictationsDir, youtubeDownloadsDir, meetingRecordingsDir, binDir, whisperModelsDir, thumbnailsDir, tempDir] {
            if !fm.fileExists(atPath: dir) {
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
        }
    }

    /// Delete stale temp WAVs from prior sessions that outlived the
    /// processCapturedAudio defer cleanup (crash, SIGKILL, or suspended
    /// cancel window). Anything older than `maxAge` is assumed orphaned.
    /// macOS purges TMPDIR on reboot but not on app restart, so transcripts
    /// from crashed sessions can linger for days otherwise.
    /// Best-effort: failures are silently ignored.
    public static func cleanStaleTempAudio(olderThan maxAge: TimeInterval = 3600) {
        let fm = FileManager.default
        let dir = tempDir
        guard let contents = try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: dir, isDirectory: true),
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-maxAge)
        for fileURL in contents {
            guard fileURL.pathExtension.lowercased() == "wav" else { continue }
            guard let modDate = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modDate < cutoff
            else { continue }
            try? fm.removeItem(at: fileURL)
        }
    }

    /// Resolve bundled FFmpeg binary path from app resources.
    /// Returns nil when running outside an app bundle or when ffmpeg is not present.
    public static func bundledFFmpegPath() -> String? {
        guard let resourcePath = Bundle.main.resourcePath else { return nil }
        let ffmpegPath = (resourcePath as NSString).appendingPathComponent("ffmpeg")
        return FileManager.default.isExecutableFile(atPath: ffmpegPath) ? ffmpegPath : nil
    }
}
