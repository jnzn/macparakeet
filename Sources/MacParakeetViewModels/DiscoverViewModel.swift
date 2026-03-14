import Foundation
import MacParakeetCore

@MainActor
@Observable
public final class DiscoverViewModel {
    public var feed: DiscoverFeed?

    public var featuredItem: DiscoverItem? {
        feed?.featuredItem
    }

    public var allItems: [DiscoverItem] {
        feed?.items ?? []
    }

    private var service: (any DiscoverServiceProtocol)?
    private var loadTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    public init() {}

    public func configure(service: any DiscoverServiceProtocol) {
        self.service = service
    }

    public func loadCached() {
        guard let service else { return }
        loadTask?.cancel()
        loadTask = Task {
            let result = await service.loadContent()
            guard !Task.isCancelled else { return }
            feed = result
            loadTask = nil
        }
    }

    public func refreshInBackground() {
        guard let service else { return }
        refreshTask?.cancel()
        refreshTask = Task {
            if let freshFeed = await service.fetchFresh() {
                guard !Task.isCancelled else { return }
                feed = freshFeed
            }
            refreshTask = nil
        }
    }
}
