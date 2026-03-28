import Foundation
import MacParakeetCore

public enum LibraryFilter: String, CaseIterable, Sendable {
    case all = "All"
    case youtube = "YouTube"
    case local = "Local"
    case favorites = "Favorites"
}

public enum LibrarySortOrder: Sendable {
    case dateDescending
    case dateAscending
    case titleAscending
}

@MainActor @Observable
public final class TranscriptionLibraryViewModel {
    public var transcriptions: [Transcription] = [] { didSet { recomputeFiltered() } }
    public var filter: LibraryFilter = .all { didSet { recomputeFiltered() } }
    public var searchText: String = "" { didSet { recomputeFiltered() } }
    public var sortOrder: LibrarySortOrder = .dateDescending { didSet { recomputeFiltered() } }
    public private(set) var filteredTranscriptions: [Transcription] = []

    private var transcriptionRepo: TranscriptionRepositoryProtocol?

    public init() {}

    public func configure(transcriptionRepo: TranscriptionRepositoryProtocol) {
        self.transcriptionRepo = transcriptionRepo
    }

    private func recomputeFiltered() {
        var result = transcriptions

        switch filter {
        case .all: break
        case .youtube: result = result.filter { $0.sourceURL != nil }
        case .local: result = result.filter { $0.sourceURL == nil }
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

    public func loadTranscriptions() {
        transcriptions = (try? transcriptionRepo?.fetchAll(limit: nil)) ?? []
    }

    public func toggleFavorite(_ transcription: Transcription) {
        let newValue = !transcription.isFavorite
        do {
            try transcriptionRepo?.updateFavorite(id: transcription.id, isFavorite: newValue)
            if let idx = transcriptions.firstIndex(where: { $0.id == transcription.id }) {
                transcriptions[idx].isFavorite = newValue
            }
        } catch {
            // DB failed — don't update UI state
        }
    }

    public func deleteTranscription(_ transcription: Transcription) {
        do {
            _ = try transcriptionRepo?.delete(id: transcription.id)
            transcriptions.removeAll { $0.id == transcription.id }
        } catch {
            // DB failed — don't remove from UI
        }
    }
}
