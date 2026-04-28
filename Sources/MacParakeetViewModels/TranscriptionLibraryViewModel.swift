import Foundation
import MacParakeetCore
import os

public enum LibraryFilter: String, CaseIterable, Sendable {
    case all = "All"
    case youtube = "YouTube"
    case local = "Local"
    case meeting = "Meetings"
    case favorites = "Favorites"
}

public enum TranscriptionLibraryScope: Sendable {
    case all
    case meetings
}

public enum LibrarySortOrder: Sendable {
    case dateDescending
    case dateAscending
    case titleAscending
}

@MainActor @Observable
public final class TranscriptionLibraryViewModel {
    private let logger = Logger(subsystem: "com.macparakeet.viewmodels", category: "TranscriptionLibrary")
    public var transcriptions: [Transcription] = [] { didSet { recomputeFiltered() } }
    public var filter: LibraryFilter = .all { didSet { recomputeFiltered() } }
    public var searchText: String = "" { didSet { recomputeFiltered() } }
    public var sortOrder: LibrarySortOrder = .dateDescending { didSet { recomputeFiltered() } }
    public private(set) var filteredTranscriptions: [Transcription] = []
    public var errorMessage: String?

    private var transcriptionRepo: TranscriptionRepositoryProtocol?
    public let scope: TranscriptionLibraryScope

    public init(scope: TranscriptionLibraryScope = .all) {
        self.scope = scope
    }

    public func configure(transcriptionRepo: TranscriptionRepositoryProtocol) {
        self.transcriptionRepo = transcriptionRepo
    }

    private func recomputeFiltered() {
        var result = transcriptions.filter { matchesScope($0) }

        switch filter {
        case .all: break
        case .youtube: result = result.filter { $0.sourceType == .youtube }
        case .local: result = result.filter { $0.sourceType == .file }
        case .meeting: result = result.filter { $0.sourceType == .meeting }
        case .favorites: result = result.filter(\.isFavorite)
        }

        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter { t in
                t.fileName.lowercased().contains(query)
                    || (t.rawTranscript?.lowercased().contains(query) ?? false)
                    || (t.cleanTranscript?.lowercased().contains(query) ?? false)
                    || (t.channelName?.lowercased().contains(query) ?? false)
            }
        }

        switch sortOrder {
        case .dateDescending: result.sort { $0.createdAt > $1.createdAt }
        case .dateAscending: result.sort { $0.createdAt < $1.createdAt }
        case .titleAscending: result.sort { $0.fileName.localizedCaseInsensitiveCompare($1.fileName) == .orderedAscending }
        }

        filteredTranscriptions = result
    }

    private func matchesScope(_ transcription: Transcription) -> Bool {
        switch scope {
        case .all:
            return true
        case .meetings:
            return transcription.sourceType == .meeting
        }
    }

    public func loadTranscriptions() {
        do {
            transcriptions = (try transcriptionRepo?.fetchAll(limit: nil) ?? [])
                .filter { $0.status != .processing }
        } catch {
            logger.error("Failed to load transcriptions: \(error.localizedDescription)")
            transcriptions = []
        }
    }

    public func toggleFavorite(_ transcription: Transcription) {
        let newValue = !transcription.isFavorite
        do {
            errorMessage = nil
            try transcriptionRepo?.updateFavorite(id: transcription.id, isFavorite: newValue)
            if let idx = transcriptions.firstIndex(where: { $0.id == transcription.id }) {
                transcriptions[idx].isFavorite = newValue
            }
            Telemetry.send(.transcriptionFavorited(isFavorite: newValue))
        } catch {
            logger.error("Failed to update transcription favorite: \(error.localizedDescription, privacy: .private)")
            errorMessage = "Failed to update favorite: \(error.localizedDescription)"
        }
    }

    public func deleteTranscription(_ transcription: Transcription) {
        do {
            errorMessage = nil
            try TranscriptionDeletionCleanup.removeOwnedAssets(for: transcription)
            let deleted = try transcriptionRepo?.delete(id: transcription.id) ?? false
            guard deleted else { return }
            transcriptions.removeAll { $0.id == transcription.id }
            Telemetry.send(.transcriptionDeleted)
        } catch {
            logger.error("Failed to delete transcription: \(error.localizedDescription, privacy: .private)")
            errorMessage = "Failed to delete transcription: \(error.localizedDescription)"
        }
    }
}
