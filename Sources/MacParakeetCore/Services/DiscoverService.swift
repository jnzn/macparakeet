import Foundation
import OSLog

// MARK: - Protocol

public protocol DiscoverServiceProtocol: Sendable {
    func loadContent() async -> DiscoverFeed
    func fetchFresh() async -> DiscoverFeed?
}

// MARK: - Implementation

public final class DiscoverService: DiscoverServiceProtocol {
    private let feedURL: URL
    private let cachePath: String
    private let fallbackData: Data
    private let session: URLSession
    private let log = Logger(subsystem: "com.macparakeet.app", category: "DiscoverService")

    public init(
        feedURL: URL? = nil,
        cachePath: String? = nil,
        fallbackData: Data,
        session: URLSession = .shared
    ) {
        if let feedURL {
            self.feedURL = feedURL
        } else if let envURL = ProcessInfo.processInfo.environment["MACPARAKEET_DISCOVER_URL"],
                  let url = URL(string: envURL) {
            self.feedURL = url
        } else {
            self.feedURL = URL(string: "https://macparakeet.com/api/discover.json")!
        }
        self.cachePath = cachePath ?? AppPaths.discoverCachePath
        self.fallbackData = fallbackData
        self.session = session
    }

    private var cacheURL: URL { URL(fileURLWithPath: cachePath) }

    public func loadContent() async -> DiscoverFeed {
        // Try cache first
        if let data = try? Data(contentsOf: cacheURL),
           let feed = try? JSONDecoder().decode(DiscoverFeed.self, from: data) {
            return feed
        }

        // Fall back to bundled data
        if let feed = try? JSONDecoder().decode(DiscoverFeed.self, from: fallbackData) {
            return feed
        }

        // Empty feed as last resort
        log.warning("Failed to decode both cache and fallback data")
        return DiscoverFeed(version: 0, items: [])
    }

    public func fetchFresh() async -> DiscoverFeed? {
        do {
            var request = URLRequest(url: feedURL, timeoutInterval: 10)
            request.httpMethod = "GET"
            let (data, response) = try await session.data(for: request)

            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                log.warning("Discover feed fetch returned non-200 status")
                return nil
            }

            let feed = try JSONDecoder().decode(DiscoverFeed.self, from: data)

            // Write to cache
            try? FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: cacheURL, options: .atomic)

            return feed
        } catch {
            log.warning("Failed to fetch discover feed: \(error.localizedDescription)")
            return nil
        }
    }
}
