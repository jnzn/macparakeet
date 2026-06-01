import XCTest
@testable import MacParakeetCore

final class AppProfileSeederTests: XCTestCase {
    private func makeRepo() throws -> AppProfileRepository {
        AppProfileRepository(dbQueue: try DatabaseManager(path: ":memory:").dbQueue)
    }

    func testSeedsGenericDefaultsWhenNoBundledFile() throws {
        let repo = try makeRepo()
        try AppProfileSeeder.seedIfEmpty(repository: repo, bundledSeedURL: nil)
        XCTAssertEqual(try repo.fetchAll().map(\.id), AppProfile.defaults.map(\.id))
    }

    func testSeedsFromBundledFileWhenPresent() throws {
        let repo = try makeRepo()
        let custom = [AppProfile(id: "real-email", displayName: "My Email", bundleIDs: ["com.apple.mail"], promptOverride: "REAL {{TRANSCRIPT}}", enabled: true, sortOrder: 0)]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("seed-\(UUID()).json")
        try JSONEncoder().encode(custom).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        try AppProfileSeeder.seedIfEmpty(repository: repo, bundledSeedURL: url)
        XCTAssertEqual(try repo.fetchAll().map(\.id), ["real-email"])
    }

    func testNoOpWhenAlreadyPopulated() throws {
        let repo = try makeRepo()
        try repo.save(AppProfile(id: "existing", displayName: "X", bundleIDs: [], promptOverride: nil))
        try AppProfileSeeder.seedIfEmpty(repository: repo, bundledSeedURL: nil)
        XCTAssertEqual(try repo.fetchAll().map(\.id), ["existing"])
    }
}
