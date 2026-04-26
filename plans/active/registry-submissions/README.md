# Registry submission drafts

Drafts of the content + PR bodies for submitting `macparakeet-cli` to
the relevant agent skill registries. **None of these have been
submitted.** Each requires user confirmation before opening an external
PR (per the standing "ask before visible-to-others actions" rule).

## Targets

| Registry | Repo | Type | Status |
|---|---|---|---|
| OpenClaw skill registry | [`openclaw/clawhub`](https://github.com/openclaw/clawhub) | Official skill registry (SOUL.md / package upload) | **Draft only** — verify exact submission schema before PR |
| Awesome OpenClaw | [`vincentkoc/awesome-openclaw`](https://github.com/vincentkoc/awesome-openclaw) | Curated awesome list (Markdown PR) | **Draft only** — verify category structure |
| Awesome OpenClaw Skills | [`VoltAgent/awesome-openclaw-skills`](https://github.com/VoltAgent/awesome-openclaw-skills) | Curated skill index (large, automated) | **Draft only** — likely auto-pulls from clawhub |
| Awesome Hermes Agent | [`0xNyk/awesome-hermes-agent`](https://github.com/0xNyk/awesome-hermes-agent) | Curated awesome list (Markdown PR) | **Draft only** — verify category structure |

## Submission order

Do NOT submit any of these before the brew tap is live, because each
submission's install path will read `brew install moona3k/tap/macparakeet-cli`.
Submitting earlier means people land on broken instructions.

Recommended sequence:

1. Cut the brew tap (see `scripts/dist/homebrew-tap-scaffold/HOWTO.md`).
2. Verify `brew install moona3k/tap/macparakeet-cli` works end-to-end.
3. Submit `awesome-hermes-agent` PR (lowest-friction, awesome-style).
4. Submit `awesome-openclaw` PR (same shape).
5. Submit to `openclaw/clawhub` (official registry — needs schema verification).
6. `VoltAgent/awesome-openclaw-skills` likely auto-syncs from clawhub —
   probably no separate submission needed; verify after step 5.

## Per-target drafts

- [`awesome-hermes-agent.md`](./awesome-hermes-agent.md)
- [`awesome-openclaw.md`](./awesome-openclaw.md)
- [`clawhub.md`](./clawhub.md)

## Cross-posting (after registry submissions)

Once the registry PRs are in flight, cross-post to:

- **r/LocalLLaMA** — title: *"Local Whisper alternative for Mac mini AI agents (Parakeet on the Neural Engine)"*
- **Hacker News** — title: *"Show HN: macparakeet-cli — canonical Parakeet CLI for Apple Silicon agents"*
- **OpenClaw Discord** — `#showcase` or equivalent
- **Nous Research Discord** — `#hermes-agent` or equivalent

Time these to land alongside v0.6.0 release for compounding momentum
(item #6 of the canonical plan). Don't fire community posts before the
brew tap is live.
