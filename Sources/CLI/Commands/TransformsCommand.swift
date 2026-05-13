import ArgumentParser
import Foundation
import MacParakeetCore

/// `macparakeet-cli transforms` — manage and run user-defined Transforms
/// (ADR-022) headlessly. Built so an agent operator can provision a fresh
/// device, dispatch a saved prompt against arbitrary text from CI, and
/// verify the dispatch table without launching the GUI.
///
/// Versus `llm transform --prompt "..."` (which is the raw-prompt ad-hoc
/// primitive), `transforms run <name>` invokes the **saved** prompt body
/// stored in the prompts table.
struct TransformsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transforms",
        abstract: "Manage and run user-defined Transforms (saved prompt + hotkey rewrite shortcuts).",
        subcommands: [
            ListSubcommand.self,
            ShowSubcommand.self,
            RunSubcommand.self,
            CreateSubcommand.self,
            DeleteSubcommand.self,
        ],
        defaultSubcommand: ListSubcommand.self
    )
}

// MARK: - List

extension TransformsCommand {
    struct ListSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List Transforms with their bound shortcuts."
        )

        @Flag(name: .long, help: "Emit JSON instead of human-readable output.")
        var json: Bool = false

        @Option(help: "Path to SQLite database file (defaults to the app database).")
        var database: String?

        func run() throws {
            try emitJSONOrRethrow(json: json) {
                try AppPaths.ensureDirectories()
                let db = try DatabaseManager(path: resolvedDatabasePath(database))
                let repo = PromptRepository(dbQueue: db.dbQueue)
                let transforms = try repo
                    .fetchVisible(category: .transform)
                    .sorted(by: { $0.sortOrder < $1.sortOrder })

                if json {
                    try printJSON(transforms.map(TransformDTO.init(prompt:)))
                    return
                }

                if transforms.isEmpty {
                    print("No Transforms found.")
                    return
                }

                for t in transforms {
                    let badge = t.isBuiltIn ? " [built-in]" : ""
                    let shortcut = t.shortcut?.displayString ?? "—"
                    print("\(t.id.uuidString.prefix(8))  \(shortcut.padding(toLength: 12, withPad: " ", startingAt: 0))  \(t.name)\(badge)")
                }
                print()
                print("\(transforms.count) Transform(s)")
            }
        }
    }
}

// MARK: - Show

extension TransformsCommand {
    struct ShowSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Show a Transform's full prompt body and bound shortcut."
        )

        @Argument(help: "Transform ID, ID prefix, or name.")
        var idOrName: String

        @Flag(name: .long, help: "Emit JSON instead of human-readable output.")
        var json: Bool = false

        @Option(help: "Path to SQLite database file (defaults to the app database).")
        var database: String?

        func run() throws {
            try emitJSONOrRethrow(json: json) {
                try AppPaths.ensureDirectories()
                let db = try DatabaseManager(path: resolvedDatabasePath(database))
                let repo = PromptRepository(dbQueue: db.dbQueue)
                let transform = try findTransform(idOrName: idOrName, repo: repo)

                if json {
                    try printJSON(TransformDTO(prompt: transform))
                    return
                }

                print("ID:        \(transform.id.uuidString)")
                print("Name:      \(transform.name)\(transform.isBuiltIn ? " [built-in]" : "")")
                print("Shortcut:  \(transform.shortcut?.displayString ?? "—")")
                print("Running:   \(transform.derivedRunningLabel)")
                print("Updated:   \(ISO8601DateFormatter().string(from: transform.updatedAt))")
                print()
                print(transform.content)
            }
        }
    }
}

// MARK: - Run

