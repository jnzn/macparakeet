# Submission draft — `vincentkoc/awesome-openclaw`

> **Status:** draft. Do not submit until the brew tap is live and the
> author confirms.

## Verify before submitting

1. Read the current `README.md` at <https://github.com/vincentkoc/awesome-openclaw>
   to find:
   - Top-level categories (Voice / Speech / Plugins / Skills / Tools / etc.)
   - Entry shape conventions
   - Contribution policy
2. Note: this list is broader than skills only (covers frameworks,
   tooling, deployments). Pick the category that fits "an external CLI
   tool an OpenClaw skill can shell out to."

## Probable category

Best fits: **"Voice & Speech"** / **"Audio"** / **"Tools" / "Integrations"**
or **"Skills"** if there's a skills subsection. If a Voice category
doesn't exist, propose adding one with this entry as the first item.

## Entry to add

```markdown
- [macparakeet-cli](https://github.com/moona3k/macparakeet) — Local Parakeet TDT speech-to-text on the Apple Neural Engine. Swift-native CLI for an OpenClaw skill to shell out to: persistent SQLite memory, prompt library, JSON output. OpenClaw entry point at [`integrations/openclaw/SOUL.md`](https://github.com/moona3k/macparakeet/blob/main/integrations/openclaw/SOUL.md). macOS 14.2+ Apple Silicon, GPL-3.0. `brew install moona3k/tap/macparakeet-cli`.
```

## PR title

```
Add macparakeet-cli — local Parakeet STT for OpenClaw on Apple Silicon
```

## PR body

```markdown
## What

Adds [`macparakeet-cli`](https://github.com/moona3k/macparakeet) to
awesome-openclaw under **<category>**.

## Why it fits

OpenClaw is increasingly deployed as a daemon on Apple Silicon Mac
minis. The voice/STT slot in that stack is currently underserved:
Whisper.cpp doesn't use the Neural Engine; the OpenAI Whisper API
breaks local-first; `parakeet-mlx` is Python-only and lacks the
persistence/prompts an OpenClaw skill wants.

`macparakeet-cli` is the canonical Swift-native CLI for Parakeet TDT
on the Apple Neural Engine — ~155× realtime, ~2.5% WER, ~66 MB memory.
Free, GPL-3.0, semver-stable (1.0.0+) with a written compatibility
policy.

For OpenClaw skill authors:

- Stable JSON output (`--json` on every read-only command, ISO-8601
  datetimes, sorted keys).
- UUID-or-name lookup with `.notFound`/`.ambiguous` error classes.
- Exit codes: 0 success, non-zero failure, errors to stderr only.
- Persistent SQLite at `~/Library/Application Support/MacParakeet/macparakeet.db`
  — lets a skill recall prior dictations/transcriptions across runs.

## OpenClaw entry point

[`integrations/openclaw/SOUL.md`](https://github.com/moona3k/macparakeet/blob/main/integrations/openclaw/SOUL.md)
— install, capabilities table, conventions. Adapt at clawhub
registration.

## Author

Daniel Moon (@moona3k), maintainer of MacParakeet.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

## Submission checklist

- [ ] Brew tap live and `brew install moona3k/tap/macparakeet-cli` verified
- [ ] Target category in `awesome-openclaw` README confirmed
- [ ] Entry shape matches existing entries
- [ ] PR opened against `vincentkoc/awesome-openclaw:main`
