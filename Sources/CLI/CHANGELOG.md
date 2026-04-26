# Changelog -- macparakeet-cli

All notable changes to the **`macparakeet-cli` surface** are documented here.

This file tracks the CLI specifically -- the commands, flags, output schemas,
and exit codes that scripted callers (shell scripts, CI pipelines, AI agents)
depend on. App-level changes ship through Sparkle and are documented in the
appcast at <https://macparakeet.com/appcast.xml>.

The format is based on [Keep a Changelog](https://keepachangelog.com), and the
CLI adheres to [Semantic Versioning](https://semver.org).

## Compatibility policy

The CLI surface is a public contract. We follow semver:

- **MAJOR** -- any change that breaks scripted callers: removed commands,
  renamed flags, removed JSON fields, changed exit-code meanings, changed
  default behavior of an existing flag.
- **MINOR** -- additive changes: new commands, new flags, new optional JSON
  fields, new exit codes for new error classes.
- **PATCH** -- bug fixes, output formatting tweaks that preserve schema,
  documentation, performance work.

When we deprecate a command or flag, the old name keeps working for **at least
one minor release** with a clear `--help` notice and a CHANGELOG callout. New
names are added first; old names are removed only at a MAJOR boundary.

JSON output schemas are part of the contract: top-level shape (array vs
object), field names, and field types are stable within a major version. We
may add new optional fields in a minor release.

## [1.0.0] -- 2026-04-25

First release of the CLI as a versioned public surface. The CLI has existed
since v0.1 of the MacParakeet app and powered AI-assisted testing through
v0.4--v0.6. With the prompts subcommand and JSON sweep landing in
[PR #138](https://github.com/moona3k/macparakeet/pull/138), the surface is
complete enough to commit to. This release marks that commitment.

### Added

- `prompts` subcommand: `list` / `show` / `add` / `set` / `delete` /
  `restore-defaults` / `run`. UUID-or-name lookup with prefix matching, error
  surfacing for ambiguous prefixes, refusal to delete built-ins. `prompts run`
  invokes any LLM provider configured via `--provider --api-key --model`.
  ([PR #138](https://github.com/moona3k/macparakeet/pull/138))
- `--json` flag on read-only commands: `history dictations`,
  `history transcriptions`, `history search`, `history search-transcriptions`,
  `history favorites`, `stats`, `flow words list`, `flow snippets list`,
  `health`, `models status`. Convention: ISO-8601 datetimes, pretty-printed
  output, sorted keys, top-level array for list commands and object for
  single-record / status commands. Matches the existing `calendar upcoming
  --json` shape.
  ([PR #138](https://github.com/moona3k/macparakeet/pull/138))
- `flow words list --source manual|learned|all` filter. Default `all`.
  Surfaces the source distinction (user-typed vs vocabulary-learned) that the
  schema has carried for two releases but the CLI hadn't exposed.
  ([PR #138](https://github.com/moona3k/macparakeet/pull/138))

### Changed

- Command abstract reframed from "internal developer CLI" to a public surface.
  The CLI is now positioned as the canonical Swift-native interface to
  Parakeet TDT on Apple Silicon, with the macOS app as one consumer of it.
  Strategic context: `plans/active/cli-as-canonical-parakeet-surface.md`.

### Compatibility notes

- Pre-1.0 callers are unaffected. Every existing command and flag retains its
  prior behavior; the version bump signals "stability commitment going
  forward," not a breaking-change cliff.
- The CLI ships inside the `MacParakeet.app` bundle today
  (`MacParakeet.app/Contents/MacOS/macparakeet-cli`). Standalone install via
  Homebrew tap is on the roadmap (see plan above) and will not change command
  semantics.
- **`--format json` (transcribe, export) vs `--json` (read-only queries)**
  is deliberate, not a bug. `transcribe` and `export` carry a `--format`
  selector because they emit one of several formats (txt / srt / vtt / json /
  docx / pdf); `--json` on read-only query commands is a binary flag because
  their output shape is conceptually fixed -- it's either JSON or human.
  Unifying this would be a major-version breaking change; we are not doing
  that in 1.0.
