import Foundation
import GRDB

public protocol AppProfileRepositoryProtocol: Sendable {
    func save(_ profile: AppProfile) throws
    func fetch(id: String) throws -> AppProfile?
    func fetchAll() throws -> [AppProfile]
    @discardableResult func delete(id: String) throws -> Bool
}

public final class AppProfileRepository: AppProfileRepositoryProtocol {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func save(_ profile: AppProfile) throws {
        try dbQueue.write { db in try profile.save(db) }
    }

    public func fetch(id: String) throws -> AppProfile? {
        try dbQueue.read { db in try AppProfile.fetchOne(db, key: id) }
    }

    public func fetchAll() throws -> [AppProfile] {
        try dbQueue.read { db in
            try AppProfile
                .order(AppProfile.Columns.sortOrder.asc, AppProfile.Columns.displayName.asc)
                .fetchAll(db)
        }
    }

    @discardableResult
    public func delete(id: String) throws -> Bool {
        try dbQueue.write { db in try AppProfile.deleteOne(db, key: id) }
    }
}
