import Foundation

/// Encodes and decodes vocabulary bundles, and applies imports against the live repositories.
///
/// Pure data shuffling — no UI, no `@MainActor`. UI layers wrap this in their own view models.
public final class VocabularyImportExportService: @unchecked Sendable {
    private let customWordRepo: CustomWordRepositoryProtocol
    private let snippetRepo: TextSnippetRepositoryProtocol
    private let appVersion: String?
    private let clock: @Sendable () -> Date

    public init(
        customWordRepo: CustomWordRepositoryProtocol,
        snippetRepo: TextSnippetRepositoryProtocol,
        appVersion: String? = BuildIdentity.current.version,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.customWordRepo = customWordRepo
        self.snippetRepo = snippetRepo
        self.appVersion = appVersion
        self.clock = clock
    }

    // MARK: - Types

    public enum ImportError: LocalizedError, Equatable {
        case invalidSchema
        case unsupportedVersion(found: Int, supported: Int)
        case decodingFailed(String)
        case ioFailed(String)

        public var errorDescription: String? {
            switch self {
            case .invalidSchema:
                return "This file isn't a MacParakeet vocabulary backup."
            case let .unsupportedVersion(found, supported):
                return "This file was created by a newer MacParakeet (format v\(found); this build understands v\(supported)). Update MacParakeet to import it."
            case let .decodingFailed(detail):
                return "Couldn't read the backup file: \(detail)"
            case let .ioFailed(detail):
                return "Couldn't read the file: \(detail)"
            }
        }
    }

    public enum ConflictPolicy: String, Sendable, CaseIterable, Equatable {
        case skip
        case replace
    }

    public struct ImportPreview: Sendable, Equatable {
        public let bundle: VocabularyBundle
        public let wordsTotal: Int
        public let snippetsTotal: Int
        public let wordConflicts: [String]
        public let snippetConflicts: [String]

        public var hasConflicts: Bool {
            !wordConflicts.isEmpty || !snippetConflicts.isEmpty
        }
    }

    public struct ImportResult: Sendable, Equatable {
        public let wordsAdded: Int
        public let wordsReplaced: Int
        public let wordsSkipped: Int
        public let snippetsAdded: Int
        public let snippetsReplaced: Int
        public let snippetsSkipped: Int

        public init(
            wordsAdded: Int = 0,
            wordsReplaced: Int = 0,
            wordsSkipped: Int = 0,
            snippetsAdded: Int = 0,
            snippetsReplaced: Int = 0,
            snippetsSkipped: Int = 0
        ) {
            self.wordsAdded = wordsAdded
            self.wordsReplaced = wordsReplaced
            self.wordsSkipped = wordsSkipped
            self.snippetsAdded = snippetsAdded
            self.snippetsReplaced = snippetsReplaced
            self.snippetsSkipped = snippetsSkipped
        }
    }

    // MARK: - Export

    /// Builds a bundle from the current vocabulary, filtering out `.learned` words.
    public func makeBundle() throws -> VocabularyBundle {
        let words = try customWordRepo.fetchAll()
            .filter { $0.source == .manual }
            .map {
                VocabularyBundle.ExportedCustomWord(
                    word: $0.word,
                    replacement: $0.replacement,
                    isEnabled: $0.isEnabled,
                    createdAt: $0.createdAt
                )
            }

        let snippets = try snippetRepo.fetchAll().map {
            VocabularyBundle.ExportedTextSnippet(
                trigger: $0.trigger,
                expansion: $0.expansion,
                isEnabled: $0.isEnabled,
                action: $0.action,
                createdAt: $0.createdAt
            )
        }

        return VocabularyBundle(
            exportedAt: clock(),
            appVersion: appVersion,
            customWords: words,
            textSnippets: snippets
        )
    }

    public func exportData() throws -> Data {
        let bundle = try makeBundle()
        return try Self.encoder.encode(bundle)
    }

