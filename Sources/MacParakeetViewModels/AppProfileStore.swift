import Foundation
import os
import MacParakeetCore

/// Thread-safe snapshot of the resolved profile list for the `@Sendable`
/// dictation resolve closure (which runs off the main actor).
public final class AppProfileSnapshot: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [AppProfile]())

    fileprivate func set(_ profiles: [AppProfile]) {
        lock.withLock { $0 = profiles }
    }

    public func resolve(bundleID: String?) -> AppProfile? {
        lock.withLock { AppProfile.resolve(bundleID: bundleID, from: $0) }
    }
}

/// Single source of truth for per-app profiles. The `@Observable` `profiles`
/// array drives the editor; `snapshot` feeds dictation resolution. Every
/// write-through CRUD op updates both atomically.
@MainActor
@Observable
public final class AppProfileStore {
    public private(set) var profiles: [AppProfile] = []
    public let snapshot = AppProfileSnapshot()

    private let repository: AppProfileRepositoryProtocol

    public init(repository: AppProfileRepositoryProtocol) {
        self.repository = repository
    }

    public func load() {
        do {
            profiles = try repository.fetchAll()
        } catch {
            profiles = []
        }
        snapshot.set(profiles)
    }

    /// Insert or update, then re-sort by sortOrder and refresh both faces.
    public func upsert(_ profile: AppProfile) {
        try? repository.save(profile)
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
        } else {
            profiles.append(profile)
        }
        profiles.sort { ($0.sortOrder, $0.displayName) < ($1.sortOrder, $1.displayName) }
        snapshot.set(profiles)
    }

    public func delete(id: String) {
        try? repository.delete(id: id)
        profiles.removeAll { $0.id == id }
        snapshot.set(profiles)
    }
}
