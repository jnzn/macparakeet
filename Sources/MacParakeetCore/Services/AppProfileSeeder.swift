import Foundation

/// One-time first-run seeding of the `app_profile` table.
///
/// Precedence: a build-bundled local seed (the user's real prompts, gitignored
/// in-repo and copied into Resources/ProfileSeeds at build time) wins; otherwise
/// the generic `AppProfile.defaults` shipped in the repo are used. No-op once the
/// table has any rows, so user edits are never clobbered.
public enum AppProfileSeeder {
    /// URL of the bundled seed inside the app, or nil. Computed by the app layer:
    /// `Bundle.main.url(forResource: "app-profiles", withExtension: "json", subdirectory: "ProfileSeeds")`.
    public static func seedIfEmpty(
        repository: AppProfileRepositoryProtocol,
        bundledSeedURL: URL?
    ) throws {
        guard try repository.fetchAll().isEmpty else { return }

        let seeds: [AppProfile]
        if let url = bundledSeedURL,
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([AppProfile].self, from: data),
           !decoded.isEmpty {
            seeds = decoded
        } else {
            seeds = AppProfile.defaults
        }

        for profile in seeds {
            try repository.save(profile)
        }
    }
}
