import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class AppProfileStoreTests: XCTestCase {
    private func makeStore() throws -> AppProfileStore {
        let repo = AppProfileRepository(dbQueue: try DatabaseManager(path: ":memory:").dbQueue)
        try repo.save(AppProfile(id: "a", displayName: "A", bundleIDs: ["com.x"], promptOverride: "PA", enabled: true, sortOrder: 0))
        let store = AppProfileStore(repository: repo)
        store.load()
        return store
    }

    func testLoadPopulatesBothFaces() throws {
        let store = try makeStore()
        XCTAssertEqual(store.profiles.map(\.id), ["a"])
        XCTAssertEqual(store.snapshot.resolve(bundleID: "com.x")?.id, "a")
    }

    func testUpsertUpdatesObservableAndSnapshot() throws {
        let store = try makeStore()
        store.upsert(AppProfile(id: "b", displayName: "B", bundleIDs: ["com.y"], promptOverride: "PB", enabled: true, sortOrder: 1))
        XCTAssertEqual(store.profiles.map(\.id), ["a", "b"])
        XCTAssertEqual(store.snapshot.resolve(bundleID: "com.y")?.id, "b")
    }

    func testDeleteUpdatesBothFaces() throws {
        let store = try makeStore()
        store.delete(id: "a")
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertNil(store.snapshot.resolve(bundleID: "com.x"))
    }
}
