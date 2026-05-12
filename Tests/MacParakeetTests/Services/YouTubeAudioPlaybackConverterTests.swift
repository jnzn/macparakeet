import XCTest
@testable import MacParakeetCore

final class YouTubeAudioPlaybackConverterTests: XCTestCase {

    // MARK: - needsConversion

    func testNeedsConversionFlagsWebM() {
        XCTAssertTrue(YouTubeAudioPlaybackConverter.needsConversion(forPath: "/tmp/a.webm"))
    }

    func testNeedsConversionFlagsOpus() {
        XCTAssertTrue(YouTubeAudioPlaybackConverter.needsConversion(forPath: "/tmp/a.opus"))
    }

    func testNeedsConversionFlagsOgg() {
        XCTAssertTrue(YouTubeAudioPlaybackConverter.needsConversion(forPath: "/tmp/a.ogg"))
    }

    func testNeedsConversionFlagsMkv() {
        XCTAssertTrue(YouTubeAudioPlaybackConverter.needsConversion(forPath: "/tmp/a.mkv"))
    }

    func testNeedsConversionIsCaseInsensitive() {
        XCTAssertTrue(YouTubeAudioPlaybackConverter.needsConversion(forPath: "/tmp/A.WEBM"))
    }

    func testNeedsConversionIgnoresM4A() {
        XCTAssertFalse(YouTubeAudioPlaybackConverter.needsConversion(forPath: "/tmp/a.m4a"))
    }

    func testNeedsConversionIgnoresMP3() {
        XCTAssertFalse(YouTubeAudioPlaybackConverter.needsConversion(forPath: "/tmp/a.mp3"))
    }

    func testNeedsConversionIgnoresWAV() {
        XCTAssertFalse(YouTubeAudioPlaybackConverter.needsConversion(forPath: "/tmp/a.wav"))
    }

    func testNeedsConversionIgnoresMP4() {
        // mp4 video container — AVFoundation reads its audio track natively.
        XCTAssertFalse(YouTubeAudioPlaybackConverter.needsConversion(forPath: "/tmp/a.mp4"))
    }

    func testNeedsConversionIgnoresExtensionlessFiles() {
        XCTAssertFalse(YouTubeAudioPlaybackConverter.needsConversion(forPath: "/tmp/audio"))
    }

    // MARK: - ffmpegArguments

    func testFFmpegArgumentsTranscodeToAACM4A() {
        let args = YouTubeAudioPlaybackConverter.ffmpegArguments(
            inputPath: "/tmp/source.webm",
            outputPath: "/tmp/source.m4a"
        )

        XCTAssertEqual(args, [
            "-nostdin",
            "-i", "/tmp/source.webm",
            "-vn",
            "-c:a", "aac",
            "-b:a", "192k",
            "-movflags", "+faststart",
            "-y",
            "/tmp/source.m4a",
        ])
    }

    // MARK: - convertToPlayableM4AIfNeeded passthrough

    func testConvertReturnsInputPathUnchangedForAlreadyPlayableFile() async throws {
        let converter = YouTubeAudioPlaybackConverter()
        // Use a path that doesn't need conversion. We don't even need the
        // file to exist — the function should short-circuit on extension.
        let path = "/tmp/anything.m4a"
        let result = try await converter.convertToPlayableM4AIfNeeded(inputPath: path)
        XCTAssertEqual(result, path)
    }

    func testConvertThrowsSourceMissingWhenFileDoesNotExist() async {
        let converter = YouTubeAudioPlaybackConverter()
        let bogus = "/tmp/macparakeet-nonexistent-\(UUID().uuidString).webm"

        do {
            _ = try await converter.convertToPlayableM4AIfNeeded(inputPath: bogus)
            XCTFail("Expected sourceMissing error")
        } catch let YouTubeAudioPlaybackConverterError.sourceMissing(path) {
            XCTAssertEqual(path, bogus)
        } catch {
            XCTFail("Expected sourceMissing, got \(error)")
        }
    }
}
