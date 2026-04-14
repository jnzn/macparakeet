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
                - Respect the user's Custom Words vocabulary list (loaded separately by the deterministic pipeline) — names and project-specific acronyms from there must be preserved verbatim.
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
            displayName: "Terminal / iTerm / Warp",
            bundleIDs: [
                "com.apple.Terminal",
                "com.googlecode.iterm2",
                "dev.warp.Warp-Stable",
            ],
            promptOverride: """
                Clean up speech dictated into a shell / terminal. Output ONLY the literal shell input the user dictated — no preamble, no explanation, no markdown, no code fences.

                The user speaks shell commands: translate spoken symbol names and common phonetic command names to the literal characters and command names.

                Symbol transliteration (spoken word → literal character):
                - "slash" → /   "backslash" → \\   "dot" / "period" → .
                - "dash" / "hyphen" → -   "underscore" → _   "tilde" → ~
                - "dollar" → $   "at" / "at sign" → @   "hash" / "pound" → #
                - "asterisk" / "star" → *   "pipe" → |   "ampersand" → &
                - "plus" → +   "equals" → =   "colon" → :   "semicolon" → ;
                - "question mark" → ?   "bang" / "exclamation" → !
                - "quote" → "   "backtick" → `
                - "open paren" → (   "close paren" → )
                - "open bracket" → [   "close bracket" → ]
                - "open brace" → {   "close brace" → }
                - "less than" / "left angle" → <   "greater than" / "right angle" → >

                Common phonetic command names:
                - "see dee" → cd   "ell ess" → ls   "em kay dir" → mkdir
                - "are em" → rm   "em vee" → mv   "see pee" → cp
                - "pee dubya dee" → pwd   "grep" → grep   "git" → git
                - "sudo" → sudo   "ssh" → ssh   "cat" → cat

                File extension shorthand:
                - "dot em dee" → .md   "dot tee ex tee" → .txt
                - "dot pee dee ef" / "dot pee dee f" → .pdf
                - "dot jay ess" → .js   "dot pee why" → .py
                - "dot jay ess oh en" → .json   "dot ess h" → .sh
                - "dot why ay em ell" / "dot yaml" → .yaml
                - "dot ess dubya eye eff tee" → .swift

                Spacing rule:
                - Regular words are separated by spaces as usual.
                - When a symbol word sits directly BETWEEN two words/letters, produce NO surrounding spaces. Examples: "hello dot em dee" → hello.md, "foo slash bar" → foo/bar, "read me dot tee ex tee" → readme.txt.
                - Commands still have a space before their arguments: "see dee slash users" → cd /users (a command + path gets one space, but the internal slashes in the path do not).

                Other rules:
                - Do NOT capitalize the first word unless it is a proper noun.
                - Do NOT add sentence-ending punctuation unless the user clearly dictates it — trailing periods break shell commands.
                - Preserve flags verbatim ("dash ay" → -a, "dash el ay" → -la, "dash dash recursive" → --recursive).
                - Fix obvious ASR stutter ("the the" → "the") and remove clear filler words only.
                - Never paraphrase, summarize, or rewrite.

                Examples:
                Input: see dee slash users slash jensen slash dev
                Output: cd /users/jensen/dev

                Input: ell ess dash el ay
                Output: ls -la

                Input: read me dot em dee
                Output: readme.md

                Input: git commit dash em quote fix the bug quote
                Output: git commit -m "fix the bug"

                Input: are em dash are eff slash tmp slash cache
                Output: rm -rf /tmp/cache

                Input: echo hello world greater than hello dot tee ex tee
                Output: echo hello world > hello.txt

                Input: sudo apt dash get install python dot pee dee ef viewer
                Output: sudo apt-get install python.pdf viewer

                Input: curl dash ess capital lee https colon slash slash example dot com slash file dot pee dee f
                Output: curl -sL https://example.com/file.pdf

                Input: {{TRANSCRIPT}}
                """
        ),
        AppProfile(
            id: "ide",
            displayName: "Code Editor (Xcode / Zed / VS Code)",
            bundleIDs: [
                "com.apple.dt.Xcode",
                "dev.zed.Zed",
                "com.microsoft.VSCode",
            ],
            promptOverride: """
                Clean up speech dictated into a code editor. Output ONLY the corrected text — no preamble, no markdown, no code fences.

                Rules:
                - If the input looks like prose (a code comment, commit message, or doc), apply normal cleanup: capitalize sentences, add punctuation, fix homophones.
                - If the input looks like code — a function name, variable, identifier, file path, or shell-like fragment — preserve it verbatim with no capitalization or punctuation added.
                - Do NOT transliterate spoken symbol words into characters. "slash" stays "slash" unless it is obviously part of a path.
                - Fix obvious ASR stutter and remove clear filler words.
                - Never paraphrase, summarize, or rewrite.

                Preserve the speaker's wording, word order, and intent.

                Input: {{TRANSCRIPT}}
                """
        ),
    ]
}
