import Foundation

/// First-run seeding + one-time version-bump re-seed of the `app_profile` table.
///
/// `seedIfEmpty`: seeds an empty table (bundled local seed wins over generics)
/// and records the seed version, so user edits are never clobbered on later runs.
///
/// `reseedIfVersionOutdated`: when the bundled seed set changes shape (e.g. the
/// 11→7 category reorg), bump `currentSeedVersion`. On launch, an already-populated
/// DB whose stored version is older is **replaced** with the current seed set. This
/// is a deliberate clobber tied to a version bump (the originals are archived in the
/// vault); it does not run on every launch.
public enum AppProfileSeeder {
    /// Bump whenever the bundled/generic seed set is intentionally reshaped.
    /// v2 = the 11→7 category consolidation.
    public static let currentSeedVersion = 2
    public static let seedVersionDefaultsKey = "appProfileSeedVersion"

    /// URL of the bundled seed inside the app, or nil. Computed by the app layer:
    /// `Bundle.main.url(forResource: "app-profiles", withExtension: "json", subdirectory: "ProfileSeeds")`.
    public static func seedIfEmpty(
        repository: AppProfileRepositoryProtocol,
        bundledSeedURL: URL?,
        defaults: UserDefaults = .standard
    ) throws {
        guard try repository.fetchAll().isEmpty else { return }
        for profile in resolveSeeds(bundledSeedURL) {
            try repository.save(profile)
        }
        defaults.set(currentSeedVersion, forKey: seedVersionDefaultsKey)
    }

    /// One-time replace when the bundled seed set has been reshaped (version bump).
    /// No-op when the stored version is current, or when the table is empty
    /// (`seedIfEmpty` already handled that and recorded the version).
    public static func reseedIfVersionOutdated(
        repository: AppProfileRepositoryProtocol,
        bundledSeedURL: URL?,
        defaults: UserDefaults = .standard
    ) throws {
        let stored = defaults.integer(forKey: seedVersionDefaultsKey)  // 0 if missing
        guard stored < currentSeedVersion else { return }
        let existing = try repository.fetchAll()
        guard !existing.isEmpty else { return }
        for p in existing { _ = try repository.delete(id: p.id) }
        for profile in resolveSeeds(bundledSeedURL) {
            try repository.save(profile)
        }
        defaults.set(currentSeedVersion, forKey: seedVersionDefaultsKey)
    }

    /// Bundled local seed (the user's real prompts) wins; otherwise generic defaults.
    private static func resolveSeeds(_ bundledSeedURL: URL?) -> [AppProfile] {
        if let url = bundledSeedURL,
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([AppProfile].self, from: data),
           !decoded.isEmpty {
            return decoded
        }
        return AppProfile.defaults
    }
}
