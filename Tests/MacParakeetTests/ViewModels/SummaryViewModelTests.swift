import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class SummaryViewModelTests: XCTestCase {
    var viewModel: SummaryViewModel!
    var llm: MockLLMService!
    var promptRepo: MockPromptRepository!
    var summaryRepo: MockSummaryRepository!

    override func setUp() {
        viewModel = SummaryViewModel()
        llm = MockLLMService()
        promptRepo = MockPromptRepository()
        summaryRepo = MockSummaryRepository()
        promptRepo.prompts = Prompt.builtInSummaryPrompts()
    }

    func testConfigureLoadsVisiblePromptsAndDefaultSelection() {
        viewModel.configure(
            llmService: llm,
            promptRepo: promptRepo,
            summaryRepo: summaryRepo
        )

        XCTAssertEqual(viewModel.visiblePrompts.count, 7)
        XCTAssertEqual(viewModel.selectedPrompt?.name, "General Summary")
    }

    func testConfigureShowsLocalCLIPresetName() throws {
        let defaults = UserDefaults(suiteName: "test.summaryvm.localcli.\(UUID().uuidString)")!
        let cliStore = LocalCLIConfigStore(defaults: defaults)
        try cliStore.save(LocalCLIConfig(commandTemplate: "claude -p --model haiku"))

        let configStore = MockLLMConfigStore()
        configStore.config = .localCLI()

        viewModel.configure(
            llmService: llm,
            promptRepo: promptRepo,
            summaryRepo: summaryRepo,
            configStore: configStore,
            cliConfigStore: cliStore
        )

        XCTAssertEqual(viewModel.currentProviderID, .localCLI)
        XCTAssertEqual(viewModel.currentModelName, "Claude Code")
        XCTAssertEqual(viewModel.modelDisplayName, "Claude Code")
        XCTAssertEqual(viewModel.availableModels, ["Claude Code"])
    }

    func testConfigureShowsCustomCLILabel() throws {
        let defaults = UserDefaults(suiteName: "test.summaryvm.customcli.\(UUID().uuidString)")!
        let cliStore = LocalCLIConfigStore(defaults: defaults)
        try cliStore.save(LocalCLIConfig(commandTemplate: "python llm_wrapper.py"))

        let configStore = MockLLMConfigStore()
        configStore.config = .localCLI()

        viewModel.configure(
            llmService: llm,
            promptRepo: promptRepo,
            summaryRepo: summaryRepo,
            configStore: configStore,
            cliConfigStore: cliStore
        )

        XCTAssertEqual(viewModel.modelDisplayName, "Custom CLI")
        XCTAssertEqual(viewModel.availableModels, ["Custom CLI"])
    }

    func testGenerateSummaryPersistsCustomPromptAndInstructions() async throws {
        let transcriptionID = UUID()
        let prompt = Prompt(
            name: "Action Items",
            content: "Extract action items only.",
            isBuiltIn: false,
            sortOrder: 99
        )
        promptRepo.prompts.append(prompt)
        viewModel.configure(
            llmService: llm,
            promptRepo: promptRepo,
            summaryRepo: summaryRepo
        )
        viewModel.selectedPrompt = prompt
        viewModel.extraInstructions = "Return terse bullet points."
        llm.streamTokens = ["Task ", "one"]

        viewModel.generateSummary(
            transcript: "Alice will send the draft tomorrow.",
            transcriptionId: transcriptionID
        )

        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(summaryRepo.saveCalls.count, 1)
        XCTAssertEqual(summaryRepo.saveCalls[0].transcriptionId, transcriptionID)
        XCTAssertEqual(summaryRepo.saveCalls[0].promptName, "Action Items")
        XCTAssertEqual(summaryRepo.saveCalls[0].extraInstructions, "Return terse bullet points.")
        XCTAssertEqual(summaryRepo.saveCalls[0].content, "Task one")
        XCTAssertEqual(
            llm.lastSummarySystemPrompt,
            "Extract action items only.\n\nReturn terse bullet points."
        )
        XCTAssertEqual(viewModel.summaries.first?.content, "Task one")
    }

    func testGenerateSummarySetsBadgeOnlyWhenRequested() async throws {
        viewModel.configure(
            llmService: llm,
            promptRepo: promptRepo,
            summaryRepo: summaryRepo
        )
        viewModel.shouldShowBadge = { false }
        llm.streamTokens = ["Done"]

        viewModel.generateSummary(transcript: "Transcript", transcriptionId: UUID())

        try await Task.sleep(for: .milliseconds(200))

        XCTAssertFalse(viewModel.summaryBadge)

        viewModel.shouldShowBadge = { true }
        viewModel.generateSummary(transcript: "Transcript", transcriptionId: UUID())

        try await Task.sleep(for: .milliseconds(200))

        XCTAssertTrue(viewModel.summaryBadge)
        viewModel.markSummaryTabViewed()
        XCTAssertFalse(viewModel.summaryBadge)
    }

    func testLoadSummariesSwitchesTranscriptions() {
        let transcriptionA = UUID()
        let transcriptionB = UUID()
        summaryRepo.summaries = [
            Summary(
                transcriptionId: transcriptionA,
                promptName: "General Summary",
                promptContent: Prompt.defaultSummaryPrompt.content,
                content: "A1",
                createdAt: Date(timeIntervalSince1970: 10),
                updatedAt: Date(timeIntervalSince1970: 10)
            ),
            Summary(
                transcriptionId: transcriptionB,
                promptName: "General Summary",
                promptContent: Prompt.defaultSummaryPrompt.content,
                content: "B1",
                createdAt: Date(timeIntervalSince1970: 20),
                updatedAt: Date(timeIntervalSince1970: 20)
            ),
        ]
        viewModel.configure(
            llmService: llm,
            promptRepo: promptRepo,
            summaryRepo: summaryRepo
        )

        viewModel.loadSummaries(transcriptionId: transcriptionA)
        XCTAssertEqual(viewModel.summaries.map(\.content), ["A1"])

        viewModel.loadSummaries(transcriptionId: transcriptionB)
        XCTAssertEqual(viewModel.summaries.map(\.content), ["B1"])
        XCTAssertEqual(viewModel.expandedSummaryIDs.count, 1)
    }

    func testDeleteSummaryRemovesItFromState() {
        let transcriptionID = UUID()
        let summary = Summary(
            transcriptionId: transcriptionID,
            promptName: "General Summary",
            promptContent: Prompt.defaultSummaryPrompt.content,
            content: "Delete me"
        )
        summaryRepo.summaries = [summary]
        viewModel.configure(
            llmService: llm,
            promptRepo: promptRepo,
            summaryRepo: summaryRepo
        )
        viewModel.loadSummaries(transcriptionId: transcriptionID)

        viewModel.deleteSummary(summary)

        XCTAssertTrue(viewModel.summaries.isEmpty)
        XCTAssertEqual(summaryRepo.deleteCalls, [summary.id])
    }

    func testAutoSummarizeUsesGeneralSummaryPrompt() async throws {
        viewModel.configure(
            llmService: llm,
            promptRepo: promptRepo,
            summaryRepo: summaryRepo
        )
        llm.streamTokens = ["Auto"]
        let longTranscript = String(repeating: "word ", count: 200)

        viewModel.autoSummarize(transcript: longTranscript, transcriptionId: UUID())

        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(llm.lastSummarySystemPrompt, Prompt.defaultSummaryPrompt.content)
        XCTAssertEqual(summaryRepo.saveCalls.count, 1)
    }
}
