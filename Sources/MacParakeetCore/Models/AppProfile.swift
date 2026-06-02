import Foundation

/// A per-app customization for dictation cleanup. Resolved once at the start of
/// a dictation based on the frontmost app's bundle identifier, then used for
/// both live-bubble cleanup and the paste-path LLM polish (when enabled).
public struct AppProfile: Equatable, Sendable, Identifiable, Codable {
    public let id: String
    public var displayName: String
    /// Bundle identifiers this profile applies to. First profile with a match wins.
    public var bundleIDs: [String]
    /// Full LLM prompt template (uses `{{TRANSCRIPT}}` placeholder) to use instead
    /// of the user-configured default. Nil falls back to the default formatter prompt.
    public var promptOverride: String?
    public var enabled: Bool
    /// Stable ordering for the editor tab strip and first-match resolution.
    public var sortOrder: Int

    public init(
        id: String,
        displayName: String,
        bundleIDs: [String],
        promptOverride: String?,
        enabled: Bool = true,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.displayName = displayName
        self.bundleIDs = bundleIDs
        self.promptOverride = promptOverride
        self.enabled = enabled
        self.sortOrder = sortOrder
    }

    /// First enabled profile in `profiles` whose `bundleIDs` contains `bundleID`,
    /// or nil if no match.
    public static func resolve(
        bundleID: String?,
        from profiles: [AppProfile] = defaults
    ) -> AppProfile? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        return profiles.first { $0.enabled && $0.bundleIDs.contains(bundleID) }
    }
}

extension AppProfile {
    /// Generic, non-personal starter samples shipped in the public repo. The
    /// user's real per-app prompts are seeded from a gitignored local file
    /// bundled at build time (see AppProfileSeeder); these are the fallback.
    public static let defaults: [AppProfile] = [
        AppProfile(
            id: "sample-email",
            displayName: "Email",
            bundleIDs: ["com.apple.mail", "com.microsoft.Outlook"],
            promptOverride: """
                Clean up ASR-transcribed speech for a business email. Output ONLY the corrected text — no preamble, no markdown. Split into sentences, capitalize correctly, and fix obvious homophones. Numbers, dates, currency, and symbols are already formatted — preserve them exactly as written. Preserve the speaker's wording and intent.

                Input: {{TRANSCRIPT}}
                """,
            enabled: true,
            sortOrder: 0
        ),
        AppProfile(
            id: "sample-notes",
            displayName: "Notes",
            bundleIDs: ["md.obsidian", "com.apple.Notes"],
            promptOverride: """
                Clean up ASR-transcribed speech for a personal note. Output ONLY the corrected text. Light touch: fix obvious errors and capitalization; keep short fragments and bullet-style phrasing. Numbers, dates, currency, and symbols are already formatted — preserve them exactly as written. Preserve wording and intent.

                Input: {{TRANSCRIPT}}
                """,
            enabled: true,
            sortOrder: 1
        ),
        AppProfile(
            id: "sample-chat",
            displayName: "Chat",
            bundleIDs: ["com.tinyspeck.slackmacgap", "com.apple.MobileSMS"],
            promptOverride: """
                Clean up ASR-transcribed speech for a casual chat message. Output ONLY the corrected text. Keep it conversational; fix obvious errors only. Numbers, dates, currency, and symbols are already formatted — preserve them exactly as written. Preserve wording and intent.

                Input: {{TRANSCRIPT}}
                """,
            enabled: true,
            sortOrder: 2
        ),
    ]
}

// MARK: - GRDB

import GRDB

extension AppProfile: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "app_profile"

    public enum Columns: String, ColumnExpression {
        case id, displayName, bundleIDs, promptOverride, enabled, sortOrder
    }
}