extension TransformsCommand {
    struct RunSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "run",
            abstract: "Run a saved Transform against text from a file or stdin."
        )

        @OptionGroup var llm: LLMInlineOptions

        @Argument(help: "Transform ID, ID prefix, or name.")
        var idOrName: String

        @Option(name: .shortAndLong, help: "Path to text file to transform. Use '-' for stdin.")
        var input: String

        @Flag(name: .long, help: "Stream the response token by token. Incompatible with --json.")
        var stream: Bool = false

        @Flag(name: .long, help: "Emit a structured JSON envelope instead of plain text.")
        var json: Bool = false

        @Option(help: "Path to SQLite database file (defaults to the app database).")
        var database: String?

        func validate() throws {
            if json && stream {
                throw ValidationError("--json with --stream is not yet supported. Run without --stream for the envelope, or omit --json for token streaming.")
            }
        }

        func run() async throws {
            try await emitJSONOrRethrow(json: json) {
                try AppPaths.ensureDirectories()
                let db = try DatabaseManager(path: resolvedDatabasePath(database))
                let repo = PromptRepository(dbQueue: db.dbQueue)
                let transform = try findTransform(idOrName: idOrName, repo: repo)

                let text = try readInput(input)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CLIInputError.empty
                }

                let execution = try llm.buildExecutionContext()
                let service = LLMService(
                    client: execution.client,
                    contextResolver: StaticLLMExecutionContextResolver(context: execution.context)
                )

                if json {
                    let result = try await service.transformDetailed(text: text, prompt: transform.content)
                    try printJSON(result)
                } else if stream {
                    let tokenStream = service.transformStream(text: text, prompt: transform.content)
                    for try await token in tokenStream {
                        print(token, terminator: "")
                    }
                    print()
                } else {
                    print(try await service.transform(text: text, prompt: transform.content))
                }
            }
        }
    }
}

// MARK: - Create

extension TransformsCommand {
    struct CreateSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "create",
            abstract: "Headless-install a new Transform with an optional bound shortcut."
        )

        @Option(name: .long, help: "Transform name (must be unique across Transforms).")
        var name: String

        @Option(name: .long, help: "Prompt body text. Mutually exclusive with --from-file.")
        var prompt: String?

        @Option(name: .long, help: "Path to a file containing the prompt body.")
        var fromFile: String?

        @Option(name: .long, help: "Keyboard shortcut, e.g. 'opt+1', 'cmd+shift+P'. Modifier required.")
        var shortcut: String?

        @Option(name: .long, help: "Optional running-pill label. Defaults to a 'Naming…' heuristic.")
        var runningLabel: String?

        @Flag(name: .long, help: "Emit a JSON envelope on success.")
        var json: Bool = false

        @Option(help: "Path to SQLite database file (defaults to the app database).")
        var database: String?

        func validate() throws {
            if prompt != nil && fromFile != nil {
                throw ValidationError("--prompt and --from-file are mutually exclusive.")
            }
            if prompt == nil && fromFile == nil {
                throw ValidationError("Provide a prompt body via --prompt or --from-file.")
            }
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError("--name must not be empty.")
            }
        }

        func run() throws {
            try emitJSONOrRethrow(json: json) {
                try AppPaths.ensureDirectories()
                let db = try DatabaseManager(path: resolvedDatabasePath(database))
                let repo = PromptRepository(dbQueue: db.dbQueue)

                let body: String
                if let p = prompt {
                    body = p
                } else if let path = fromFile {
                    body = try String(contentsOfFile: path, encoding: .utf8)
                } else {
                    throw ValidationError("Provide a prompt body via --prompt or --from-file.")
                }

                let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)

                let existing = try repo.fetchAll()
                if existing.contains(where: { $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame }) {
                    throw CLITransformsError.duplicateName(trimmedName)
                }

                let shortcutValue: KeyboardShortcut?
                if let s = shortcut {
                    guard let parsed = KeyboardShortcut.parse(s) else {
                        throw CLITransformsError.invalidShortcut(s)
                    }
                    guard parsed.hasModifier else {
                        throw CLITransformsError.shortcutMissingModifier
                    }
                    guard !parsed.isMacOSDeadKey else {
                        throw CLITransformsError.shortcutMacOSDeadKey
                    }
                    if let duplicate = existing.first(where: { prompt in
                        guard prompt.category == .transform,
                              let shortcut = prompt.shortcut
                        else { return false }
                        return shortcutsMatch(shortcut, parsed)
                    }) {
                        throw CLITransformsError.duplicateShortcut(
                            parsed.displayString,
                            duplicate.name
                        )
                    }
                    let appHotkeyCollision = appHotkeyCollision(for: parsed)
                    if let appHotkeyCollision {
                        throw appHotkeyCollision
                    }
                    shortcutValue = parsed
                } else {
                    shortcutValue = nil
                }

                let now = Date()
                let transform = Prompt(
                    id: UUID(),
                    name: trimmedName,
                    content: body,
                    category: .transform,
                    isBuiltIn: false,
                    isVisible: true,
                    isAutoRun: false,
                    sortOrder: 200,
                    createdAt: now,
                    updatedAt: now,
                    keyboardShortcut: shortcutValue?.encodedString(),
                    runningLabel: runningLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                try repo.save(transform)

                if json {
                    try printJSON(TransformDTO(prompt: transform))
                } else {
                    print("Created Transform \(transform.id.uuidString.prefix(8))  \(transform.name)")
                    if let shortcutValue {
                        print("Bound to \(shortcutValue.displayString)")
                    } else {
                        print("Dormant (no shortcut bound)")
                    }
                }
            }
        }
    }
}

