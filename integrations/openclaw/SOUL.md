# MacParakeet skill for OpenClaw

> Thin OpenClaw-flavored entry point. The canonical integration story
> (vocabulary, JSON schemas, privacy posture, conventions) lives in
> [`../README.md`](../README.md). The CLI semver contract is at
> [`../../Sources/CLI/CHANGELOG.md`](../../Sources/CLI/CHANGELOG.md).
>
> The exact `SOUL.md` schema used by ClawHub may evolve. Treat the structure
> below as illustrative and adapt to the published spec at registration time.

## What this skill provides

Local speech-to-text and transcription for an OpenClaw agent running on Apple
Silicon. Wraps `macparakeet-cli` so an OpenClaw skill can:

- Transcribe a local audio/video file.
- Transcribe a YouTube URL.
- Search the user's prior dictation/transcription history.
- Run a prompt against a transcription (action items, summary, etc.).

All execution is local on the Apple Neural Engine. No cloud STT.

## Install (manual, today)

```bash
# 1. Install MacParakeet from https://macparakeet.com
# 2. Make the CLI available on $PATH
ln -s /Applications/MacParakeet.app/Contents/MacOS/macparakeet-cli \
      /usr/local/bin/macparakeet-cli
# 3. Verify
macparakeet-cli --version   # 1.0.0+
macparakeet-cli health --json
```

`brew install moona3k/tap/macparakeet-cli` is on the roadmap; the manual
symlink path will be deprecated once the tap ships.

## Capabilities (suggested SOUL bindings)

| Capability | Command |
|---|---|
| Transcribe a file | `macparakeet-cli transcribe <path> --format json` |
| Transcribe a YouTube URL | `macparakeet-cli transcribe <url> --format json` |
| List recent transcriptions | `macparakeet-cli history transcriptions --json` |
| Search transcriptions | `macparakeet-cli history search "<query>" --json` |
| Search dictations | `macparakeet-cli history search-transcriptions "<query>" --json` |
| Run a prompt on a transcription | `macparakeet-cli prompts run <prompt-name> --transcription <id> --provider <p> --api-key "$KEY" --model <m>` |
| Health probe (use in skill init) | `macparakeet-cli health --json` |

## Conventions

JSON to stdout when `--json` is set; human-readable errors to stderr;
non-zero exit on failure. JSON schemas are stable within a major CLI version
(semver, see [`CHANGELOG.md`](../../Sources/CLI/CHANGELOG.md)). Lookup args
accept full UUID, UUID prefix (>= 4 chars), or case-insensitive name.

For the full vocabulary, schema details, and privacy posture, see
[`../README.md`](../README.md).

## Status

Submitted to ClawHub: tracking via
<https://github.com/moona3k/macparakeet/issues> with the `integration` label.
