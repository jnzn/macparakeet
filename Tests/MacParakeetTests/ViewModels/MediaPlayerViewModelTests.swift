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
}
