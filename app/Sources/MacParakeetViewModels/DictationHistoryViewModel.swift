import AppKit
import Foundation
import MacParakeetCore

@MainActor
@Observable
public final class DictationHistoryViewModel {
    public var groupedDictations: [(String, [Dictation])] = []
    public var searchText: String = "" {
        didSet { loadDictations() }
    }
    public var selectedDictation: Dictation?

    private var dictationRepo: DictationRepositoryProtocol?

    public init() {}

    public func configure(dictationRepo: DictationRepositoryProtocol) {
        self.dictationRepo = dictationRepo
        loadDictations()
    }

    public func loadDictations() {
        guard let repo = dictationRepo else { return }

        let dictations: [Dictation]
        if searchText.isEmpty {
            dictations = (try? repo.fetchAll(limit: 200)) ?? []
        } else {
            dictations = (try? repo.search(query: searchText, limit: 200)) ?? []
        }

        // Group by date
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: dictations) { dictation in
            calendar.startOfDay(for: dictation.createdAt)
        }

        groupedDictations = grouped.sorted { $0.key > $1.key }.map { (key, value) in
            (formatDateHeader(key), value.sorted { $0.createdAt > $1.createdAt })
        }
    }

    public func deleteDictation(_ dictation: Dictation) {
        guard let repo = dictationRepo else { return }
        if let path = dictation.audioPath {
            try? FileManager.default.removeItem(atPath: path)
        }
        _ = try? repo.delete(id: dictation.id)
        if selectedDictation?.id == dictation.id {
            selectedDictation = nil
        }
        loadDictations()
    }

    public func copyToClipboard(_ dictation: Dictation) {
        let text = dictation.cleanTranscript ?? dictation.rawTranscript
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Private

    private func formatDateHeader(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return formatter.string(from: date)
        }
    }
}
