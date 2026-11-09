import XCTest
import GRDB
@testable import MacParakeetCore

final class AppProfileRepositoryTests: XCTestCase {
    private func makeDB() throws -> DatabaseManager {
        try DatabaseManager(path: ":memory:")
    }

    private func makeRepo(_ db: DatabaseManager) -> AppProfileRepository {
        AppProfileRepository(dbQueue: db.dbQueue)
    }

    func testMigrationCreatesAppProfileTable() throws {
        let db = try makeDB()
        let exists = try db.dbQueue.read { try $0.tableExists("app_profile") }
        XCTAssertTrue(exists)
    }

    func testSaveFetchRoundTripWithBundleIDs() throws {
        let repo = makeRepo(try makeDB())
        let p = AppProfile(id: "email", displayName: "Email", bundleIDs: ["com.apple.mail", "com.microsoft.Outlook"], promptOverride: "X {{TRANSCRIPT}}", enabled: true, sortOrder: 2)
        try repo.save(p)
        let back = try XCTUnwrap(repo.fetch(id: "email"))
        XCTAssertEqual(back, p)
        XCTAssertEqual(back.bundleIDs, ["com.apple.mail", "com.microsoft.Outlook"])
    }

    func testFetchAllOrdersBySortOrder() throws {
        let repo = makeRepo(try makeDB())
        try repo.save(AppProfile(id: "b", displayName: "B", bundleIDs: [], promptOverride: nil, enabled: true, sortOrder: 5))
        try repo.save(AppProfile(id: "a", displayName: "A", bundleIDs: [], promptOverride: nil, enabled: true, sortOrder: 1))
        XCTAssertEqual(try repo.fetchAll().map(\.id), ["a", "b"])
    }

    func testDeleteRemovesRow() throws {
        let repo = makeRepo(try makeDB())
        try repo.save(AppProfile(id: "a", displayName: "A", bundleIDs: [], promptOverride: nil))
        XCTAssertTrue(try repo.delete(id: "a"))
        XCTAssertNil(try repo.fetch(id: "a"))
        XCTAssertFalse(try repo.delete(id: "a"))
    }
}
