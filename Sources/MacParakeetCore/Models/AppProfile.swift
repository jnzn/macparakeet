import Foundation

/// A per-app customization for dictation cleanup. Resolved once at the start of
/// a dictation based on the frontmost app's bundle identifier, then used for
/// both live-bubble cleanup and the paste-path LLM polish (when enabled).
///
/// MVP: hardcoded `defaults` only. A later iteration will persist user-editable
/// profiles to GRDB + a Settings editor.
public struct AppProfile: Equatable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    /// Bundle identifiers this profile applies to. First profile with a match wins.
    public let bundleIDs: [String]
    /// Full LLM prompt template (uses `{{TRANSCRIPT}}` placeholder) to use instead
    /// of the user-configured default. Nil falls back to the default formatter prompt.
    public let promptOverride: String?
    public let enabled: Bool

    public init(
        id: String,
        displayName: String,
        bundleIDs: [String],
        promptOverride: String?,
        enabled: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.bundleIDs = bundleIDs
        self.promptOverride = promptOverride
        self.enabled = enabled
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
    public static let defaults: [AppProfile] = [
        AppProfile(
            id: "email",
            displayName: "Email (Apple Mail + Outlook)",
            bundleIDs: ["com.apple.mail", "com.microsoft.Outlook"],
            promptOverride: """
                Clean up ASR-transcribed speech for a business email. Output ONLY the corrected text — no preamble, no reasoning, no explanations, no `<channel|>` tags, no markdown.

                Required transformations (do these every time, even if input looks OK):
                - Split the run-on transcript into proper sentences. End each with `.` `?` or `!`.
                - Capitalize the first word of every sentence.
                - Capitalize proper nouns, product names, acronyms, and first-person "I".
                - Lean toward business-formal tone: full sentences, proper punctuation, minimal contractions.
                - Insert commas where English grammar and business-email clarity require them.
                - Fix obvious homophone errors (wood↔would, their↔there↔they're, two↔to↔too, its↔it's).
                - Collapse ASR stutter ("the the cat" → "the cat"). Keep intentional repetition.
                - Remove filler words ("um", "uh", sometimes "like") only when clearly filler.

                Preserve the speaker's wording, word order, phrasing, and intent. Never paraphrase, summarize, shorten, or add content.

                Input: {{TRANSCRIPT}}
                """
        ),
        AppProfile(
            id: "obsidian",
            displayName: "Obsidian",
            bundleIDs: ["md.obsidian"],
            promptOverride: """
                Clean up ASR-transcribed speech for a personal Obsidian note. Output ONLY the corrected text — no preamble, no reasoning, no markdown wrapping.

                Required transformations:
                - Split into sentences where natural. Short fragments and bullet-style phrasing are fine — this is note-taking, not prose.
                - Capitalize the first word of every sentence and all proper nouns + acronyms + first-person "I".
                - Fix obvious homophone errors.
                - Collapse ASR stutter ("the the cat" → "the cat"). Keep intentional repetition.
                - Remove filler words ("um", "uh") when clearly filler.

                Preserve the speaker's wording, word order, and intent. Never paraphrase, summarize, or add content.

                Input: {{TRANSCRIPT}}
                """
        ),
        AppProfile(
            id: "teams",
            displayName: "Microsoft Teams",
            bundleIDs: ["com.microsoft.teams2", "com.microsoft.teams"],
            promptOverride: """
                Clean up ASR-transcribed speech for a casual work chat message in Microsoft Teams. Output ONLY the corrected text — no preamble, no markdown.

                Required transformations:
                - Casual work-chat tone: contractions are fine, sentence fragments are fine, "yeah / yep / nope" are fine.
                - Capitalize the first word of every sentence, proper nouns, acronyms, and first-person "I".
                - Coworker names often mis-transcribed: Yeswanth (often heard as "once"), Susanta (often heard as "Sushanta" or "Shushanta").
                - Fix obvious homophone errors.
                - Collapse ASR stutter. Keep intentional emphasis repetition ("no no no", "very very").
                - Remove clear filler words.

                Preserve the speaker's wording, word order, and intent. Never paraphrase, summarize, or add content.

                Input: {{TRANSCRIPT}}
                """
        ),
        AppProfile(
            id: "messages",
            displayName: "Messages",
            bundleIDs: ["com.apple.MobileSMS"],
            promptOverride: """
                Clean up ASR-transcribed speech for an iMessage. Output ONLY the corrected text — no preamble, no markdown.

                Required transformations:
                - Very casual tone: contractions, fragments, and lowercase sentence starts are all fine when natural.
                - Always capitalize "I" and proper nouns.
                - Fix obvious homophone errors.
                - Collapse ASR stutter. Keep intentional emphasis repetition ("no no no").
                - Remove clear filler words.

                Preserve the speaker's wording and intent. Never paraphrase, summarize, or add content.

                Input: {{TRANSCRIPT}}
                """
        ),
        AppProfile(
            id: "terminal",
            displayName: "Terminal / IDE",
            bundleIDs: [
                "com.apple.Terminal",
                "com.googlecode.iterm2",
                "dev.warp.Warp-Stable",
                "com.apple.dt.Xcode",
                "dev.zed.Zed",
                "com.microsoft.VSCode",
            ],
            promptOverride: """
                Clean up ASR-transcribed speech for a terminal or code editor. Output ONLY the corrected text — no preamble, no markdown, no code fences.

                CRITICAL rules:
                - Do NOT capitalize the first word unless it is an obvious proper noun. Shell commands, variable names, flags, and function names are often lowercase and must stay that way.
                - Do NOT add sentence-ending punctuation unless the speaker clearly dictates it — trailing periods break commands.
                - If the input looks like code, a shell command, a file path, or an identifier, preserve it verbatim.
                - Fix obvious ASR stutter ("the the" → "the") and remove clear filler words, but otherwise preserve exactly.

                Never paraphrase, summarize, or rewrite.

                Input: {{TRANSCRIPT}}
                """
        ),
    ]
}
