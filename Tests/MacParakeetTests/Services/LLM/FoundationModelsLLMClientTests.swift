import XCTest

@testable import MacParakeetCore

final class FoundationModelsLLMClientTests: XCTestCase {
    // MARK: - Session inputs

    func testSystemMessagesBecomeInstructionsAndQuestionIsThePrompt() {
        let inputs = FoundationModelsLLMClient.buildSessionInputs(from: [
            ChatMessage(role: .system, content: "Answer from the transcript.\n\n---\nTranscript:\nSam: hello"),
            ChatMessage(role: .user, content: "hi"),
        ])

        XCTAssertEqual(inputs.instructions, "Answer from the transcript.\n\n---\nTranscript:\nSam: hello")
        // The regression: the transcript must not ride along in the prompt, or the
        // model treats the whole thing as a document and invents its own question.
        XCTAssertEqual(inputs.prompt, "hi")
    }

    func testMultipleSystemMessagesAreJoinedIntoInstructions() {
        let inputs = FoundationModelsLLMClient.buildSessionInputs(from: [
            ChatMessage(role: .system, content: "Rule one."),
            ChatMessage(role: .system, content: "Rule two."),
            ChatMessage(role: .user, content: "Q"),
        ])

        XCTAssertEqual(inputs.instructions, "Rule one.\n\nRule two.")
        XCTAssertEqual(inputs.prompt, "Q")
    }

    func testNoSystemMessageMeansNoInstructions() {
        let inputs = FoundationModelsLLMClient.buildSessionInputs(from: [
            ChatMessage(role: .user, content: "Just a question"),
        ])

        XCTAssertNil(inputs.instructions)
        XCTAssertEqual(inputs.prompt, "Just a question")
    }

    func testMultiTurnHistoryIsLabeledInThePrompt() {
        let inputs = FoundationModelsLLMClient.buildSessionInputs(from: [
            ChatMessage(role: .system, content: "Sys"),
            ChatMessage(role: .user, content: "Who spoke?"),
            ChatMessage(role: .assistant, content: "Sam and Priya."),
            ChatMessage(role: .user, content: "About what?"),
        ])

        XCTAssertEqual(inputs.instructions, "Sys")
        XCTAssertEqual(inputs.prompt, "User: Who spoke?\n\nAssistant: Sam and Priya.\n\nUser: About what?")
    }

    // MARK: - Snapshot → delta

    func testSnapshotsThatExtendProduceOnlyTheNewText() {
        var accumulator = SnapshotDeltaAccumulator()

        XCTAssertEqual(accumulator.delta(for: "Hel"), .append("Hel"))
        XCTAssertEqual(accumulator.delta(for: "Hello"), .append("lo"))
        XCTAssertEqual(accumulator.delta(for: "Hello world"), .append(" world"))
    }

    /// The observed regression: the stream re-yields the finished snapshot two or
    /// three times, and each repeat used to be re-sent in full and appended.
    func testRepeatedIdenticalSnapshotsAreIgnored() {
        var accumulator = SnapshotDeltaAccumulator()
        _ = accumulator.delta(for: "The launch is October 14th.")

        XCTAssertEqual(accumulator.delta(for: "The launch is October 14th."), .unchanged)
        XCTAssertEqual(accumulator.delta(for: "The launch is October 14th."), .unchanged)
    }

    func testJoinedDeltasEqualTheFinalReplyDespiteRepeatedSnapshots() {
        // Shape seen from the real stream: growth interleaved with identical repeats.
        let snapshots = [
            "- Billing", "- Billing slips", "- Billing slips", "- Billing slips two weeks",
            "- Billing slips two weeks", "- Billing slips two weeks", "- Billing slips two weeks",
        ]
        var accumulator = SnapshotDeltaAccumulator()
        var joined = ""
        for snapshot in snapshots {
            if case .append(let text) = accumulator.delta(for: snapshot) { joined += text }
        }

        XCTAssertEqual(joined, "- Billing slips two weeks")
    }

    func testShorterPrefixOfWhatWasSentWaitsForGrowth() {
        var accumulator = SnapshotDeltaAccumulator()
        _ = accumulator.delta(for: "Hello world")

        XCTAssertEqual(accumulator.delta(for: "Hello"), .unchanged)
        XCTAssertEqual(accumulator.delta(for: "Hello world!"), .append("!"))
    }

    func testRevisionOfSentTextIsSkippedNotResent() {
        var accumulator = SnapshotDeltaAccumulator()
        _ = accumulator.delta(for: "Hello world")

        // Deltas can't retract text already sent; re-sending it would duplicate it.
        XCTAssertEqual(accumulator.delta(for: "Howdy world"), .diverged)
        XCTAssertEqual(accumulator.emitted, "Hello world")
    }

    // MARK: - Context overflow mapping

    private enum FakeGenerationError: Error { case exceededContextWindowSize }
    private enum FakeLanguageModelError: Error { case contextSizeExceeded }

    func testContextOverflowMapsToContextTooLongAcrossOSReleases() {
        // macOS 26 wording (as reported in the app).
        let macOS26 = NSError(
            domain: "FoundationModels.LanguageModelSession.GenerationError", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Exceeded model context window size"])
        // macOS 27 wording.
        let macOS27 = NSError(
            domain: "FoundationModels.LanguageModelError", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "The session's transcript exceeded the model's context size."])

        for error in [macOS26, macOS27, FakeGenerationError.exceededContextWindowSize, FakeLanguageModelError.contextSizeExceeded] as [Error] {
            guard case .contextTooLong = FoundationModelsLLMClient.mapSessionError(error) else {
                return XCTFail("\(error) should map to contextTooLong")
            }
        }
    }

    func testOtherErrorsKeepTheirDescription() {
        let error = NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "Guardrail tripped"])

        guard case .streamingError(let detail) = FoundationModelsLLMClient.mapSessionError(error) else {
            return XCTFail("expected streamingError")
        }
        XCTAssertEqual(detail, "Guardrail tripped")
    }

    // MARK: - Budget

    func testAppleBudgetLeavesRoomForTheReplyWithinTheWindow() {
        let window = FoundationModelsLLMClient.contextWindowTokens
        let budgetChars = LLMService.appleOnDeviceContextBudget

        // At the app's conservative 3.5 chars/token, prompt + reply reserve fit the window.
        // (Tokenizer-exact fitting on top of this lives in `fitToContextWindow`.)
        let promptTokens = Int((Double(budgetChars) / 3.5).rounded(.up))
        XCTAssertLessThanOrEqual(
            promptTokens + FoundationModelsLLMClient.responseReserveTokens, window,
            "budget \(budgetChars) chars would overflow a \(window)-token window")
        // And it is far tighter than the generic local budget that caused the overflow.
        XCTAssertLessThan(budgetChars, LLMService.localContextBudget / 4)
    }
}
