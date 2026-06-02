# Spoken-Text Smart Formatting (Deterministic Normalizer Chain)

> Status: **PROPOSAL** — design approved in conversation 2026-06-02; implementation pending.
> Related: ADR-004 (deterministic text processing), `NumberNormalizer`, `TextProcessingPipeline`, `TextRefinementService`.

## Problem

The only always-applied formatting MacParakeet has today is `NumberNormalizer`
(spoken cardinals → digits), and it only runs in Clean mode. Everything else —
currency, dates, symbols, punctuation — depends on the optional LLM formatter,
which is slow (a minute+ per long paragraph through a local model), only
*usually* follows instructions, and blocks the paste.

The owner wants formatting rules that are **always applied, instantly**:
currency, numbers, ordinals, dates, times, symbols, units, and guarded
punctuation. Parakeet itself cannot take instructions (it is an ASR model, not
an LLM), so these rules belong in the deterministic pipeline.

## Decision

Build a **chain of pure normalizers** (same pattern as `NumberNormalizer`:
static functions, no dependencies, no state) applied at the existing Step 2.4
slot of `TextProcessingPipeline`, in dependency order:

```
cardinals/decimals → years → ordinals → currency → percent/units →
dates → times → phone runs → email/URL → symbols → punctuation (guarded)
```

Ordering rationale:
- Years ("twenty twenty six" → 2026) must be recognized **before** general
  cardinal merging would mangle them into "20 20 6".
- Currency/percent/units/dates/times operate on digits, so they run **after**
  the number stages ("twenty five dollars" → "25 dollars" → "$25").
- Symbols and punctuation run last, on otherwise-final text.

One configuration toggle — **"Smart formatting"** in Vocabulary — controls the
whole chain. The existing "Normalize numbers" setting folds into it (its
UserDefaults key is migrated; see §Configuration). No per-category toggles in
v1 (single-user PDX edition; add granularity only when actually wanted).

**Mode requirement:** the chain runs in the deterministic pipeline, i.e. only
in **Clean** processing mode. Rollout for the owner: switch processing mode to
Clean; the slow LLM formatter then becomes optional rather than the only
cleanup.

## Rules

Every example below is a required test case. The normalizers are conservative
by design: when a guard is not met, text passes through unchanged.

### 1. Cardinals and decimals (existing `NumberNormalizer`, unchanged)

| Spoken | Output |
|---|---|
| "twenty five people" | `25 people` |
| "three hundred forty two" | `342` |
| "three point five" | `3.5` |
| "one two three" | `1 2 3` |

### 2. Years

Runs before cardinal merging. Guard: two-part year pattern only.

| Spoken | Output |
|---|---|
| "twenty twenty six" | `2026` |
| "nineteen ninety nine" | `1999` |
| "twenty twenty" | `2020` |
| "back in twenty twenty four" | `back in 2024` |

### 3. Ordinals (outside dates)

Guard: compound ordinals and tenth+ always convert; standalone
first–ninth stay words ("first of all", "wait a second" must never break).
Full suffixes (st/nd/rd/th) in non-date text.

| Spoken | Output |
|---|---|
| "the twenty fifth item" | `the 25th item` |
| "their thirty third anniversary" | `their 33rd anniversary` |
| "the twelfth floor" | `the 12th floor` |
| "first of all" | `first of all` (unchanged — guard) |
| "wait a second" | `wait a second` (unchanged — guard) |

### 4. Currency

| Spoken | Output |
|---|---|
| "twenty five dollars" | `$25` |
| "three dollars and fifty cents" | `$3.50` |
| "fifty bucks" | `$50` |
| "one point five million dollars" | `$1.5 million` |
| "twenty euros" | `€20` |
| "five thousand won" | `₩5,000` |
| "five hundred yen" | `¥500` |
| "ten pounds" | `ten pounds` (unchanged — £ vs weight is ambiguous; excluded from v1) |

### 5. Percentages, degrees, units

| Spoken | Output |
|---|---|
| "fifty percent" | `50%` |
| "three point five percent" | `3.5%` |
| "seventy two degrees" | `72°` |
| "thirty seven degrees celsius" | `37°C` |
| "ninety eight degrees fahrenheit" | `98°F` |
| "five kilometers" | `5 km` |
| "six feet" | `6 ft` |
| "ten miles" | `10 mi` |
| "five hundred megabytes" | `500 MB` |
| "sixteen gigabytes" | `16 GB` |
| "two terabytes" | `2 TB` |
| "one half" | `1/2` |
| "three quarters" | `3/4` |

