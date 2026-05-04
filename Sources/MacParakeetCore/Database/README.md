# Database

> SQLite via GRDB. One file (`macparakeet.db`), one repository per
> table, inline migrations registered in `DatabaseManager`.

## Entry point

`DatabaseManager` — owns the `DatabaseQueue` and runs migrations on
init. Every repository takes a `DatabaseManager` (or its `dbQueue`)
and reads/writes through it. There is one `DatabaseManager` per app
process.

## What's here

- `DatabaseManager.swift` — connection setup, migrator registration,
  schema versions. The single source of truth for the database
  schema.
- One repository per table:
  - `DictationRepository.swift` — dictation history + lifetime stats.
  - `TranscriptionRepository.swift` — file/YouTube/meeting transcriptions.
  - `CustomWordRepository.swift` — vocabulary entries.
  - `TextSnippetRepository.swift` — snippets (text + action).
  - `PromptRepository.swift` — prompt-library entries.
  - `PromptResultRepository.swift` — saved prompt outputs.
  - `QuickPromptRepository.swift` — quick-prompt entries (Ask tab).
  - `ChatConversationRepository.swift` — multi-turn chat history.

## Cross-references

- `spec/01-data-model.md` — the canonical schema spec; mirrors
  what's in `DatabaseManager`'s migrator. Update both when schema
  changes.
- ADR-013 — prompt library + multi-summary architecture (drives
  several of the repositories above).
- `Sources/MacParakeetCore/Models/` — the row types each repository
  reads and writes.

## What to know before editing

**Migrations are inline in `DatabaseManager`, not separate files.**
Each migration is a `migrator.registerMigration("vX.Y-name") { db in
... }` block. The naming convention is `vX.Y-<table-or-feature>` so
the migration ledger doubles as a release-version trail. Migrations
run once and are never edited after a release ships — to change a
shipped schema, register a *new* migration that performs the
adjustment.

**One repository per table. Don't combine tables in one repo.**
Each repository implements a `…Protocol` so callers can be tested
against a mock. The repository owns CRUD plus any table-specific
helpers (FTS search, stats aggregation). Cross-table joins live at
the service layer, not in repositories.

**Never use raw SQL `WHERE id = ?` with `uuid.uuidString`.**
GRDB stores UUID values via Codable encoding, which produces a
representation that is not always equal to `UUID.uuidString`. Use
GRDB's `fetchOne(key:)` + `update()` pattern for primary-key
lookups, and `Codable`-aware filter expressions for predicates. A
raw-SQL UUID lookup will silently miss rows. This has bitten the
repo before and is the single most common database bug shape we see.

**In-memory databases for tests.** `DatabaseManager()` (no args)
returns an in-memory queue with the same migrator applied. Use
this in unit and integration tests — never write to the on-disk
file from tests. In-memory fixtures are fast, isolated, and don't
require cleanup.

**Foreign keys are on.** `Configuration().foreignKeysEnabled = true`
is set in `makeConfiguration`. Migrations and inserts must respect
foreign-key constraints; cascading deletes are explicit on each FK.

**Short concurrent writes wait.** `Configuration.busyMode = .timeout(5)`
is set so separate GUI/CLI/agent processes wait through brief SQLite write
locks instead of surfacing immediate `SQLITE_BUSY` failures. Long-held locks
still fail visibly after the timeout.

**File-backed migrations are process-serialized.** `DatabaseManager(path:)`
uses a sibling `.migration.lock` file while running migrations and built-in
seed reconciliation. This keeps parallel CLI/agent first-run processes from
racing on an empty database.

**SQL tracing in DEBUG.** Set the env var `MACPARAKEET_DEBUG_SQL=1`
to print every executed statement. Useful for diagnosing slow
queries or accidental N+1 patterns during development; off by
default and unavailable in release builds.

**Lifetime-stats counter row.** `DictationRepository` maintains a
singleton row (`lifetime_dictation_stats`) that survives history
deletion. Increments happen in the same transaction as the
dictation save (issue #124). If you add a stat, add it to that row,
the migration for the column, and the `resetLifetimeStats()` path.

## How to verify a change

- `swift test --filter Database` — repository unit tests.
- `swift test --filter Migration` (where applicable) — confirm new
  migrations apply cleanly to an empty database and to a
  previous-version snapshot.
- `swift test` — full suite. Schema changes ripple through services
  and view models.
- Manual: delete `~/Library/Application Support/MacParakeet/macparakeet.db`,
  relaunch the app, confirm migrations run cleanly from empty.
  (Only do this on a dev install you don't mind resetting.)