// MARK: - Delete

extension TransformsCommand {
    struct DeleteSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "delete",
            abstract: "Delete a custom Transform. Built-ins are protected."
        )

        @Argument(help: "Transform ID, ID prefix, or name.")
        var idOrName: String

        @Flag(name: .long, help: "Emit a JSON envelope on success.")
        var json: Bool = false

        @Option(help: "Path to SQLite database file (defaults to the app database).")
        var database: String?

        func run() throws {
            try emitJSONOrRethrow(json: json) {
                try AppPaths.ensureDirectories()
                let db = try DatabaseManager(path: resolvedDatabasePath(database))
                let repo = PromptRepository(dbQueue: db.dbQueue)
                let transform = try findTransform(idOrName: idOrName, repo: repo)

                if transform.isBuiltIn {
                    throw CLITransformsError.deleteBuiltIn(transform.name)
                }

                let deleted = try repo.delete(id: transform.id)
                guard deleted else {
                    throw CLITransformsError.notFound(idOrName)
                }

                if json {
                    struct DeleteResult: Encodable { let deleted: Bool; let id: String; let name: String }
                    try printJSON(DeleteResult(deleted: true, id: transform.id.uuidString, name: transform.name))
                } else {
                    print("Deleted Transform \(transform.id.uuidString.prefix(8))  \(transform.name)")
                }
            }
        }
    }
}

// MARK: - Lookup helper

private let transformIDPrefixMinimumLength = 4

private func findTransform(idOrName: String, repo: PromptRepository) throws -> Prompt {
    let query = idOrName.trimmingCharacters(in: .whitespacesAndNewlines)
    let all = try repo.fetchVisible(category: .transform)
    // Exact UUID match
    if let uuid = UUID(uuidString: query), let match = all.first(where: { $0.id == uuid }) {
        return match
    }
    // ID prefix. Dashes are optional. Prefix lookup intentionally precedes
    // name lookup so an ambiguous machine identifier never silently resolves
    // to a same-text custom name.
    if let prefix = normalizedUUIDPrefix(query) {
        let prefixMatches = all.filter {
            $0.id.uuidString
                .lowercased()
                .filter { $0 != "-" }
                .hasPrefix(prefix)
        }
        if prefixMatches.count == 1 {
            return prefixMatches[0]
        }
        if prefixMatches.count > 1 {
            throw CLITransformsError.ambiguous(query, prefixMatches.map(\.name))
        }
    }
    // Case-insensitive name match
    let nameMatches = all.filter { $0.name.caseInsensitiveCompare(query) == .orderedSame }
    if nameMatches.count == 1 {
        return nameMatches[0]
    }
    if nameMatches.count > 1 {
        throw CLITransformsError.ambiguous(query, nameMatches.map(\.name))
    }
    throw CLITransformsError.notFound(query)
}

private func normalizedUUIDPrefix(_ raw: String) -> String? {
    let lowercased = raw.lowercased()
    guard lowercased.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return nil }
    let normalized = lowercased.filter { $0 != "-" }
    guard normalized.count >= transformIDPrefixMinimumLength else { return nil }
    return normalized
}

// MARK: - DTO + errors

/// Snake-cased DTO for the `--json` envelope so CLI consumers don't have to
/// learn about the internal `Prompt` shape (which conflates `.result` rows
/// with this surface).
struct TransformDTO: Encodable {
    let id: String
    let name: String
    let shortcut: String?
    let runningLabel: String?
    let isBuiltIn: Bool
    let prompt: String
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case shortcut
        case runningLabel = "running_label"
        case isBuiltIn = "is_built_in"
        case prompt
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(prompt: Prompt) {
        self.id = prompt.id.uuidString
        self.name = prompt.name
        self.shortcut = prompt.shortcut?.displayString
        self.runningLabel = prompt.runningLabel
        self.isBuiltIn = prompt.isBuiltIn
        self.prompt = prompt.content
        self.createdAt = prompt.createdAt
        self.updatedAt = prompt.updatedAt
    }
}

