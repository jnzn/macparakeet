import Foundation

/// Lightweight probe used by onboarding (and any future "is Ollama up?" UI)
/// to detect a reachable Ollama daemon and enumerate its installed models.
///
/// Hits `GET <baseURL>/api/tags`. A successful response is HTTP 200 with a
/// JSON body shaped `{"models":[{"name":"<tag>"},...]}`. Empty `models` is
/// still a success — the daemon is reachable, the user just hasn't pulled
/// any models yet.
public enum OllamaReachability {
    public enum ProbeError: Error, Equatable, Sendable {
        case invalidURL
        case timeout
        case connectionRefused
        case http(Int)
        case parse
        case other(String)
    }

    /// Probes the daemon and returns the list of installed model tags on success.
    /// `timeout` clamps the per-request wait — keep it short (2-3s) so the
    /// onboarding card doesn't feel stuck when the daemon isn't running.
    public static func check(
        baseURL: URL,
        session: URLSession = .shared,
        timeout: TimeInterval = 2.5
    ) async -> Result<[String], ProbeError> {
        guard let url = tagsURL(from: baseURL) else {
            return .failure(.invalidURL)
        }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            return .failure(map(urlError: urlError))
        } catch {
            return .failure(.other(error.localizedDescription))
        }

        guard let http = response as? HTTPURLResponse else {
            return .failure(.other("Invalid response."))
        }
        guard (200...299).contains(http.statusCode) else {
            return .failure(.http(http.statusCode))
        }

        guard let decoded = try? JSONDecoder().decode(TagsResponse.self, from: data) else {
            return .failure(.parse)
        }

        let names = decoded.models
            .map(\.name)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return .success(names)
    }

    /// Strips a trailing `/v1` (LLM-config-store convention) and appends
    /// `api/tags`. Returns nil if the input doesn't normalize to a valid URL.
    static func tagsURL(from baseURL: URL) -> URL? {
        var baseString = baseURL.absoluteString
        if baseString.hasSuffix("/v1") {
            baseString = String(baseString.dropLast(3))
        } else if baseString.hasSuffix("/v1/") {
            baseString = String(baseString.dropLast(4))
        }
        guard let normalized = URL(string: baseString) else {
            return nil
        }
        return normalized.appendingPathComponent("api/tags")
    }

    private static func map(urlError: URLError) -> ProbeError {
        switch urlError.code {
        case .timedOut:
            return .timeout
        case .cannotConnectToHost,
             .cannotFindHost,
             .networkConnectionLost,
             .notConnectedToInternet,
             .dnsLookupFailed:
            return .connectionRefused
        default:
            return .other(urlError.localizedDescription)
        }
    }
}

private struct TagsResponse: Decodable {
    let models: [Model]

    struct Model: Decodable {
        let name: String
    }
}
