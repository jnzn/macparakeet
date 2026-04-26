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

### Exit codes

The CLI uses a small set of exit codes. They are part of the public contract;
new error classes get new minor-version codes, never silent reuse.

| Code | Meaning |
|------|---------|
| `0`  | Success. |
| `1`  | Runtime failure -- the command attempted its work and the work failed. Examples: LLM provider call returned an error, transcription failed, database read/write error, network unreachable. The command writes a one-line stderr message describing the failure. |
| `2`  | Validation/misuse -- the invocation itself was malformed before the command did any real work. Examples: unknown provider, missing required flag, malformed input file, unsupported `--format` value. ArgumentParser produces this for unknown flags as well. |
| `130` | Interrupted by `SIGINT` (Ctrl-C). Inherits Unix convention; downstream agents should treat this as cancellation, not failure. |

After argument parsing succeeds, `--json` output never goes to stderr
regardless of exit code. When `--json` is passed, both success and post-parse
failure print a JSON object to stdout; the exit code remains the source of
truth for branching.

### `--json` failure envelope

Any command that accepts `--json` emits this envelope on stdout when the
command fails *after argument parsing succeeds* — provider error, missing
input, lookup miss, runtime exception, etc.:

```json
{
  "ok": false,
  "error": "human-readable message",
  "errorType": "auth"
}
```

`errorType` is a low-cardinality stable string. Current values: `auth`,
`config`, `connection`, `context`, `input_empty`, `input_missing`,
`invalid_response`, `lookup`, `model`, `provider`, `rate_limit`, `runtime`,
`streaming`, `truncated`, `validation`. New error classes get new values in
minor releases; existing values are stable within a major.

Stderr stays plain text for human-only progress / status (e.g. "Saved
PromptResult abc12345"), so piping `--json` stdout through `jq` is safe.

**Parse-time / `validate()` failures** (unknown flags, missing required
flags, mutually-exclusive flag combinations like `--json` with `--stream`)
happen before the command starts running and surface through
ArgumentParser's plain-text stderr path with exit code `2`. Downstream
agents that branch on `errorType` should also handle the parse-error case
by checking exit code first: `2` = misuse, `1` = runtime, `0` = success.

## [1.2.0] -- 2026-04-26

### Added

- `--json` output mode for the LLM commands (`llm summarize`, `llm chat`,
  `llm transform`, `prompts run`) and `llm test-connection`. Emits a
  structured envelope so agents can read `{output, provider, model,
  usage: {promptTokens, completionTokens, totalTokens}, stopReason,
  latencyMs}` directly rather than regexing prose. Token field names
  match the OpenAI convention. `usage` is omitted when the provider
  doesn't surface it (`localCLI`; some `openaiCompatible` servers).
  `stopReason` is pass-through — provider-native vocabulary
  (`end_turn`, `length`, `STOP`, `done_reason`, etc.) is surfaced
  verbatim. `test-connection --json` returns
  `{ok: true, provider, model, latencyMs}` on success and the standard
  `--json` failure envelope (see top of file) on failure. All `--json`
  commands now share that failure envelope so downstream agents see one
  of two shapes — never a mix of JSON success and plain-text failure.

### Not yet supported

- `--json` combined with `--stream` is rejected at argument validation
  with a clear error. NDJSON streaming (`{type: "delta"}` lines
  followed by a `{type: "final"}` envelope) is a planned follow-up.

## [1.1.0] -- 2026-04-26

### Added

- `flow process --database <path>` can now run the clean text-processing
  pipeline against an explicit SQLite database, matching the testability and
  agent-workflow override already used by other `flow` commands.

### Fixed

- `feedback` and direct `llm` commands now write validation and provider
  errors to stderr instead of stdout.
- `transcribe --format` now rejects unsupported values during argument parsing
  instead of silently falling back to text output.
- `transcribe` now awaits STT runtime shutdown on both success and error paths.

## [1.0.1] -- 2026-04-26

End-to-end validation of the brew-installed 1.0.0 binary surfaced a
single stdout-pollution bug in `transcribe`. Fixed below; no other
behavior change.

### Fixed

- `transcribe --format json` emitted a `Transcribing <file>...` (or
  `Converting`/`Downloading`/`Identifying speakers`/`Finalizing` for
  YouTube URLs) progress line on **stdout** before the JSON payload,
  which broke `transcribe ... --format json | jq .` for any scripted
  caller. Progress messages now go to stderr (matching the existing
  pattern in `prompts run` and the documented "JSON only to stdout"
  contract from `integrations/README.md`). New `printErr(_:)` helper
  in `CLIHelpers.swift` codifies the channel.

### Compatibility notes

- The progress messages are still emitted; they just go to stderr now.
  Human callers using the human-readable `--format txt` (default) are
  unaffected — stderr still surfaces in the terminal.
- Scripted callers that were relying on the progress message appearing
  on stdout (unlikely; it was a polling-style "..." line) need to read
  stderr instead.

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
