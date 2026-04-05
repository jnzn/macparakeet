import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

final class TranscriptionDeletionCleanupTests: XCTestCase {
    override func setUpWithError() throws {
        try AppPaths.ensureDirectories()
    }

    func testMeetingDeletionRemovesSessionFolder() throws {
        let folderURL = URL(fileURLWithPath: AppPaths.meetingRecordingsDir, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let mixedURL = folderURL.appendingPathComponent("meeting.m4a")
        let micURL = folderURL.appendingPathComponent("microphone.m4a")
        FileManager.default.createFile(atPath: mixedURL.path, contents: Data("mix".utf8))
        FileManager.default.createFile(atPath: micURL.path, contents: Data("mic".utf8))

        let transcription = Transcription(
            fileName: "Meeting.m4a",
            filePath: mixedURL.path,
            status: .completed,
            sourceType: .meeting
        )

        TranscriptionDeletionCleanup.removeOwnedAssets(for: transcription)

        XCTAssertFalse(FileManager.default.fileExists(atPath: folderURL.path))
    }

    func testMeetingDeletionOutsideAppSupportIsIgnored() throws {
        let folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let mixedURL = folderURL.appendingPathComponent("meeting.m4a")
        FileManager.default.createFile(atPath: mixedURL.path, contents: Data("mix".utf8))

        let transcription = Transcription(
            fileName: "Meeting.m4a",
            filePath: mixedURL.path,
            status: .completed,
            sourceType: .meeting
        )

        TranscriptionDeletionCleanup.removeOwnedAssets(for: transcription)

        XCTAssertTrue(FileManager.default.fileExists(atPath: folderURL.path))
        try? FileManager.default.removeItem(at: folderURL)
    }
}
