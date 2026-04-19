import Foundation
import XCTest
@testable import MacParakeetCore

final class OllamaReachabilityTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        ReachabilityMockURLProtocol.requestHandler = nil
    }

    // MARK: - Success cases

    func testCheckReturnsModelNamesOnHTTP200JSON() async throws {
        let session = makeSession()
        ReachabilityMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.absoluteString, "http://localhost:11434/api/tags")
            XCTAssertEqual(request.httpMethod, "GET")
            let body = """
                {"models":[
                    {"name":"llama3.2:1b"},
                    {"name":"qwen2.5:7b"}
                ]}
                """.data(using: .utf8)!
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, body)
        }

        let result = await OllamaReachability.check(
            baseURL: URL(string: "http://localhost:11434")!,
            session: session
        )

        XCTAssertEqual(try result.get(), ["llama3.2:1b", "qwen2.5:7b"])
    }

    func testCheckSucceedsWithEmptyModelList() async throws {
        let session = makeSession()
        ReachabilityMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"models":[]}"#.utf8))
        }

        let result = await OllamaReachability.check(
            baseURL: URL(string: "http://localhost:11434")!,
            session: session
        )

        XCTAssertEqual(try result.get(), [])
    }

    func testCheckStripsV1SuffixBeforeAppendingTagsPath() async throws {
        let session = makeSession()
        ReachabilityMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.absoluteString, "http://studio.local:11434/api/tags")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"models":[]}"#.utf8))
        }

        _ = await OllamaReachability.check(
            baseURL: URL(string: "http://studio.local:11434/v1")!,
            session: session
        )
    }

    // MARK: - Failure cases

    func testCheckReturnsParseErrorOnMalformedJSON() async {
        let session = makeSession()
        ReachabilityMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data("not json".utf8))
        }

        let result = await OllamaReachability.check(
            baseURL: URL(string: "http://localhost:11434")!,
            session: session
        )

        guard case .failure(let error) = result else {
            XCTFail("Expected failure, got \(result)")
            return
        }
        XCTAssertEqual(error, .parse)
    }

    func testCheckReturnsHTTPErrorOnNon2xxStatus() async {
        let session = makeSession()
        ReachabilityMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 404,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        let result = await OllamaReachability.check(
            baseURL: URL(string: "http://localhost:11434")!,
            session: session
        )

        guard case .failure(let error) = result else {
            XCTFail("Expected failure, got \(result)")
            return
        }
        XCTAssertEqual(error, .http(404))
    }

    func testCheckMapsConnectionRefusedToConnectionRefusedError() async {
        let session = makeSession()
        ReachabilityMockURLProtocol.requestHandler = { _ in
            throw URLError(.cannotConnectToHost)
        }

        let result = await OllamaReachability.check(
            baseURL: URL(string: "http://localhost:11434")!,
            session: session
        )

        guard case .failure(let error) = result else {
            XCTFail("Expected failure, got \(result)")
            return
        }
        XCTAssertEqual(error, .connectionRefused)
    }

    func testCheckMapsTimeoutToTimeoutError() async {
        let session = makeSession()
        ReachabilityMockURLProtocol.requestHandler = { _ in
            throw URLError(.timedOut)
        }

        let result = await OllamaReachability.check(
            baseURL: URL(string: "http://localhost:11434")!,
            session: session
        )

        guard case .failure(let error) = result else {
            XCTFail("Expected failure, got \(result)")
            return
        }
        XCTAssertEqual(error, .timeout)
    }

    // MARK: - Helpers

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReachabilityMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class ReachabilityMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

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