### 6. Dates (owner's format rules)

Suffix rule (dates only): keep **st / nd / rd**, drop **th** —
"second" → `2nd` but "fourth" → `4`.

| Spoken | Output |
|---|---|
| "june first" | `June 1st` |
| "june second" | `June 2nd` |
| "june third" | `June 3rd` |
| "june fourth" | `June 4` |
| "june fifth" | `June 5` |
| "june twenty first" | `June 21st` |
| "june twenty fifth" | `June 25` |
| "june second twenty twenty six" | `June 2nd, 2026` |
| "the fifth of may" | `May 5` |
| "june two" | `June 2nd` (cardinal day in month context) |

**ISO trigger** — year first + spoken "hyphen" **or** "dash" separators:

| Spoken | Output |
|---|---|
| "twenty twenty six hyphen june hyphen second" | `2026-06-02` |
| "twenty twenty six dash june dash second" | `2026-06-02` |
| "twenty twenty six dash december dash thirty first" | `2026-12-31` |

### 7. Times

Guard: requires am / pm / o'clock anchor. Bare "three thirty" stays words.

| Spoken | Output |
|---|---|
| "three thirty pm" | `3:30 PM` |
| "nine a m" | `9:00 AM` |
| "three o'clock" | `3:00` |
| "twelve fifteen pm" | `12:15 PM` |
| "there were three thirty year olds" | unchanged (no anchor) |

### 8. Phone-style digit runs

Guard: exactly 7 or 10 consecutive single spoken digits.

| Spoken | Output |
|---|---|
| "five five five one two one two" | `555-1212` |
| "six one seven five five five one two one two" | `617-555-1212` |
| "one two three" | `1 2 3` (3 digits — not a phone pattern) |

### 9. Email and URLs

Guard: requires a TLD tail (com / net / org / io / gov / edu).

| Spoken | Output |
|---|---|
| "john at gmail dot com" | `john@gmail.com` |
| "support at macparakeet dot com" | `support@macparakeet.com` |
| "example dot com slash docs" | `example.com/docs` |
| "I'm at home" | unchanged ("at" only converts with a dot-TLD tail) |

### 10. Symbols (always — unambiguous words only)

| Spoken | Output |
|---|---|
| "hashtag standup" | `#standup` |
| "at sign" | `@` |
| "ampersand" | `&` |
| "asterisk" | `*` |
| "underscore" | `_` |
| "tilde" | `~` |
| "backslash" | `\` |
| "pound sign" | `#` |
| "dollar sign" | `$` |
| "percent sign" | `%` |
| "self hyphen aware" | `self-aware` ("hyphen" joins adjacent words) |

Excluded (ambiguous, available via Custom Words): "dash", "plus", "pipe",
"slash" (outside URL context), "equals".

### 11. Punctuation voice commands (guarded)

Always convert (multi-word / unambiguous): "question mark" → `?`,
"exclamation point" / "exclamation mark" → `!`, "semicolon" → `;`,
"open quote" / "close quote" → `"`.

End-of-dictation only: "period" → `.`, "comma" → `,` — converts only when it
is the final word of the dictation.

| Spoken | Output |
|---|---|
| "ship it today period" | `Ship it today.` |
| "the trial period ended" | `The trial period ended` (mid-text "period" — unchanged, no punctuation added) |
| "is this right question mark" | `Is this right?` |
| "hashtag standup question mark" | `#standup?` |

Excluded (stay words, available via Custom Words): "colon", "new line",
"new paragraph".

## Out of Scope (ambiguous — rejected for deterministic handling)

| Rule | Why rejected |
|---|---|
| Ranges ("five to ten" → 5–10) | "I gave five to ten people" — preposition vs range |
| Bare "at" → @ | "I'm at home" |
| Math ("five times three" → 5×3) | "I called five times" |
| "pounds" → £ | Weight vs currency for a US-based user |
| Per-category toggles | YAGNI for a single-user edition |

## Architecture

```
Sources/MacParakeetCore/TextProcessing/
├── NumberNormalizer.swift            (existing — cardinals/decimals)
├── Normalizers/
│   ├── YearNormalizer.swift
│   ├── OrdinalNormalizer.swift
│   ├── CurrencyNormalizer.swift
│   ├── UnitNormalizer.swift          (percent, degrees, measurements, data, fractions)
│   ├── DateNormalizer.swift          (owner format rules + ISO trigger)
│   ├── TimeNormalizer.swift
│   ├── PhoneRunNormalizer.swift
│   ├── EmailURLNormalizer.swift
│   ├── SymbolNormalizer.swift
│   └── PunctuationNormalizer.swift   (guarded; "period"/"comma" convert only as the final word of the text)
└── SpokenTextFormatter.swift         (the chain — single entry point)
```

