import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class AppProfilesViewModelTests: XCTestCase {
    private func makeVM(preview: @escaping @Sendable (String, String) async throws -> String = { _, _ in "OUT" }) throws -> AppProfilesViewModel {
        let repo = AppProfileRepository(dbQueue: try DatabaseManager(path: ":memory:").dbQueue)
        try repo.save(AppProfile(id: "a", displayName: "A", bundleIDs: ["com.x"], promptOverride: "PA {{TRANSCRIPT}}", enabled: true, sortOrder: 0))
        let store = AppProfileStore(repository: repo)
        store.load()
        return AppProfilesViewModel(store: store, runPreview: preview)
    }

    func testNewScriptAddsAndSelects() throws {
        let vm = try makeVM()
        vm.newScript()
        XCTAssertEqual(vm.store.profiles.count, 2)
        XCTAssertEqual(vm.selectedID, vm.store.profiles.last?.id)
    }

    func testAddAndRemoveApp() throws {
        let vm = try makeVM()
        vm.select(id: "a")
        vm.addApp(bundleID: "com.y")
        XCTAssertEqual(vm.draft?.bundleIDs, ["com.x", "com.y"])
        vm.removeApp(bundleID: "com.x")
        XCTAssertEqual(vm.draft?.bundleIDs, ["com.y"])
    }

    func testAddDuplicateAppIsIgnored() throws {
        let vm = try makeVM()
        vm.select(id: "a")
        vm.addApp(bundleID: "com.x")
        XCTAssertEqual(vm.draft?.bundleIDs, ["com.x"])
    }

    func testSavePersistsDraftToStore() throws {
        let vm = try makeVM()
        vm.select(id: "a")
        vm.draft?.displayName = "Renamed"
        vm.save()
        XCTAssertEqual(vm.store.profiles.first(where: { $0.id == "a" })?.displayName, "Renamed")
    }

    func testDeleteSelectedRemovesFromStore() throws {
        let vm = try makeVM()
        vm.select(id: "a")
        vm.deleteSelected()
        XCTAssertTrue(vm.store.profiles.isEmpty)
        XCTAssertNil(vm.selectedID)
    }

    func testDeleteMiddleSelectsAdjacentNotFirst() throws {
        let repo = AppProfileRepository(dbQueue: try DatabaseManager(path: ":memory:").dbQueue)
        try repo.save(AppProfile(id: "p1", displayName: "P1", bundleIDs: [], promptOverride: nil, enabled: true, sortOrder: 0))
        try repo.save(AppProfile(id: "p2", displayName: "P2", bundleIDs: [], promptOverride: nil, enabled: true, sortOrder: 1))
        try repo.save(AppProfile(id: "p3", displayName: "P3", bundleIDs: [], promptOverride: nil, enabled: true, sortOrder: 2))
        let store = AppProfileStore(repository: repo)
        store.load()
        let vm = AppProfilesViewModel(store: store, runPreview: { _, _ in "OUT" })
        vm.select(id: "p2")  // select middle
        vm.deleteSelected()
        // After deleting p2 (was at index 1), p3 slides to index 1 — should be selected.
        XCTAssertEqual(vm.selectedID, "p3")
    }

    func testRunPreviewSetsOutput() async throws {
        let vm = try makeVM(preview: { _, _ in "Hi — can you send me the deck?" })
        vm.select(id: "a")
        await vm.runPreview(sample: "hey can u send me the deck")
        XCTAssertEqual(vm.previewOutput, "Hi — can you send me the deck?")
        XCTAssertNil(vm.previewError)
    }

    func testRunPreviewSurfacesError() async throws {
        struct Boom: Error {}
        let vm = try makeVM(preview: { _, _ in throw Boom() })
        vm.select(id: "a")
        await vm.runPreview(sample: "x")
        XCTAssertNil(vm.previewOutput)
        XCTAssertNotNil(vm.previewError)
    }

    func testDuplicateBundleWarningAcrossScripts() throws {
        let vm = try makeVM()
        vm.newScript()                              // selects the new empty script
        vm.addApp(bundleID: "com.x")                // already owned by "a"
        XCTAssertTrue(vm.duplicateBundleIDs.contains("com.x"))
    }

    func testRunPreviewNotConfiguredShowsSettingsMessage() async throws {
        let vm = try makeVM(preview: { _, _ in throw LLMError.notConfigured })
        vm.select(id: "a")
        await vm.runPreview(sample: "x")
        XCTAssertNil(vm.previewOutput)
        XCTAssertEqual(vm.previewError, "Configure AI in Settings to test.")
    }
}
