import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class DictationHistoryViewModelTests: XCTestCase {
    var viewModel: DictationHistoryViewModel!
    var mockRepo: MockDictationRepository!

    override func setUp() {
        mockRepo = MockDictationRepository()
        viewModel = DictationHistoryViewModel()
    }

    // MARK: - Fetching

    func testConfigureLoadsDictations() {
        let dictation = Dictation(
            durationMs: 1000,
            rawTranscript: "Hello world"
        )
        mockRepo.dictations = [dictation]

        viewModel.configure(dictationRepo: mockRepo)

        XCTAssertEqual(viewModel.groupedDictations.count, 1, "Should have one date group")
        XCTAssertEqual(viewModel.groupedDictations[0].1.count, 1, "Group should have one dictation")
        XCTAssertEqual(viewModel.groupedDictations[0].1[0].rawTranscript, "Hello world")
    }

    func testEmptyRepoResultsInEmptyList() {
        viewModel.configure(dictationRepo: mockRepo)

        XCTAssertTrue(viewModel.groupedDictations.isEmpty)
    }

    func testMultipleDictationsGroupedByDate() {
        let today = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        let twoDaysAgo = Calendar.current.date(byAdding: .day, value: -2, to: today)!

        mockRepo.dictations = [
            Dictation(createdAt: today, durationMs: 1000, rawTranscript: "Today's dictation"),
            Dictation(createdAt: yesterday, durationMs: 2000, rawTranscript: "Yesterday's dictation"),
            Dictation(createdAt: twoDaysAgo, durationMs: 3000, rawTranscript: "Older dictation"),
        ]

        viewModel.configure(dictationRepo: mockRepo)

        XCTAssertEqual(viewModel.groupedDictations.count, 3, "Should have three date groups")
        // Groups are sorted newest first
        XCTAssertEqual(viewModel.groupedDictations[0].0, "Today")
        XCTAssertEqual(viewModel.groupedDictations[1].0, "Yesterday")
    }

    func testTodayGroupHeader() {
        mockRepo.dictations = [
            Dictation(createdAt: Date(), durationMs: 500, rawTranscript: "Now")
        ]

        viewModel.configure(dictationRepo: mockRepo)

        XCTAssertEqual(viewModel.groupedDictations[0].0, "Today")
    }

    func testYesterdayGroupHeader() {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        mockRepo.dictations = [
            Dictation(createdAt: yesterday, durationMs: 500, rawTranscript: "Yesterday entry")
        ]

        viewModel.configure(dictationRepo: mockRepo)

        XCTAssertEqual(viewModel.groupedDictations[0].0, "Yesterday")
    }

    func testMultipleDictationsSameDayGroupedTogether() {
        let now = Date()
        let earlier = now.addingTimeInterval(-3600) // 1 hour ago

        mockRepo.dictations = [
            Dictation(createdAt: now, durationMs: 1000, rawTranscript: "First"),
            Dictation(createdAt: earlier, durationMs: 2000, rawTranscript: "Second"),
        ]

        viewModel.configure(dictationRepo: mockRepo)

        XCTAssertEqual(viewModel.groupedDictations.count, 1, "Same day should be one group")
        XCTAssertEqual(viewModel.groupedDictations[0].1.count, 2, "Group should have two dictations")
        // Within a group, sorted by createdAt descending
        XCTAssertEqual(viewModel.groupedDictations[0].1[0].rawTranscript, "First")
        XCTAssertEqual(viewModel.groupedDictations[0].1[1].rawTranscript, "Second")
    }

    // MARK: - Search

    func testSearchFiltersDictations() {
        mockRepo.dictations = [
            Dictation(durationMs: 1000, rawTranscript: "The quick brown fox"),
            Dictation(durationMs: 1000, rawTranscript: "Hello world"),
            Dictation(durationMs: 1000, rawTranscript: "Goodbye world"),
        ]

        viewModel.configure(dictationRepo: mockRepo)
        XCTAssertEqual(totalDictationCount(), 3, "Before search, all three should be loaded")

        viewModel.searchText = "world"

        XCTAssertEqual(totalDictationCount(), 2, "Should match two dictations containing 'world'")
    }

    func testClearSearchShowsAll() {
        mockRepo.dictations = [
            Dictation(durationMs: 1000, rawTranscript: "The quick brown fox"),
            Dictation(durationMs: 1000, rawTranscript: "Hello world"),
        ]

        viewModel.configure(dictationRepo: mockRepo)
        viewModel.searchText = "fox"
        XCTAssertEqual(totalDictationCount(), 1)

        viewModel.searchText = ""
        XCTAssertEqual(totalDictationCount(), 2, "Clearing search should show all dictations")
    }

    func testSearchNoResults() {
        mockRepo.dictations = [
            Dictation(durationMs: 1000, rawTranscript: "Hello world"),
        ]

        viewModel.configure(dictationRepo: mockRepo)
        viewModel.searchText = "nonexistent"

        XCTAssertTrue(viewModel.groupedDictations.isEmpty, "No results for unmatched search")
    }

    // MARK: - Delete

    func testDeleteRemovesFromList() {
        let dictation = Dictation(durationMs: 1000, rawTranscript: "To be deleted")
        mockRepo.dictations = [dictation]

        viewModel.configure(dictationRepo: mockRepo)
        XCTAssertEqual(totalDictationCount(), 1)

        viewModel.deleteDictation(dictation)

        XCTAssertTrue(viewModel.groupedDictations.isEmpty, "List should be empty after deletion")
        XCTAssertTrue(mockRepo.deleteCalledWith.contains(dictation.id))
    }

    func testDeleteClearsSelectedDictation() {
        let dictation = Dictation(durationMs: 1000, rawTranscript: "Selected one")
        mockRepo.dictations = [dictation]

        viewModel.configure(dictationRepo: mockRepo)
        viewModel.selectedDictation = dictation

        XCTAssertNotNil(viewModel.selectedDictation)

        viewModel.deleteDictation(dictation)

        XCTAssertNil(viewModel.selectedDictation, "Deleting the selected dictation should clear selection")
    }

    func testDeleteDoesNotClearUnrelatedSelection() {
        let dictation1 = Dictation(durationMs: 1000, rawTranscript: "First")
        let dictation2 = Dictation(durationMs: 2000, rawTranscript: "Second")
        mockRepo.dictations = [dictation1, dictation2]

        viewModel.configure(dictationRepo: mockRepo)
        viewModel.selectedDictation = dictation1

        viewModel.deleteDictation(dictation2)

        XCTAssertNotNil(viewModel.selectedDictation, "Deleting a different dictation should not clear selection")
        XCTAssertEqual(viewModel.selectedDictation?.id, dictation1.id)
    }

    // MARK: - Unconfigured

    func testLoadDictationsBeforeConfigureIsNoOp() {
        viewModel.loadDictations()
        XCTAssertTrue(viewModel.groupedDictations.isEmpty, "Should be empty when no repo configured")
    }

    func testDeleteBeforeConfigureIsNoOp() {
        let dictation = Dictation(durationMs: 1000, rawTranscript: "Test")
        // Should not crash
        viewModel.deleteDictation(dictation)
        XCTAssertTrue(viewModel.groupedDictations.isEmpty)
    }

    // MARK: - Helpers

    private func totalDictationCount() -> Int {
        viewModel.groupedDictations.reduce(0) { $0 + $1.1.count }
    }
}
