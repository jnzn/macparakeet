import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class TransformsViewModelTests: XCTestCase {
    var manager: DatabaseManager!
    var repo: PromptRepository!
    var viewModel: TransformsViewModel!

    override func setUp() async throws {
        // The no-argument initializer is the in-memory test database.
        // `DatabaseManager(path:)` is the file-backed production path.
        manager = try DatabaseManager()
        repo = PromptRepository(dbQueue: manager.dbQueue)
        viewModel = TransformsViewModel()
        viewModel.configure(repo: repo, hasLLMProvider: true)
        await viewModel.load()
    }

    func testLoadPullsOnlyTransformCategoryPrompts() {
        XCTAssertEqual(viewModel.transforms.count, 3, "Three built-in Transforms ship with the app.")
        XCTAssertTrue(viewModel.transforms.allSatisfy { $0.category == .transform })
        // Built-in count is exposed via the helper.
        XCTAssertEqual(viewModel.builtInTransforms.count, 3)
        XCTAssertEqual(viewModel.customTransforms.count, 0)
    }

    func testLoadOrdersBySortOrder() {
        let names = viewModel.transforms.map(\.name)
        XCTAssertEqual(names, ["Polish", "Distill", "Decide"])
    }

    func testShortcutBindingsExposesNonNilShortcuts() {
        let bindings = viewModel.shortcutBindings
        XCTAssertEqual(bindings.count, 3, "All three built-ins ship with default shortcuts.")
        let labels = Set(bindings.values.map(\.keyLabel))
        XCTAssertEqual(labels, ["1", "2", "3"])
    }

    func testSaveNewCustomTransformAppendsToList() async {
        let prompt = Prompt(
            id: UUID(),
            name: "Soften",
            content: "Make the message warmer.",
            category: .transform,
            isBuiltIn: false,
            sortOrder: 200,
            keyboardShortcut: nil,
            runningLabel: nil
        )
        let saved = await viewModel.save(prompt)
        XCTAssertTrue(saved)
        XCTAssertEqual(viewModel.transforms.count, 4)
        XCTAssertTrue(viewModel.customTransforms.contains(where: { $0.name == "Soften" }))
    }

    func testDeleteCustomTransformRemovesRow() async {
        let prompt = Prompt(
            id: UUID(),
            name: "Sharpen",
            content: "Make it crisper.",
            category: .transform,
            isBuiltIn: false,
            sortOrder: 201
        )
        await viewModel.save(prompt)
        XCTAssertEqual(viewModel.transforms.count, 4)

        let deleted = await viewModel.delete(prompt)
        XCTAssertTrue(deleted)
        XCTAssertEqual(viewModel.transforms.count, 3)
        XCTAssertFalse(viewModel.transforms.contains(where: { $0.id == prompt.id }))
    }

    func testDeleteBuiltInIsRejected() async {
        let polish = viewModel.transforms.first(where: { $0.name == "Polish" })!
        let deleted = await viewModel.delete(polish)
        XCTAssertFalse(deleted, "Built-ins must be protected from deletion.")
        XCTAssertEqual(viewModel.transforms.count, 3)
    }

    func testConfirmPendingDeleteClearsAndDeletes() async {
        let prompt = Prompt(
            id: UUID(),
            name: "Temp",
            content: "Body.",
            category: .transform,
            isBuiltIn: false
        )
        await viewModel.save(prompt)
        viewModel.pendingDeleteTransform = prompt

        await viewModel.confirmPendingDelete()

        XCTAssertNil(viewModel.pendingDeleteTransform)
        XCTAssertFalse(viewModel.transforms.contains(where: { $0.id == prompt.id }))
    }

    func testResetBuiltInRestoresDefaultContent() async {
        // User customizes Polish: prompt body + shortcut + label.
        var polish = viewModel.transforms.first(where: { $0.name == "Polish" })!
        let customized = polish
        polish.content = "Custom polish prompt body."
        polish.keyboardShortcut = KeyboardShortcut(
            modifiers: KeyboardShortcut.ModifierFlag.option.rawValue
                | KeyboardShortcut.ModifierFlag.shift.rawValue,
            keyCode: 0x23,
            keyLabel: "P"
        ).encodedString()
        polish.runningLabel = "Refining…"
        await viewModel.save(polish)

        let reset = await viewModel.resetBuiltIn(polish)
        XCTAssertTrue(reset)

        let restored = viewModel.transforms.first(where: { $0.id == customized.id })!
        XCTAssertNotEqual(restored.content, "Custom polish prompt body.")
        XCTAssertEqual(restored.shortcut?.keyLabel, "1", "Default shortcut should be restored.")
        XCTAssertEqual(restored.runningLabel, "Polishing…", "Default running label should be restored.")
    }

    func testResetBuiltInRejectsDefaultShortcutWhenAlreadyUsed() async throws {
        var polish = try XCTUnwrap(viewModel.transforms.first(where: { $0.name == "Polish" }))
        polish.content = "Custom polish prompt body."
        polish.keyboardShortcut = KeyboardShortcut.parse("opt+4")!.encodedString()
        let savedPolish = await viewModel.save(polish)
        XCTAssertTrue(savedPolish)

        let custom = Prompt(
            id: UUID(),
            name: "Custom Opt One",
            content: "Body.",
            category: .transform,
            isBuiltIn: false,
            sortOrder: 200,
            keyboardShortcut: KeyboardShortcut.parse("opt+1")!.encodedString()
        )
        let savedCustom = await viewModel.save(custom)
        XCTAssertTrue(savedCustom)

        let reset = await viewModel.resetBuiltIn(polish)
        XCTAssertFalse(reset)
        XCTAssertTrue(viewModel.errorMessage?.contains("already used") ?? false)

        let reloadedPolish = try XCTUnwrap(viewModel.transforms.first(where: { $0.id == polish.id }))
        XCTAssertEqual(reloadedPolish.content, "Custom polish prompt body.")
        XCTAssertEqual(reloadedPolish.shortcut?.displayString, "⌥4")

        let reloadedCustom = try XCTUnwrap(viewModel.transforms.first(where: { $0.id == custom.id }))
        XCTAssertEqual(reloadedCustom.shortcut?.displayString, "⌥1")
    }

    func testResetBuiltInRejectsDefaultShortcutWhenReservedByAppHotkey() async throws {
        var polish = try XCTUnwrap(viewModel.transforms.first(where: { $0.name == "Polish" }))
        polish.content = "Custom polish prompt body."
        polish.keyboardShortcut = KeyboardShortcut.parse("opt+4")!.encodedString()
        let savedPolish = await viewModel.save(polish)
        XCTAssertTrue(savedPolish)

        let reset = await viewModel.resetBuiltIn(
            polish,
            reservedHotkeys: [
                TransformShortcutReservedHotkey(name: "hands-free dictation", trigger: .option)
            ]
        )
        XCTAssertFalse(reset)
        XCTAssertTrue(viewModel.errorMessage?.contains("conflicts with hands-free dictation") ?? false)

        let reloadedPolish = try XCTUnwrap(viewModel.transforms.first(where: { $0.id == polish.id }))
        XCTAssertEqual(reloadedPolish.content, "Custom polish prompt body.")
        XCTAssertEqual(reloadedPolish.shortcut?.displayString, "⌥4")
    }

    func testReseedMissingBuiltInsRecreatesDeletedDefault() async throws {
        // Force-delete Polish via raw SQL (bypassing the built-in protection)
        // to simulate a corrupted state where a built-in is missing.
        let polish = viewModel.transforms.first(where: { $0.name == "Polish" })!
        try await manager.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM prompts WHERE id = ?", arguments: [polish.id])
        }
        await viewModel.load()
        XCTAssertEqual(viewModel.transforms.count, 2, "Polish should be gone before reseed.")

        await viewModel.reseedMissingBuiltIns()

        XCTAssertEqual(viewModel.transforms.count, 3)
        XCTAssertTrue(viewModel.transforms.contains(where: { $0.name == "Polish" }))
    }

    func testReseedDoesNotOverwriteExistingBuiltIn() async {
        // Customize Polish, then reseed — the custom values must survive.
        var polish = viewModel.transforms.first(where: { $0.name == "Polish" })!
        let customContent = "User-customized Polish body."
        polish.content = customContent
        await viewModel.save(polish)

        await viewModel.reseedMissingBuiltIns()

        let reloaded = viewModel.transforms.first(where: { $0.name == "Polish" })!
        XCTAssertEqual(reloaded.content, customContent, "Reseed must not overwrite existing built-in customizations.")
    }

    func testReseedDoesNotOverwriteExistingBuiltInWhenVisibleStateIsStale() async throws {
        var polish = try XCTUnwrap(viewModel.transforms.first(where: { $0.name == "Polish" }))
        let customContent = "User-customized Polish body while UI state is stale."
        polish.content = customContent
        let saved = await viewModel.save(polish)
        XCTAssertTrue(saved)

        viewModel.transforms = []
        viewModel.allPrompts = []

        let reseeded = await viewModel.reseedMissingBuiltIns()
        XCTAssertTrue(reseeded)

        let reloaded = try XCTUnwrap(viewModel.transforms.first(where: { $0.id == polish.id }))
        XCTAssertEqual(reloaded.content, customContent)
    }

    func testReseedMissingBuiltInsClearsDefaultShortcutWhenAlreadyUsed() async throws {
        let polish = try XCTUnwrap(viewModel.transforms.first(where: { $0.name == "Polish" }))
        try await manager.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM prompts WHERE id = ?", arguments: [polish.id])
        }
        await viewModel.load()

        let custom = Prompt(
            id: UUID(),
            name: "Custom Opt One",
            content: "Body.",
            category: .transform,
            isBuiltIn: false,
            sortOrder: 200,
            keyboardShortcut: KeyboardShortcut.parse("opt+1")!.encodedString()
        )
        let savedCustom = await viewModel.save(custom)
        XCTAssertTrue(savedCustom)

        let reseeded = await viewModel.reseedMissingBuiltIns()
        XCTAssertTrue(reseeded)

        let restoredPolish = try XCTUnwrap(viewModel.transforms.first(where: { $0.name == "Polish" }))
        XCTAssertNil(restoredPolish.shortcut)
        let reloadedCustom = try XCTUnwrap(viewModel.transforms.first(where: { $0.id == custom.id }))
        XCTAssertEqual(reloadedCustom.shortcut?.displayString, "⌥1")
        XCTAssertTrue(viewModel.errorMessage?.contains("without conflicting shortcuts") ?? false)
    }

    func testReseedMissingBuiltInsClearsDefaultShortcutWhenReservedByAppHotkey() async throws {
        let polish = try XCTUnwrap(viewModel.transforms.first(where: { $0.name == "Polish" }))
        try await manager.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM prompts WHERE id = ?", arguments: [polish.id])
        }
        await viewModel.load()

        let reseeded = await viewModel.reseedMissingBuiltIns(
            reservedHotkeys: [
                TransformShortcutReservedHotkey(name: "hands-free dictation", trigger: .option)
            ]
        )
        XCTAssertTrue(reseeded)

        let restoredPolish = try XCTUnwrap(viewModel.transforms.first(where: { $0.name == "Polish" }))
        XCTAssertNil(restoredPolish.shortcut)
        XCTAssertTrue(viewModel.errorMessage?.contains("conflicts with hands-free dictation") ?? false)
    }
}