- Each normalizer: `public enum X { public static func normalize(_ text: String) -> String }`,
  pure function, no dependencies (mirrors `NumberNormalizer`).
- `SpokenTextFormatter.format(_ text: String) -> String` runs the chain in the
  order defined above. This is the only symbol `TextProcessingPipeline` calls.
- `TextProcessingPipeline.process` replaces its `normalizeNumbers:` parameter
  with `smartFormatting:`; Step 2.4 calls `SpokenTextFormatter.format` instead
  of `NumberNormalizer.normalize` directly.
- Terminal symbol expansion (Step 2.5, `isTerminalProfile`) is unchanged and
  still terminal-profile-only.

## Configuration

- New key `smartFormattingEnabled` in `UserDefaultsAppRuntimePreferences`
  (default **true**).
- Migration: if the legacy `normalizeNumbers` key is explicitly `false`, seed
  `smartFormattingEnabled` to `false` (respect a prior opt-out), then ignore
  the legacy key.
- Vocabulary UI: the "Normalize numbers" toggle becomes **"Smart formatting"**
  with updated description text listing the rule categories.
- `AppRuntimePreferencesProtocol` gains `var smartFormattingEnabled: Bool`;
  `normalizeNumbers` is removed from the protocol (single-user edition; no
  external compat concern).

## AI Formatter Prompt Cleanup

The LLM formatter runs **after** the deterministic pipeline
(`DictationService.swift`: `refine(...)` then `formatTranscriptIfNeeded(...)`),
so it receives already-formatted text (`$25`, `June 2nd`, `50%`). Prompts must
stop instructing the LLM to do work the chain now owns — and must explicitly
tell it to preserve the chain's output.

### Shipped default template (`AIFormatter.defaultPromptTemplate` → v3)

- Remove "and filler sounds" from the repeated-words rule (fillers are
  deterministic in Clean mode; keep "remove repeated words" — that is still
  LLM work).
- Add a new rule:
  > Numbers, dates, times, currency, percentages, and symbols are already
  > formatted correctly — preserve them exactly as written (e.g. $25,
  > June 2nd, 3:30 PM, 50%, #standup). Do not spell them out or reformat them.
- Fold the v2 template into v3 via `normalizedPromptTemplate` (same mechanism
  as the existing legacy-v1 fold) so users on the old default get v3
  automatically.

### Sample per-app profiles (`AppProfile.defaults`)

- Email sample: remove "remove filler words" and "write spoken numbers as
  digits"; add the preserve-formatting rule.
- Notes / Chat samples: add the preserve-formatting rule (no overlapping
  rules to remove).

### Owner's stored prompts (user data — rollout steps, not code)

- Custom `aiFormatterPrompt` (UserDefaults): no overlapping rules found; add
  the preserve-formatting rule (or reset to the new default).
- Seeded per-app profiles (GRDB, from the gitignored local seed): review each
  prompt in the profile editor; remove number/filler instructions; add the
  preserve-formatting rule. Also update the local seed file so future
  reinstalls stay clean.

## Testing

- One XCTest class per normalizer; every table row above is a test case.
- `AIFormatter.normalizedPromptTemplate` folds the v2 default into v3 (same
  test pattern as the existing legacy-v1 fold test).
- Chain-order integration tests in `SpokenTextFormatterTests`:
  - "twenty five dollars on june second" → `$25 on June 2nd`
  - "fifty percent by three thirty pm period" → `50% by 3:30 PM.`
  - "twenty twenty six dash june dash second at nine a m" → `2026-06-02 at 9:00 AM`
- Pass-through tests (guards): every "unchanged" row above.
- `TextProcessingPipeline` integration: smart formatting on/off, raw vs clean
  mode, terminal profile interaction.

## Owner Rollout (after implementation)

1. Vocabulary → Processing mode → **Clean**
2. Vocabulary → **Smart formatting** → on (default)
3. Settings → **AI Formatter** → off (or keep with a small fast model for prose polish)
4. If keeping the AI Formatter: update the custom prompt and seeded per-app
   profiles per §AI Formatter Prompt Cleanup (remove number/filler rules, add
   the preserve-formatting rule)
5. Result: every dictation pastes in ~1 second with all formatting rules applied