    /// Suggested filename in the form `MacParakeet-Vocabulary-YYYY-MM-DD.json`.
    public func suggestedFilename(now: Date? = nil) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "MacParakeet-Vocabulary-\(formatter.string(from: now ?? clock())).json"
    }

    // MARK: - Import

    public func decodePreview(from data: Data) throws -> ImportPreview {
        let bundle: VocabularyBundle
        do {
            bundle = try Self.decoder.decode(VocabularyBundle.self, from: data)
        } catch {
            throw ImportError.decodingFailed(error.localizedDescription)
        }

        guard bundle.schema == VocabularyBundle.schemaIdentifier else {
            throw ImportError.invalidSchema
        }

        guard bundle.version <= VocabularyBundle.currentVersion else {
            throw ImportError.unsupportedVersion(
                found: bundle.version,
                supported: VocabularyBundle.currentVersion
            )
        }

        let existingWords = Set((try customWordRepo.fetchAll()).map { $0.word.lowercased() })
        let existingTriggers = Set((try snippetRepo.fetchAll()).map { $0.trigger.lowercased() })

        let wordConflicts = bundle.customWords
            .map(\.word)
            .filter { existingWords.contains($0.lowercased()) }
        let snippetConflicts = bundle.textSnippets
            .map(\.trigger)
            .filter { existingTriggers.contains($0.lowercased()) }

        return ImportPreview(
            bundle: bundle,
            wordsTotal: bundle.customWords.count,
            snippetsTotal: bundle.textSnippets.count,
            wordConflicts: wordConflicts,
            snippetConflicts: snippetConflicts
        )
    }

    public func apply(preview: ImportPreview, policy: ConflictPolicy) throws -> ImportResult {
        let now = clock()

        // Custom words: build lookup of existing by lowercase word.
        let existingWords = try customWordRepo.fetchAll()
        var wordsByKey: [String: CustomWord] = [:]
        for word in existingWords { wordsByKey[word.word.lowercased()] = word }

        var wordsAdded = 0
        var wordsReplaced = 0
        var wordsSkipped = 0

        for imported in preview.bundle.customWords {
            let key = imported.word.lowercased()
            if let match = wordsByKey[key] {
                switch policy {
                case .skip:
                    wordsSkipped += 1
                case .replace:
                    _ = try customWordRepo.delete(id: match.id)
                    let new = CustomWord(
                        id: UUID(),
                        word: imported.word,
                        replacement: imported.replacement,
                        source: .manual,
                        isEnabled: imported.isEnabled,
                        createdAt: imported.createdAt ?? now,
                        updatedAt: now
                    )
                    try customWordRepo.save(new)
                    wordsReplaced += 1
                }
            } else {
                let new = CustomWord(
                    id: UUID(),
                    word: imported.word,
                    replacement: imported.replacement,
                    source: .manual,
                    isEnabled: imported.isEnabled,
                    createdAt: imported.createdAt ?? now,
                    updatedAt: now
                )
                try customWordRepo.save(new)
                wordsAdded += 1
            }
        }

        // Snippets.
        let existingSnippets = try snippetRepo.fetchAll()
        var snippetsByKey: [String: TextSnippet] = [:]
        for snippet in existingSnippets { snippetsByKey[snippet.trigger.lowercased()] = snippet }

        var snippetsAdded = 0
        var snippetsReplaced = 0
        var snippetsSkipped = 0

        for imported in preview.bundle.textSnippets {
            let key = imported.trigger.lowercased()
            if let match = snippetsByKey[key] {
                switch policy {
                case .skip:
                    snippetsSkipped += 1
                case .replace:
                    _ = try snippetRepo.delete(id: match.id)
                    let new = TextSnippet(
                        id: UUID(),
                        trigger: imported.trigger,
                        expansion: imported.expansion,
                        isEnabled: imported.isEnabled,
                        useCount: 0,
                        action: imported.action,
                        createdAt: imported.createdAt ?? now,
                        updatedAt: now
                    )
                    try snippetRepo.save(new)
                    snippetsReplaced += 1
                }
            } else {
                let new = TextSnippet(
                    id: UUID(),
                    trigger: imported.trigger,
                    expansion: imported.expansion,
                    isEnabled: imported.isEnabled,
                    useCount: 0,
                    action: imported.action,
                    createdAt: imported.createdAt ?? now,
                    updatedAt: now
                )
                try snippetRepo.save(new)
                snippetsAdded += 1
            }
        }

        return ImportResult(
            wordsAdded: wordsAdded,
            wordsReplaced: wordsReplaced,
            wordsSkipped: wordsSkipped,
            snippetsAdded: snippetsAdded,
            snippetsReplaced: snippetsReplaced,
            snippetsSkipped: snippetsSkipped
        )
    }

    // MARK: - Codec

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
