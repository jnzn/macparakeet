# Submission draft — `0xNyk/awesome-hermes-agent`

> **Status:** draft. Do not submit until the brew tap is live and the
> author confirms.

## Verify before submitting

1. Read the current `README.md` at <https://github.com/0xNyk/awesome-hermes-agent>
   to find:
   - Existing top-level categories (Voice / Speech / STT / Mac / etc.)
   - Required entry shape (title, link, description, badge?)
   - Contribution-policy section if any
2. Match the existing entry voice. Awesome lists are conventionally
   one-line entries: `- [name](url) — short description.`

## Probable category

Look for one of: **"Voice & Speech"**, **"Audio"**, **"Local"**,
**"Mac / macOS"**, **"Transcription"**. If none of those exists,
propose adding "Voice & Speech" with this entry as the first item.

## Entry to add

```markdown
- [macparakeet-cli](https://github.com/moona3k/macparakeet) — Local Parakeet TDT speech-to-text on the Apple Neural Engine. Swift-native CLI with persistent SQLite memory layer, prompt library, and stable JSON output. macOS 14.2+ Apple Silicon, GPL-3.0. `brew install moona3k/tap/macparakeet-cli`.
```

## PR title

```
Add macparakeet-cli — local Parakeet STT for Apple Silicon
```

## PR body

```markdown
## What

Adds [`macparakeet-cli`](https://github.com/moona3k/macparakeet) to
the awesome-hermes-agent list under **<category>**.

## Why it fits

`macparakeet-cli` is the canonical Swift-native CLI for Parakeet TDT
0.6B v3 on the Apple Neural Engine. It fills a documented gap in the
Hermes-on-Mac-mini stack:

- Whisper.cpp doesn't use the Neural Engine, so it's slow on Mac.
- The OpenAI Whisper API is fast but cloud-only and breaks the
  local-first posture Hermes encourages.
- `parakeet-mlx` (Python) doesn't carry persistence, prompts, or
  speaker diarization.

`macparakeet-cli` is:

- ~155× realtime, ~2.5% WER, ~66 MB memory per inference slot.
- Free + open-source (GPL-3.0).
- Stable: semver 1.0.0+ with a written compatibility policy.
- Skill-friendly: `--json` on every read-only command, stable schemas,
  exit codes, UUID-or-name lookup, errors to stderr.

## Hermes-flavored entry point

A thin Hermes README with an illustrative skill-manifest sketch lives
at [`integrations/hermes/README.md`](https://github.com/moona3k/macparakeet/blob/main/integrations/hermes/README.md).
Repo-root [`AGENTS.md`](https://github.com/moona3k/macparakeet/blob/main/AGENTS.md)
covers cross-agent coding-agent context.

## Author

Daniel Moon (@moona3k), maintainer of MacParakeet. Daily-driver user.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

## Submission checklist

- [ ] Brew tap live and `brew install moona3k/tap/macparakeet-cli` verified
- [ ] Target category in `awesome-hermes-agent` README confirmed
- [ ] Entry shape matches existing entries (one-line, `— em-dash`, period)
- [ ] PR opened against `0xNyk/awesome-hermes-agent:main`
- [ ] Linked from internal tracking issue (if any)
