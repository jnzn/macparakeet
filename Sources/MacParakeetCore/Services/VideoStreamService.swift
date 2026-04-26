import Darwin
import Foundation
import os

public final class VideoStreamService: Sendable {
    private let logger = Logger(subsystem: "com.macparakeet", category: "VideoStream")

    /// Shared cache across all instances — survives view recreation
    private static let cache = OSAllocatedUnfairLock(initialState: [String: CachedURL]())

    private struct CachedURL: Sendable {
        let url: URL
        let expiresAt: Date
    }

    /// TTL for cached stream URLs (YouTube URLs typically expire after ~2-6 hours)
    private static let cacheTTL: TimeInterval = 2 * 60 * 60

    /// Timeout for the entire yt-dlp extraction (pipe reads + termination)
    private static let extractionTimeout: TimeInterval = 30

    public init() {}

    /// Extract a streaming URL for a YouTube video. Caches per video ID.
    public func streamURL(for youtubeURL: String) async throws -> URL {
        let videoID = YouTubeURLValidator.extractVideoID(youtubeURL) ?? youtubeURL

        // Check cache
        if let cached = Self.cache.withLock({ $0[videoID] }),
           cached.expiresAt > Date() {
            logger.notice("🎯 Cache HIT for \(videoID) (expires in \(Int(cached.expiresAt.timeIntervalSinceNow))s)")
            return cached.url
        }
        logger.notice("❌ Cache MISS for \(videoID), extracting via yt-dlp")

        let url = try await extractStreamURL(youtubeURL: youtubeURL)

        Self.cache.withLock {
            $0[videoID] = CachedURL(url: url, expiresAt: Date().addingTimeInterval(Self.cacheTTL))
        }
        logger.notice("✅ Cached stream URL for \(videoID) (TTL: \(Int(Self.cacheTTL))s)")

        return url
    }

    /// Invalidate cached URL for a video (e.g., after playback error).
    public func invalidateCache(for youtubeURL: String) {
        let videoID = YouTubeURLValidator.extractVideoID(youtubeURL) ?? youtubeURL
        _ = Self.cache.withLock { $0.removeValue(forKey: videoID) }
        logger.notice("🗑 Invalidated cache for \(videoID)")
    }

    // MARK: - Private