enum CLITransformsError: Error, CustomStringConvertible {
    case notFound(String)
    case ambiguous(String, [String])
    case duplicateName(String)
    case invalidShortcut(String)
    case shortcutMissingModifier
    case shortcutMacOSDeadKey
    case duplicateShortcut(String, String)
    case shortcutConflictsWithAppHotkey(String, String)
    case deleteBuiltIn(String)

    var description: String {
        switch self {
        case .notFound(let q):
            return "No Transform found matching “\(q)”."
        case .ambiguous(let q, let names):
            return "“\(q)” matches multiple Transforms: \(names.joined(separator: ", ")). Use a longer ID prefix."
        case .duplicateName(let n):
            return "A prompt named “\(n)” already exists."
        case .invalidShortcut(let s):
            return "Couldn't parse shortcut “\(s)”. Try forms like 'opt+1', 'cmd+shift+P', 'ctrl+opt+space'."
        case .shortcutMissingModifier:
            return "Shortcut must include a modifier key (cmd, opt, ctrl, or shift)."
        case .shortcutMacOSDeadKey:
            return "This shortcut produces a special character on Mac. Pick another combo."
        case .duplicateShortcut(let shortcut, let name):
            return "Shortcut “\(shortcut)” is already used by Transform “\(name)”."
        case .shortcutConflictsWithAppHotkey(let shortcut, let name):
            return "Shortcut “\(shortcut)” conflicts with your \(name) hotkey."
        case .deleteBuiltIn(let n):
            return "Cannot delete the built-in Transform “\(n)”. Reset or edit it in the Transforms tab."
        }
    }

    var errorType: String {
        switch self {
        case .notFound, .ambiguous:
            return CLIErrorType.lookup
        case .duplicateName,
             .invalidShortcut,
             .shortcutMissingModifier,
             .shortcutMacOSDeadKey,
             .duplicateShortcut,
             .shortcutConflictsWithAppHotkey,
             .deleteBuiltIn:
            return CLIErrorType.validation
        }
    }

    var isValidationMisuse: Bool {
        switch self {
        case .notFound, .ambiguous:
            return false
        case .duplicateName,
             .invalidShortcut,
             .shortcutMissingModifier,
             .shortcutMacOSDeadKey,
             .duplicateShortcut,
             .shortcutConflictsWithAppHotkey,
             .deleteBuiltIn:
            return true
        }
    }
}

private func shortcutsMatch(_ lhs: KeyboardShortcut, _ rhs: KeyboardShortcut) -> Bool {
    lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers
}

private func appHotkeyCollision(for shortcut: KeyboardShortcut) -> CLITransformsError? {
    let defaults = macParakeetAppDefaults()
    let candidate = shortcut.hotkeyTrigger
    let reservedHotkeys: [(name: String, trigger: HotkeyTrigger)] = [
        (
            "hands-free dictation",
            HotkeyTrigger.current(defaults: defaults)
        ),
        (
            "push-to-talk",
            HotkeyTrigger.current(
                defaults: defaults,
                defaultsKey: HotkeyTrigger.pushToTalkDefaultsKey,
                fallback: .defaultPushToTalk
            )
        ),
        (
            "meeting recording",
            HotkeyTrigger.current(
                defaults: defaults,
                defaultsKey: HotkeyTrigger.meetingDefaultsKey,
                fallback: .defaultMeetingRecording
            )
        ),
        (
            "file transcription",
            HotkeyTrigger.current(
                defaults: defaults,
                defaultsKey: HotkeyTrigger.fileTranscriptionDefaultsKey,
                fallback: .disabled
            )
        ),
        (
            "YouTube transcription",
            HotkeyTrigger.current(
                defaults: defaults,
                defaultsKey: HotkeyTrigger.youtubeTranscriptionDefaultsKey,
                fallback: .disabled
            )
        ),
    ]
    for reserved in reservedHotkeys where !reserved.trigger.isDisabled {
        if candidate.overlaps(with: reserved.trigger) {
            return .shortcutConflictsWithAppHotkey(shortcut.displayString, reserved.name)
        }
    }

    return nil
}
