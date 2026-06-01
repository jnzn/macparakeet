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

    // MARK: - Seed-version re-seed

    private func freshDefaults() -> UserDefaults {
        let suite = "appprofileseeder-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    private func bundleURL(_ profiles: [AppProfile]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("seed-\(UUID()).json")
        try JSONEncoder().encode(profiles).write(to: url)
        return url
    }

    func testSeedIfEmptyRecordsSeedVersion() throws {
        let repo = try makeRepo()
        let defaults = freshDefaults()
        try AppProfileSeeder.seedIfEmpty(repository: repo, bundledSeedURL: nil, defaults: defaults)
        XCTAssertEqual(defaults.integer(forKey: AppProfileSeeder.seedVersionDefaultsKey), AppProfileSeeder.currentSeedVersion)
    }

    func testReseedReplacesWhenVersionOutdated() throws {
        let repo = try makeRepo()
        // Simulate an existing pre-versioning install: populated table, no marker.
        try repo.save(AppProfile(id: "old1", displayName: "Old", bundleIDs: ["com.old"], promptOverride: "OLD"))
        let defaults = freshDefaults()  // version 0 (missing)
        let newSet = [AppProfile(id: "cat-email", displayName: "E-mail", bundleIDs: ["com.apple.mail"], promptOverride: "NEW {{TRANSCRIPT}}", enabled: true, sortOrder: 0)]
        let url = try bundleURL(newSet)
        defer { try? FileManager.default.removeItem(at: url) }

        try AppProfileSeeder.reseedIfVersionOutdated(repository: repo, bundledSeedURL: url, defaults: defaults)

        XCTAssertEqual(try repo.fetchAll().map(\.id), ["cat-email"])
        XCTAssertEqual(defaults.integer(forKey: AppProfileSeeder.seedVersionDefaultsKey), AppProfileSeeder.currentSeedVersion)
    }

    func testReseedNoOpWhenVersionCurrent() throws {
        let repo = try makeRepo()
        try repo.save(AppProfile(id: "keep", displayName: "Keep", bundleIDs: [], promptOverride: nil))
        let defaults = freshDefaults()
        defaults.set(AppProfileSeeder.currentSeedVersion, forKey: AppProfileSeeder.seedVersionDefaultsKey)
        try AppProfileSeeder.reseedIfVersionOutdated(repository: repo, bundledSeedURL: nil, defaults: defaults)
        XCTAssertEqual(try repo.fetchAll().map(\.id), ["keep"])  // untouched
    }
}
