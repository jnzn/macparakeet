import ArgumentParser
import XCTest
@testable import MacParakeetCore
@testable import CLI

final class ModelLifecycleCommandTests: XCTestCase {
    func testValidatedAttemptsRejectsZero() {
        XCTAssertThrowsError(try validatedAttempts(0)) { error in
            XCTAssertTrue(error is ValidationError)
        }
    }

    func testValidatedAttemptsAcceptsPositiveValues() throws {
        XCTAssertEqual(try validatedAttempts(1), 1)
        XCTAssertEqual(try validatedAttempts(5), 5)
    }

    func testModelsStatusParsesTarget() throws {
        let command = try ModelsCommand.Status.parse(["--target", "llm"])
        XCTAssertEqual(command.target, .llm)
    }

    func testModelsWarmUpParsesTargetAndAttempts() throws {
        let command = try ModelsCommand.WarmUp.parse(["--target", "stt", "--attempts", "4"])
        XCTAssertEqual(command.target, .stt)
        XCTAssertEqual(command.attempts, 4)
    }

    func testModelsRepairDefaultsToAllAndThreeAttempts() throws {
        let command = try ModelsCommand.Repair.parse([])
        XCTAssertEqual(command.target, .all)
        XCTAssertEqual(command.attempts, 3)
    }

    func testHealthParsesRepairFlags() throws {
        let command = try HealthCommand.parse(["--repair-models", "--repair-attempts", "6"])
        XCTAssertTrue(command.repairModels)
        XCTAssertEqual(command.repairAttempts, 6)
    }

    func testWarmUpAllAttemptsBothModelsEvenWhenFirstFails() async {
        let stt = StubSTTClient()
        let llm = StubLLMService()
        await stt.setAlwaysFail(true)
        await llm.setAlwaysFail(false)

        do {
            try await warmUpModels(
                target: .all,
                attempts: 1,
                sttClient: stt,
                llmService: llm,
                log: { _ in }
            )
            XCTFail("Expected .all warm-up to throw when one model fails")
        } catch {
            // expected
        }

        let sttCalls = await stt.warmUpCalls
        let llmCalls = await llm.warmUpCalls
        XCTAssertEqual(sttCalls, 1)
        XCTAssertEqual(llmCalls, 1)
    }

    func testWarmUpRetriesConfiguredAttempts() async {
        let stt = StubSTTClient()
        let llm = StubLLMService()
        await stt.setFailuresBeforeSuccess(2)

        do {
            try await warmUpModels(
                target: .stt,
                attempts: 3,
                sttClient: stt,
                llmService: llm,
                log: { _ in }
            )
        } catch {
            XCTFail("Expected warm-up to succeed after retries, got \(error)")
        }

        let sttCalls = await stt.warmUpCalls
        XCTAssertEqual(sttCalls, 3)
    }
}

private actor StubSTTClient: STTClientProtocol {
    private(set) var warmUpCalls = 0
    private var alwaysFail = false
    private var failuresBeforeSuccess = 0
    private var ready = false

    func setAlwaysFail(_ value: Bool) {
        alwaysFail = value
    }

    func setFailuresBeforeSuccess(_ count: Int) {
        failuresBeforeSuccess = max(0, count)
    }

    func transcribe(audioPath: String, onProgress: (@Sendable (Int, Int) -> Void)?) async throws -> STTResult {
        STTResult(text: "", words: [])
    }

    func warmUp(onProgress: (@Sendable (String) -> Void)?) async throws {
        warmUpCalls += 1
        if alwaysFail {
            throw STTError.engineStartFailed("forced failure")
        }
        if failuresBeforeSuccess > 0 {
            failuresBeforeSuccess -= 1
            throw STTError.engineStartFailed("transient failure")
        }
        ready = true
    }

    func isReady() async -> Bool {
        ready
    }

    func shutdown() async {}
}

private actor StubLLMService: LLMServiceProtocol {
    private(set) var warmUpCalls = 0
    private var alwaysFail = false
    private var ready = false

    func setAlwaysFail(_ value: Bool) {
        alwaysFail = value
    }

    func generate(request: LLMRequest) async throws -> LLMResponse {
        if alwaysFail {
            throw LLMServiceError.generationFailed("forced failure")
        }
        ready = true
        return LLMResponse(text: "OK", modelID: "stub", durationSeconds: 0.01)
    }

    func warmUp() async throws {
        warmUpCalls += 1
        if alwaysFail {
            throw LLMServiceError.generationFailed("forced failure")
        }
        ready = true
    }

    func isReady() async -> Bool {
        ready
    }
}