    private func extractStreamURL(youtubeURL: String) async throws -> URL {
        let ytDlpPath = try resolveYtDlpPath()
        logger.notice("▶️ Starting yt-dlp extraction for \(youtubeURL)")
        logger.notice("  yt-dlp path: \(ytDlpPath)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ytDlpPath)
        process.arguments = [
            "-f", "b",
            "--get-url",
            "--no-playlist",
            "--", youtubeURL,
        ]

        var env = ProcessInfo.processInfo.environment
        let current = env["PATH"] ?? "/usr/bin:/bin"
        let extras = [AppPaths.binDir, "/opt/homebrew/bin", "/usr/local/bin"]
        let existing = Set(current.split(separator: ":").map(String.init))
        let missing = extras.filter { !existing.contains($0) }
        env["PATH"] = (missing + [current]).joined(separator: ":")
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let startTime = ContinuousClock.now

        try process.run()
        logger.notice("  yt-dlp process launched (PID: \(process.processIdentifier))")

        // Wrap EVERYTHING in a single timeout — process termination + pipe drain.
        // The pipes are read AFTER the process terminates (or is killed) rather
        // than concurrently on a DispatchQueue. That avoids the previous bug
        // where the dispatched `readDataToEndOfFile` blocked on a global queue
        // thread that TaskGroup cancellation could not interrupt; if yt-dlp
        // hung, the read leaked the thread and never resumed.
        //
        // For `yt-dlp --get-url` the output is one URL line (well under the 64K
        // pipe buffer), so reading after termination cannot deadlock. If we ever
        // wrap a yt-dlp invocation that produces large output, switch to
        // incremental drain via `FileHandle.bytes`.
        let result: (stdout: Data, stderr: Data) = try await withThrowingTaskGroup(of: ProcessOutcome.self) { group in
            defer {
                group.cancelAll()
                if process.isRunning {
                    process.terminate()
                    // SIGKILL fallback if SIGTERM doesn't take. Holding `process`
                    // strongly via the closure keeps it alive until the dispatch
                    // fires, even if every other reference has been released.
                    let stuckProcess = process
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                        guard stuckProcess.isRunning else { return }
                        kill(stuckProcess.processIdentifier, SIGKILL)
                    }
                }
            }

            group.addTask {
                // Wait for process to exit (terminationHandler fires when SIGTERM
                // or natural exit completes), then drain pipes synchronously —
                // they're at EOF, so the reads return immediately.
                await Self.awaitProcessTermination(process)
                let stdoutData = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
                let stderrData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
                return .completed(stdout: stdoutData, stderr: stderrData)
            }

            group.addTask {
                try await Task.sleep(for: .seconds(Self.extractionTimeout))
                throw VideoStreamError.extractionFailed(
                    "Stream extraction timed out after \(Int(Self.extractionTimeout))s"
                )
            }

            // First task to complete wins — either extraction finishes or timeout fires.
            // The timeout task throws; the completion task returns `.completed`.
            let outcome = try await group.next()!
            guard case .completed(let stdout, let stderr) = outcome else {
                // Unreachable — only the completion task returns a value, and it
                // always returns `.completed`. The timeout task throws.
                throw VideoStreamError.extractionFailed("Internal error: unexpected outcome")
            }
            return (stdout: stdout, stderr: stderr)
        }

        let elapsed = ContinuousClock.now - startTime
        logger.notice("  yt-dlp finished in \(elapsed) (exit: \(process.terminationStatus))")

        let stdout = String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: result.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !stderr.isEmpty {
            logger.notice("  yt-dlp stderr: \(stderr)")
        }

        guard process.terminationStatus == 0, !stdout.isEmpty else {
            logger.error("❌ yt-dlp extraction failed: \(stderr)")
            throw VideoStreamError.extractionFailed(stderr.isEmpty ? "No output from yt-dlp" : stderr)
        }

        // yt-dlp may return multiple URLs (video + audio); take the first
        let urlString = stdout.components(separatedBy: .newlines).first ?? stdout
        guard let url = URL(string: urlString) else {
            logger.error("❌ Invalid stream URL: \(urlString.prefix(100))")
            throw VideoStreamError.invalidStreamURL
        }

        logger.notice("✅ Extracted stream URL for \(youtubeURL) in \(elapsed)")
        return url
    }

    private enum ProcessOutcome: Sendable {
        case completed(stdout: Data, stderr: Data)
    }

    /// Resume-once wrapper around `Process.terminationHandler`. Resumes
    /// immediately if the process has already exited by the time the handler
    /// is wired, and never double-resumes if the handler fires concurrently.
    private static func awaitProcessTermination(_ process: Process) async {
        let resumed = OSAllocatedUnfairLock(initialState: false)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in
                let already = resumed.withLock { flag -> Bool in
                    let was = flag; flag = true; return was
                }
                if !already { continuation.resume() }
            }
            if !process.isRunning {
                let already = resumed.withLock { flag -> Bool in
                    let was = flag; flag = true; return was
                }
                if !already {
                    process.terminationHandler = nil
                    continuation.resume()
                }
            }
        }
    }

    private func resolveYtDlpPath() throws -> String {
        let candidates = [
            AppPaths.ytDlpBinaryPath,
            "/opt/homebrew/bin/yt-dlp",
            "/usr/local/bin/yt-dlp",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        throw VideoStreamError.ytDlpNotFound
    }
}

public enum VideoStreamError: Error, LocalizedError {
    case ytDlpNotFound
    case extractionFailed(String)
    case invalidStreamURL

    public var errorDescription: String? {
        switch self {
        case .ytDlpNotFound:
            return "yt-dlp not found for video streaming"
        case .extractionFailed(let reason):
            return "Failed to extract stream URL: \(reason)"
        case .invalidStreamURL:
            return "Extracted URL is not valid"
        }
    }
}
