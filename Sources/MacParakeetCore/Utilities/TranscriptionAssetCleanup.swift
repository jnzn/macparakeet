import Foundation
import os

public enum TranscriptionAssetCleanup {
    private static let logger = Logger(
        subsystem: "com.macparakeet.core",
        category: "TranscriptionAssetCleanup"
    )

    public static func removeOwnedAssets(
        for transcription: Transcription,
        fileManager: FileManager = .default
    ) {
        guard let filePath = transcription.filePath, !filePath.isEmpty else { return }

        switch transcription.sourceType {
        case .youtube:
            removeYouTubeFile(at: URL(fileURLWithPath: filePath), fileManager: fileManager)
        case .meeting:
            removeMeetingFolder(containing: URL(fileURLWithPath: filePath), fileManager: fileManager)
        case .file:
            return
        }
    }

    private static func removeYouTubeFile(at fileURL: URL, fileManager: FileManager) {
        let downloadsRootURL = URL(fileURLWithPath: AppPaths.youtubeDownloadsDir, isDirectory: true)
            .standardizedFileURL
        let targetURL = fileURL.standardizedFileURL

        guard targetURL.path.hasPrefix(downloadsRootURL.path + "/") else {
            logger.warning(
                "Refusing to remove YouTube asset outside app support: \(targetURL.path, privacy: .private)"
            )
            return
        }

        removeItem(at: targetURL, fileManager: fileManager)
    }

    private static func removeMeetingFolder(containing fileURL: URL, fileManager: FileManager) {
        let meetingRootURL = URL(fileURLWithPath: AppPaths.meetingRecordingsDir, isDirectory: true)
            .standardizedFileURL
        let folderURL = fileURL.deletingLastPathComponent().standardizedFileURL

        guard folderURL.path.hasPrefix(meetingRootURL.path + "/") else {
            logger.warning(
                "Refusing to remove meeting folder outside app support: \(folderURL.path, privacy: .private)"
            )
            return
        }
        removeItem(at: folderURL, fileManager: fileManager)
    }

    private static func removeItem(at url: URL, fileManager: FileManager) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            logger.warning(
                "Failed to remove transcription asset at \(url.path, privacy: .private): \(String(describing: error), privacy: .private)"
            )
        }
    }
}
