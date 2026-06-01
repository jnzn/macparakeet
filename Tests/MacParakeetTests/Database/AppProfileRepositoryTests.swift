import XCTest
import GRDB
@testable import MacParakeetCore

final class AppProfileRepositoryTests: XCTestCase {
    private func makeDB() throws -> DatabaseManager {
        try DatabaseManager(path: ":memory:")
    }

    func testMigrationCreatesAppProfileTable() throws {
        let db = try makeDB()
        let exists = try db.dbQueue.read { try $0.tableExists("app_profile") }
        XCTAssertTrue(exists)
    }
}
