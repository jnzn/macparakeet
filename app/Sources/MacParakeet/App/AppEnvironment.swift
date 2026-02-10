import Foundation
import MacParakeetCore

/// Service container: creates and wires up all dependencies.
@MainActor
final class AppEnvironment {
    let databaseManager: DatabaseManager
    let dictationRepo: DictationRepository
    let transcriptionRepo: TranscriptionRepository
    let sttClient: STTClient
    let audioProcessor: AudioProcessor
    let dictationService: DictationService
    let transcriptionService: TranscriptionService
    let clipboardService: ClipboardService
    let exportService: ExportService
    let permissionService: PermissionService

    init() throws {
        // Database
        let dbPath = AppPaths.databasePath
        try FileManager.default.createDirectory(
            atPath: AppPaths.appSupportDir,
            withIntermediateDirectories: true
        )
        databaseManager = try DatabaseManager(path: dbPath)

        // Repositories
        dictationRepo = DictationRepository(dbQueue: databaseManager.dbQueue)
        transcriptionRepo = TranscriptionRepository(dbQueue: databaseManager.dbQueue)

        // Services
        sttClient = STTClient()
        audioProcessor = AudioProcessor()
        clipboardService = ClipboardService()
        exportService = ExportService()
        permissionService = PermissionService()

        dictationService = DictationService(
            audioProcessor: audioProcessor,
            sttClient: sttClient,
            dictationRepo: dictationRepo,
            clipboardService: clipboardService
        )

        transcriptionService = TranscriptionService(
            audioProcessor: audioProcessor,
            sttClient: sttClient,
            transcriptionRepo: transcriptionRepo
        )
    }
}
