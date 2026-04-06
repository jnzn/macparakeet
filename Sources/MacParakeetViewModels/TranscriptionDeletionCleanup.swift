import Foundation
import MacParakeetCore
import os

enum TranscriptionDeletionCleanup {
    private static let logger = Logger(
        subsystem: "com.macparakeet.viewmodels",
        category: "TranscriptionDeletionCleanup"
    )

    static func removeOwnedAssets(for transcription: Transcription) {
        Task.detached(priority: .utility) {
            guard let filePath = transcription.filePath else { return }

            switch transcription.sourceType {
            case .youtube:
                removeItem(at: URL(fileURLWithPath: filePath))
            case .meeting:
                removeMeetingFolder(containing: URL(fileURLWithPath: filePath))
            case .file:
                return
            }
        }
    }

    private static func removeMeetingFolder(containing fileURL: URL) {
        let meetingRootURL = URL(fileURLWithPath: AppPaths.meetingRecordingsDir, isDirectory: true)
            .standardizedFileURL
        let folderURL = fileURL.deletingLastPathComponent().standardizedFileURL

        guard folderURL.path.hasPrefix(meetingRootURL.path + "/") else {
            logger.warning(
                "Refusing to remove meeting folder outside app support: \(folderURL.path, privacy: .private)"
            )
            return
        }

        removeItem(at: folderURL)
    }

    private static func removeItem(at url: URL) {
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            logger.warning(
                "Failed to remove transcription asset at \(url.path, privacy: .private): \(String(describing: error), privacy: .private)"
            )
        }
    }
}
