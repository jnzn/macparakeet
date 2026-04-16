import Foundation
import XCTest
@testable import MacParakeetCore

final class AIAssistantOllamaExecutorTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        MockURLProtocol.requestHandler = nil
    }

    func testExecuteUsesConfiguredOllamaEndpointAndStripsThinkingTags() async throws {
        let configStore = OllamaExecutorConfigStoreStub(
            config: LLMProviderConfig.ollama(
                model: "gemma4:e2b",
                baseURL: URL(string: "http://studio.local:11434/v1")!
            )
        )
        let session = makeSession()

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.absoluteString, "http://studio.local:11434/api/chat")
            XCTAssertEqual(request.httpMethod, "POST")

            let body = try XCTUnwrap(self.requestBody(from: request))
            let payload = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertEqual(payload["model"] as? String, "gemma4:e2b")
            XCTAssertEqual(payload["stream"] as? Bool, false)
            XCTAssertEqual(payload["think"] as? Bool, false)
            XCTAssertEqual(payload["keep_alive"] as? String, "5m")

            let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
            XCTAssertEqual(messages.count, 2)
            XCTAssertEqual(messages[0]["role"] as? String, "system")
            XCTAssertEqual(messages[0]["content"] as? String, "system prompt")
            XCTAssertEqual(messages[1]["role"] as? String, "user")
            XCTAssertEqual(messages[1]["content"] as? String, "user prompt")

            let responseBody = """
                {
                  "model": "gemma4:e2b",
                  "message": {
                    "role": "assistant",
                    "content": "<think>internal reasoning</think>final answer"
                  }
                }
                """.data(using: .utf8)!
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, responseBody)
        }

        let executor = AIAssistantOllamaExecutor(
            configStore: configStore,
            session: session
        )

        let output = try await executor.execute(
            systemPrompt: "system prompt",
            userPrompt: "user prompt",
            config: LocalCLIConfig(commandTemplate: "ignored", timeoutSeconds: 42)
        )

        XCTAssertEqual(output, "final answer")
    }

    func testExecuteThrowsHelpfulErrorWhenOllamaIsNotConfigured() async {
        let executor = AIAssistantOllamaExecutor(
            configStore: OllamaExecutorConfigStoreStub(config: nil),
            session: makeSession()
        )

        do {
            _ = try await executor.execute(
                systemPrompt: "system",
                userPrompt: "user",
                config: LocalCLIConfig(commandTemplate: "ignored")
            )
            XCTFail("Expected notConfigured error")
        } catch let error as AIAssistantOllamaExecutorError {
            XCTAssertEqual(
                error.localizedDescription,
                "Ollama isn't configured. Open Settings -> AI Provider to set the URL and model."
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func requestBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }

        return data.isEmpty ? nil : data
    }
}

private final class OllamaExecutorConfigStoreStub: LLMConfigStoreProtocol, @unchecked Sendable {
    let config: LLMProviderConfig?

    init(config: LLMProviderConfig?) {
        self.config = config
    }

    func loadConfig() throws -> LLMProviderConfig? { config }
    func saveConfig(_ config: LLMProviderConfig) throws {}
    func deleteConfig() throws {}
    func loadAPIKey() throws -> String? { nil }
    func loadAPIKey(for provider: LLMProviderID) throws -> String? { nil }
    func saveAPIKey(_ key: String) throws {}
    func deleteAPIKey() throws {}
    func updateModelName(_ modelName: String) throws {}
}

private final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
