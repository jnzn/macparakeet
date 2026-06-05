import Foundation
import GRDB

public protocol LLMRunRepositoryProtocol: Sendable {
    func save(_ run: LLMRun) async throws
    func fetchRecent(limit: Int) throws -> [LLMRun]
    func fetchForDictation(id: UUID) throws -> [LLMRun]
    func fetchForTranscription(id: UUID) throws -> [LLMRun]
    func fetchForPromptResult(id: UUID) throws -> [LLMRun]
    func fetchForChatConversation(id: UUID) throws -> [LLMRun]
    func fetchForTransformHistory(id: UUID) throws -> [LLMRun]
    func count() throws -> Int
    func deleteAll() throws
}

public extension LLMRunRepositoryProtocol {
    func fetchRecent() throws -> [LLMRun] {
        try fetchRecent(limit: 200)
    }
}

public final class LLMRunRepository: LLMRunRepositoryProtocol {
    /// Default cap on retained rows. The ledger is metadata-only (no prompt or
    /// transcript content), so even at the cap it is on the order of ~1 MB; this
    /// only stops the table growing without bound (audit PDX-012). Tunable via
    /// init for tests and power users.
    public static let defaultRetentionLimit = 5000

    private let dbQueue: DatabaseQueue
    private let retentionLimit: Int

    public init(
        dbQueue: DatabaseQueue,
        retentionLimit: Int = LLMRunRepository.defaultRetentionLimit
    ) {
        self.dbQueue = dbQueue
        self.retentionLimit = max(1, retentionLimit)
    }

    public func save(_ run: LLMRun) async throws {
        let limit = retentionLimit
        try await dbQueue.write { db in
            try run.save(db)
            try Self.enforceRetentionLimit(db, limit: limit)
        }
    }

    /// Keep only the newest `limit` rows so the ledger can't grow without bound
    /// (audit PDX-012). There is no content to preserve — rows are metadata only,
    /// and the full audio/transcript for any source still lives in its own table.
    /// Uses a subquery `LIMIT` (portable: a bare `DELETE … LIMIT` needs a SQLite
    /// compile-time option) and only deletes when actually over the cap.
    private static func enforceRetentionLimit(_ db: Database, limit: Int) throws {
        let total = try LLMRun.fetchCount(db)
        guard total > limit else { return }
        try db.execute(
            sql: """
                DELETE FROM \(LLMRun.databaseTableName)
                WHERE rowid IN (
                    SELECT rowid FROM \(LLMRun.databaseTableName)
                    ORDER BY \(LLMRun.Columns.createdAt.rawValue) ASC, rowid ASC
                    LIMIT ?
                )
                """,
            arguments: [total - limit]
        )
    }

    public func fetchRecent(limit: Int = 200) throws -> [LLMRun] {
        try dbQueue.read { db in
            try LLMRun
                .order(LLMRun.Columns.createdAt.desc)
                .limit(max(0, limit))
                .fetchAll(db)
        }
    }

    public func fetchForDictation(id: UUID) throws -> [LLMRun] {
        try dbQueue.read { db in
            try LLMRun
                .filter(LLMRun.Columns.dictationId == id)
                .order(LLMRun.Columns.createdAt.desc)
                .fetchAll(db)
        }
    }

    public func fetchForTranscription(id: UUID) throws -> [LLMRun] {
        try dbQueue.read { db in
            try LLMRun
                .filter(LLMRun.Columns.transcriptionId == id)
                .order(LLMRun.Columns.createdAt.desc)
                .fetchAll(db)
        }
    }

    public func fetchForPromptResult(id: UUID) throws -> [LLMRun] {
        try dbQueue.read { db in
            try LLMRun
                .filter(LLMRun.Columns.promptResultId == id)
                .order(LLMRun.Columns.createdAt.desc)
                .fetchAll(db)
        }
    }

    public func fetchForChatConversation(id: UUID) throws -> [LLMRun] {
        try dbQueue.read { db in
            try LLMRun
                .filter(LLMRun.Columns.chatConversationId == id)
                .order(LLMRun.Columns.createdAt.desc)
                .fetchAll(db)
        }
    }

    public func fetchForTransformHistory(id: UUID) throws -> [LLMRun] {
        try dbQueue.read { db in
            try LLMRun
                .filter(LLMRun.Columns.transformHistoryId == id)
                .order(LLMRun.Columns.createdAt.desc)
                .fetchAll(db)
        }
    }

    public func count() throws -> Int {
        try dbQueue.read { db in
            try LLMRun.fetchCount(db)
        }
    }

    public func deleteAll() throws {
        _ = try dbQueue.write { db in
            try LLMRun.deleteAll(db)
        }
    }
}
