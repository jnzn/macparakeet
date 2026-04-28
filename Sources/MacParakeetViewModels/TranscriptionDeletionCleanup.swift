import Foundation
import MacParakeetCore

enum TranscriptionDeletionCleanup {
    static func removeOwnedAssets(for transcription: Transcription) {
        Task.detached(priority: .utility) {
            TranscriptionAssetCleanup.removeOwnedAssets(for: transcription)
        }
    }
}
