import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class TextSnippetsViewModelTests: XCTestCase {
    var viewModel: TextSnippetsViewModel!
    var mockRepo: MockTextSnippetRepository!

    override func setUp() async throws {
        mockRepo = MockTextSnippetRepository()
        viewModel = TextSnippetsViewModel()
        viewModel.configure(repo: mockRepo)
    }

    func testInitialState() {
        XCTAssertTrue(viewModel.snippets.isEmpty)
        XCTAssertEqual(viewModel.searchText, "")
        XCTAssertEqual(viewModel.newTrigger, "")
        XCTAssertEqual(viewModel.newExpansion, "")
        XCTAssertNil(viewModel.errorMessage)
    }

    func testAddSnippet() {
        viewModel.newTrigger = "my signature"
        viewModel.newExpansion = "Best regards, David"
        viewModel.addSnippet()

        XCTAssertEqual(viewModel.snippets.count, 1)
        XCTAssertEqual(viewModel.snippets.first?.trigger, "my signature")
        XCTAssertEqual(viewModel.snippets.first?.expansion, "Best regards, David")
        XCTAssertEqual(viewModel.newTrigger, "")
        XCTAssertEqual(viewModel.newExpansion, "")
    }

    func testAddEmptyTriggerIgnored() {
        viewModel.newTrigger = "  "
        viewModel.newExpansion = "something"
        viewModel.addSnippet()

        XCTAssertTrue(viewModel.snippets.isEmpty)
    }

    func testAddEmptyExpansionIgnored() {
        viewModel.newTrigger = "test"
        viewModel.newExpansion = "  "
        viewModel.addSnippet()

        XCTAssertTrue(viewModel.snippets.isEmpty)
    }

    func testAddDuplicateShowsError() {
        viewModel.newTrigger = "my sig"
        viewModel.newExpansion = "Sincerely"
        viewModel.addSnippet()
        XCTAssertNil(viewModel.errorMessage)

        viewModel.newTrigger = "MY SIG"
        viewModel.newExpansion = "Different"
        viewModel.addSnippet()
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.snippets.count, 1)
    }

    func testToggleEnabled() {
        viewModel.newTrigger = "test"
        viewModel.newExpansion = "expansion"
        viewModel.addSnippet()
        XCTAssertTrue(viewModel.snippets.first?.isEnabled ?? false)

        viewModel.toggleEnabled(viewModel.snippets.first!)
        XCTAssertFalse(viewModel.snippets.first?.isEnabled ?? true)
    }

    func testDeleteSnippet() {
        viewModel.newTrigger = "test"
        viewModel.newExpansion = "expansion"
        viewModel.addSnippet()
        XCTAssertEqual(viewModel.snippets.count, 1)

        viewModel.deleteSnippet(viewModel.snippets.first!)
        XCTAssertTrue(viewModel.snippets.isEmpty)
    }

    func testFilteredSnippets() {
        viewModel.newTrigger = "my signature"
        viewModel.newExpansion = "Best regards"
        viewModel.addSnippet()

        viewModel.newTrigger = "my address"
        viewModel.newExpansion = "123 Main St"
        viewModel.addSnippet()

        viewModel.searchText = "sig"
        XCTAssertEqual(viewModel.filteredSnippets.count, 1)
        XCTAssertEqual(viewModel.filteredSnippets.first?.trigger, "my signature")
    }

    func testAddSnippetWithNewlineToken() {
        viewModel.newTrigger = "new paragraph"
        viewModel.newExpansion = "\\n\\n"
        viewModel.addSnippet()

        XCTAssertEqual(viewModel.snippets.count, 1)
        XCTAssertEqual(viewModel.snippets.first?.expansion, "\n\n")
    }

    func testAddSnippetWithMixedNewlineToken() {
        viewModel.newTrigger = "my address"
        viewModel.newExpansion = "123 Main St\\nCity"
        viewModel.addSnippet()

        XCTAssertEqual(viewModel.snippets.count, 1)
        XCTAssertEqual(viewModel.snippets.first?.expansion, "123 Main St\nCity")
    }

    func testAddSnippetNewlineOnlyExpansion() {
        viewModel.newTrigger = "new line"
        viewModel.newExpansion = "\\n"
        viewModel.addSnippet()

        XCTAssertEqual(viewModel.snippets.count, 1)
        XCTAssertEqual(viewModel.snippets.first?.expansion, "\n")
    }

    func testFilteredSnippetsEmptySearch() {
        viewModel.newTrigger = "test"
        viewModel.newExpansion = "expansion"
        viewModel.addSnippet()

        viewModel.searchText = ""
        XCTAssertEqual(viewModel.filteredSnippets.count, 1)
    }

    // MARK: - Keystroke Action Snippets

    func testAddKeystrokeSnippet() {
        viewModel.newTrigger = "press return"
        viewModel.newSnippetIsKeystroke = true
        viewModel.newKeystrokeAction = .returnKey
        viewModel.addSnippet()

        XCTAssertEqual(viewModel.snippets.count, 1)
        XCTAssertEqual(viewModel.snippets.first?.action, .returnKey)
        XCTAssertEqual(viewModel.snippets.first?.trigger, "press return")
        // State reset after add
        XCTAssertEqual(viewModel.newTrigger, "")
        XCTAssertFalse(viewModel.newSnippetIsKeystroke)
    }

    func testDuplicateTriggerAcrossTypes() {
        // Add a text snippet with trigger "return"
        viewModel.newTrigger = "return"
        viewModel.newExpansion = "some text"
        viewModel.addSnippet()
        XCTAssertEqual(viewModel.snippets.count, 1)

        // Try to add a keystroke snippet with same trigger — should fail
        viewModel.newTrigger = "return"
        viewModel.newSnippetIsKeystroke = true
        viewModel.newKeystrokeAction = .returnKey
        viewModel.addSnippet()
        XCTAssertEqual(viewModel.snippets.count, 1)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    func testKeystrokeSnippetDoesNotRequireExpansion() {
        viewModel.newTrigger = "hit return"
        viewModel.newSnippetIsKeystroke = true
        viewModel.newKeystrokeAction = .returnKey
        viewModel.newExpansion = ""  // Expansion is empty but should not matter
        viewModel.addSnippet()

        XCTAssertEqual(viewModel.snippets.count, 1)
        XCTAssertEqual(viewModel.snippets.first?.action, .returnKey)
    }
}
