# Submission draft — `openclaw/clawhub` (the official OpenClaw skill registry)

> **Status:** draft, schema-uncertain. Do not submit until the brew tap
> is live AND the actual ClawHub skill manifest schema is verified.

## What's uncertain

ClawHub appears to be the **official skill registry** for OpenClaw —
not just a curated awesome list. Skills there are typically packaged as
SOUL.md plus supporting files, with a documented submission flow
(possibly via the OpenClaw CLI: `openclaw skill publish` or similar) or
via PR to `openclaw/clawhub`.

Before submitting, verify:

1. Read <https://docs.openclaw.ai/tools/clawhub> for the canonical
   submission flow.
2. Inspect <https://github.com/openclaw/clawhub> for repo structure.
   Are skills bundled per-directory? Is there a manifest schema?
3. Check whether submission is via CLI tooling, PR, or web upload at
   <https://clawhub.ai>.
4. Check whether submission requires native installation of the
   OpenClaw CLI to package + sign the skill.

The thin scaffold at [`integrations/openclaw/SOUL.md`](https://github.com/moona3k/macparakeet/blob/main/integrations/openclaw/SOUL.md)
self-marks as "illustrative — adapt at registration time" precisely
because the schema may have evolved post-OpenAI acquisition.

## Likely submission shape

If ClawHub follows the typical skill-manifest pattern, the skill would be:

```
macparakeet-stt/
├── SOUL.md                # Skill manifest (description, capabilities, usage)
├── install.sh             # Installs the macparakeet-cli host binary
├── README.md              # Human-facing intro
└── examples/              # Example invocations
    ├── transcribe.md
    ├── search-history.md
    └── run-prompt.md
```

`SOUL.md` content would mirror our `integrations/openclaw/SOUL.md`
but adapted to whatever frontmatter fields ClawHub requires
(e.g., `name:`, `version:`, `author:`, `tags:`, `requires:`).

## Probable PR title (if PR-based submission)

```
Add macparakeet-stt — local Parakeet STT skill (Apple Silicon)
```

## Probable PR body skeleton

```markdown
## Skill: macparakeet-stt

Local Parakeet TDT speech-to-text for OpenClaw on Apple Silicon.
Wraps [macparakeet-cli](https://github.com/moona3k/macparakeet)
(GPL-3.0, semver 1.0+).

## Capabilities

- Transcribe local audio/video files (MP3 / WAV / MP4 / MOV / WebM / ...)
- Transcribe YouTube URLs
- Search the user's prior dictation/transcription history
- Run a prompt against a transcription (action items, summaries, ...)

## Requires

- macOS 14.2+ on Apple Silicon (M1, M2, M3, M4)
- `brew install moona3k/tap/macparakeet-cli` (the host binary)

## Privacy

All execution local. STT runs on the Apple Neural Engine. No audio
or transcript content is sent over the network unless the user
explicitly invokes the prompt-runner with a cloud LLM provider.

## Source

- Skill scaffold: <https://github.com/moona3k/macparakeet/blob/main/integrations/openclaw/SOUL.md>
- Host binary: <https://github.com/moona3k/macparakeet>
- Compatibility policy: <https://github.com/moona3k/macparakeet/blob/main/Sources/CLI/CHANGELOG.md>
- Author: @moona3k

🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

## Submission checklist

- [ ] Brew tap live and `brew install moona3k/tap/macparakeet-cli` verified
- [ ] ClawHub submission flow confirmed (CLI / PR / web)
- [ ] SOUL.md schema fields confirmed against current spec
- [ ] If CLI-based: OpenClaw CLI installed locally and skill packaged
- [ ] PR / submission opened
- [ ] `VoltAgent/awesome-openclaw-skills` checked — likely auto-syncs
      from clawhub; only submit there if it doesn't
