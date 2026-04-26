# Integrations -- using `macparakeet-cli` from your agent

> If you are a *coding agent working in this repo*, read
> [`/AGENTS.md`](../AGENTS.md) instead. This directory is for agents (and the
> people running them) that want to *call* `macparakeet-cli` to add local STT
> to their stack.

## What `macparakeet-cli` gives your agent

- **Local Parakeet TDT speech-to-text** at ~155x realtime on Apple Silicon
  with ~2.5% WER, running on the Neural Engine. No cloud, no API keys, no
  per-minute charges.
- **Audio + video file transcription** -- accepts MP3 / WAV / MP4 / MOV /
  WebM / etc. via the bundled FFmpeg.
- **YouTube transcription** via bundled yt-dlp.
- **Persistent SQLite memory layer** -- everything transcribed is queryable
  later: dictation history, transcriptions, prompt outputs.
- **Prompt library + LLM-backed summarization** -- bring your own provider
  (OpenAI, Anthropic, Ollama, LM Studio, OpenAI-compatible local), or skip
  the LLM entirely and consume raw transcripts.
- **JSON output everywhere** -- every read-only command supports `--json`
  with a stable schema (see
  [`../Sources/CLI/CHANGELOG.md`](../Sources/CLI/CHANGELOG.md) for the
  contract).

## Install

**Today:** the CLI ships inside the macOS app bundle. After installing
[MacParakeet](https://macparakeet.com), the binary is at:

```bash
/Applications/MacParakeet.app/Contents/MacOS/macparakeet-cli --help
```

For convenience, symlink it onto your `$PATH`:

```bash
ln -s /Applications/MacParakeet.app/Contents/MacOS/macparakeet-cli \
      /usr/local/bin/macparakeet-cli
```

**On the roadmap:** `brew install moona3k/tap/macparakeet-cli` for a
standalone install with no `.app` required. See
[`../plans/active/cli-as-canonical-parakeet-surface.md`](../plans/active/cli-as-canonical-parakeet-surface.md).

## Why Apple Silicon specifically

Parakeet TDT runs on the Apple Neural Engine via CoreML. That is the entire
performance story: 155x realtime, ~66 MB working memory per inference slot.
On VPS hosts without Apple Silicon (typical for cloud-deployed agent
daemons), Parakeet falls back to CPU and Whisper.cpp is competitive. **The
compelling deployment target is a Mac mini (M1+) running headless** as a
personal AI compute box -- unified memory, ANE, ~8W idle, silent.

## Common commands (the agent vocabulary)

Every command below produces JSON when `--json` is passed. Schemas are stable
per [`../Sources/CLI/CHANGELOG.md`](../Sources/CLI/CHANGELOG.md).

### Health probe (run at agent init)

```bash
macparakeet-cli health --json
```

Reports model readiness, database accessibility, and binary deps (FFmpeg,
yt-dlp). Use this before issuing real work.

### Transcribe a file

```bash
macparakeet-cli transcribe /path/to/audio.mp3 --format json
```

### Transcribe a YouTube video

```bash
macparakeet-cli transcribe "https://www.youtube.com/watch?v=..." --format json
```

### Look up past transcriptions

```bash
macparakeet-cli history transcriptions --json
macparakeet-cli history search "design review" --json
```

### Search past dictations

```bash
macparakeet-cli history dictations --json
macparakeet-cli history search-transcriptions "what did I say about" --json
```

### List or run a prompt against a transcription

```bash
macparakeet-cli prompts list --json
macparakeet-cli prompts run "Action items" \
  --transcription <id-or-prefix> \
  --provider anthropic --api-key "$ANTHROPIC_API_KEY" \
  --model claude-sonnet-4-6
```

`<id-or-prefix>` accepts a full UUID, a UUID prefix (>= 4 chars), or the
case-insensitive name. Ambiguous prefixes return a `.ambiguous` error so the
agent can re-prompt the user.

## Conventions

- **Exit codes:** `0` on success; non-zero on failure with a one-line stderr
  message. JSON output never goes to stderr.
- **Lookups:** records that take an `<id-or-name>` argument accept full UUID,
  UUID prefix (>= 4 chars), or case-insensitive name. Ambiguous prefixes
  produce a `.ambiguous` error; missing records produce `.notFound`.
- **Privacy:** STT and database access never touch the network. The only
  network egress paths are: YouTube downloads (yt-dlp), optional cloud LLM
  provider calls (only when `prompts run --provider <cloud>`), and Sparkle
  update checks (app, not CLI).
- **Concurrency:** the STT scheduler reserves one slot for dictation and
  shares a second slot for meeting / batch work (ADR-016). Multiple
  concurrent CLI calls share the background slot; expect serial transcription
  of multi-file batches.

## Per-ecosystem entry points

- **OpenClaw:** [`openclaw/SOUL.md`](./openclaw/SOUL.md)
- **Hermes Agent:** [`hermes/README.md`](./hermes/README.md)
- **Codex CLI / Claude Code / generic AGENTS.md consumers:** read
  [`/AGENTS.md`](../AGENTS.md) at the repo root, plus this file for the CLI
  vocabulary.

## Reporting issues

Open an issue at <https://github.com/moona3k/macparakeet/issues> with the
`integration` label. Include the agent platform, the CLI version
(`macparakeet-cli --version`), and a minimal repro.
