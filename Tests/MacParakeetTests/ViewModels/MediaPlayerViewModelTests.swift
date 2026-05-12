import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

final class MediaPlayerViewModelTests: XCTestCase {

    // MARK: - Playback Mode Detection

    func testDetectPlaybackModeForYouTube() {
        let t = Transcription(
            fileName: "YouTube Video",
            sourceURL: "https://www.youtube.com/watch?v=abc123"
        )
        XCTAssertEqual(MediaPlayerViewModel.detectPlaybackMode(for: t), .video)
    }

    func testDetectPlaybackModeForLocalVideo() throws {
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).mp4")
        try Data([0x00]).write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let t = Transcription(fileName: "video.mp4", filePath: tempFile.path)
        XCTAssertEqual(MediaPlayerViewModel.detectPlaybackMode(for: t), .video)
    }

    func testDetectPlaybackModeForLocalAudio() throws {
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).mp3")
        try Data([0x00]).write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let t = Transcription(fileName: "audio.mp3", filePath: tempFile.path)
        XCTAssertEqual(MediaPlayerViewModel.detectPlaybackMode(for: t), .audio)
    }

    func testDetectPlaybackModeForMissingFile() {
        let t = Transcription(fileName: "deleted.mp3", filePath: "/nonexistent/path/file.mp3")
        XCTAssertEqual(MediaPlayerViewModel.detectPlaybackMode(for: t), .none)
    }

    func testDetectPlaybackModeForNoPath() {
        let t = Transcription(fileName: "orphan.mp3")
        XCTAssertEqual(MediaPlayerViewModel.detectPlaybackMode(for: t), .none)
    }

    func testDetectPlaybackModeVideoExtensions() throws {
        let videoExts = ["mp4", "mov", "mkv", "avi", "webm", "m4v"]
        for ext in videoExts {
            let tempFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("test-\(UUID().uuidString).\(ext)")
            try Data([0x00]).write(to: tempFile)
            defer { try? FileManager.default.removeItem(at: tempFile) }

            let t = Transcription(fileName: "file.\(ext)", filePath: tempFile.path)
            XCTAssertEqual(
                MediaPlayerViewModel.detectPlaybackMode(for: t), .video,
                "Expected .video for .\(ext)"
            )
        }
    }

    func testDetectPlaybackModeAudioExtensions() throws {
        let audioExts = ["mp3", "wav", "m4a", "flac", "ogg", "aac"]
        for ext in audioExts {
            let tempFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("test-\(UUID().uuidString).\(ext)")
            try Data([0x00]).write(to: tempFile)
            defer { try? FileManager.default.removeItem(at: tempFile) }

            let t = Transcription(fileName: "file.\(ext)", filePath: tempFile.path)
            XCTAssertEqual(
                MediaPlayerViewModel.detectPlaybackMode(for: t), .audio,
                "Expected .audio for .\(ext)"
            )
        }
    }

    // MARK: - Initial State

    @MainActor
    func testInitialState() {
        let vm = MediaPlayerViewModel()
        XCTAssertNil(vm.player)
        XCTAssertFalse(vm.isPlaying)
        XCTAssertEqual(vm.currentTimeMs, 0)
        XCTAssertEqual(vm.durationMs, 0)
        XCTAssertEqual(vm.playerState, .idle)
        XCTAssertEqual(vm.playbackMode, .none)
    }

    @MainActor
    func testCleanupResetsState() {
        let vm = MediaPlayerViewModel()
        vm.currentTimeMs = 5000
        vm.durationMs = 60000
        vm.isPlaying = true
        vm.playerState = .ready
        vm.playbackMode = .video

        vm.cleanup()

        XCTAssertNil(vm.player)
        XCTAssertFalse(vm.isPlaying)
        XCTAssertEqual(vm.currentTimeMs, 0)
        XCTAssertEqual(vm.durationMs, 0)
        XCTAssertEqual(vm.playerState, .idle)
    }

    @MainActor
    func testLoadNoMediaSetsPlaybackModeNone() async {
        let vm = MediaPlayerViewModel()
        let t = Transcription(fileName: "orphan.mp3")
        await vm.load(for: t)
        XCTAssertEqual(vm.playbackMode, .none)
        XCTAssertEqual(vm.playerState, .idle)
    }

    // MARK: - Lazy webm → m4a migration (issue #237 playback fix)

    @MainActor
    func testPrepareSchedulesPlaybackConversionForExistingWebMFile() async throws {
        // Place a (zero-byte) webm next to where a converted m4a would land.
        // We don't need ffmpeg to actually succeed — we only assert that the
        // VM observed the unplayable extension and scheduled a conversion
        // via the injected converter (the persist callback proves it).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet-playback-mig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let webm = dir.appendingPathComponent("video.webm")
        try Data([0x00]).write(to: webm)

        let stubConverter = StubPlaybackConverter(
            transformedPath: dir.appendingPathComponent("video.m4a").path
        )

        let vm = MediaPlayerViewModel(playbackConverter: stubConverter)
        let persistExpectation = expectation(description: "persistConvertedFilePath called")
        var persistedID: UUID?
        var persistedPath: String?
        vm.onPlaybackFilePathConverted = { id, path in
            persistedID = id
            persistedPath = path
            persistExpectation.fulfill()
        }

        let transcription = Transcription(
            fileName: "Talk",
            filePath: webm.path,
            sourceURL: "https://www.youtube.com/watch?v=abc"
        )
        await vm.prepare(for: transcription)

        await fulfillment(of: [persistExpectation], timeout: 2.0)
        XCTAssertEqual(persistedID, transcription.id)
        XCTAssertEqual(persistedPath, dir.appendingPathComponent("video.m4a").path)
    }

    @MainActor
    func testPrepareSkipsConversionWhenNoCallbackWired() async throws {
        // Without `onPlaybackFilePathConverted`, the converter must NOT run
        // (we'd orphan the resulting .m4a since the DB still points at the
        // deleted .webm).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet-playback-mig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let webm = dir.appendingPathComponent("video.webm")
        try Data([0x00]).write(to: webm)

        let stubConverter = StubPlaybackConverter(
            transformedPath: dir.appendingPathComponent("video.m4a").path
        )

        let vm = MediaPlayerViewModel(playbackConverter: stubConverter)
        // No callback wired.

        let transcription = Transcription(
            fileName: "Talk",
            filePath: webm.path,
            sourceURL: "https://www.youtube.com/watch?v=abc"
        )
        await vm.prepare(for: transcription)

        // Give the @MainActor task a couple of runloop hops to settle.
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(stubConverter.invocationCount, 0, "Converter must not run when callback is absent")
    }

    @MainActor
    func testPrepareReportsLoadingStateUntilConversionSwapsThePlayer() async throws {
        // A webm-backed YouTube transcription must not present `.ready`
        // before the m4a player is loaded — that would expose a dead play
        // button with no visible indicator. We surface `.loading` and
        // flip to `.ready` only after `loadLocalFile` runs.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet-playback-loading-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let webm = dir.appendingPathComponent("video.webm")
        try Data([0x00]).write(to: webm)

        // A slow stub keeps the conversion task suspended so we can
        // observe the in-flight UI state without flakiness.
        let stubConverter = SuspendingStubPlaybackConverter()
        let vm = MediaPlayerViewModel(playbackConverter: stubConverter)
        vm.onPlaybackFilePathConverted = { _, _ in }

        let transcription = Transcription(
            fileName: "Talk",
            filePath: webm.path,
            sourceURL: "https://www.youtube.com/watch?v=abc"
        )
        await vm.prepare(for: transcription)

        XCTAssertEqual(vm.playerState, .loading,
                       "Player should be `.loading` while the lazy m4a transcode is in flight")

        vm.cleanup()
    }

    @MainActor
    func testPrepareCancelsPriorPlaybackConversionTaskOnRapidNavigation() async throws {
        // Switching to a different transcription while the first one's
        // m4a conversion is still in flight must cancel the prior task —
        // otherwise it can complete late and swap the AVPlayer to the old
        // file's audio while the user is viewing a different row.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet-playback-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let webm = dir.appendingPathComponent("video.webm")
        try Data([0x00]).write(to: webm)
        let plainAudio = dir.appendingPathComponent("audio.mp3")
        try Data([0x00]).write(to: plainAudio)

        let stubConverter = SuspendingStubPlaybackConverter()
        let vm = MediaPlayerViewModel(playbackConverter: stubConverter)
        var persistInvocations = 0
        vm.onPlaybackFilePathConverted = { _, _ in
            persistInvocations += 1
        }

        let webmTranscription = Transcription(
            fileName: "Webm Talk",
            filePath: webm.path,
            sourceURL: "https://www.youtube.com/watch?v=abc"
        )
        await vm.prepare(for: webmTranscription)
        XCTAssertEqual(vm.playerState, .loading)

        // Navigate to a different (already playable) transcription. The
        // suspending converter would otherwise sit forever; if cancellation
        // didn't propagate, the suspended task would block this test.
        let plainTranscription = Transcription(
            fileName: "Plain Audio",
            filePath: plainAudio.path
        )
        await vm.prepare(for: plainTranscription)

        // Give the cancelled task a runloop hop to settle.
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(persistInvocations, 0,
                       "Cancelled conversion must not invoke the persist callback")
    }
}

private final class StubPlaybackConverter: YouTubeAudioPlaybackConverting, @unchecked Sendable {
    private let transformedPath: String
    private(set) var invocationCount: Int = 0
    private let lock = NSLock()

    init(transformedPath: String) {
        self.transformedPath = transformedPath
    }

    func convertToPlayableM4AIfNeeded(inputPath: String) async throws -> String {
        lock.lock()
        invocationCount += 1
        lock.unlock()
        return transformedPath
    }
}

/// Test converter that suspends until cancelled. Used to observe
/// in-flight UI state and cancellation propagation without timing-sensitive
/// sleeps. `Task.sleep` throws `CancellationError` when the surrounding
/// task is cancelled, which propagates out as a converter failure.
private final class SuspendingStubPlaybackConverter: YouTubeAudioPlaybackConverting, @unchecked Sendable {
    func convertToPlayableM4AIfNeeded(inputPath: String) async throws -> String {
        try await Task.sleep(nanoseconds: UInt64.max)
        return inputPath
    }
}
