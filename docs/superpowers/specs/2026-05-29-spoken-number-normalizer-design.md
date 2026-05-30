# Spoken Number Normalizer (words → digits) — Design

> Status: **APPROVED** (2026-05-29). Implementation pending.
> Related: ADR-004 (deterministic pipeline); `Sources/MacParakeetCore/TextProcessing/`.
> Inspired by the `justingonz96-creator` fork's LLM number refiner — we deliberately chose a **deterministic** approach instead.

## Context

Parakeet STT emits numbers as words ("twenty five"). The text-processing pipeline
is deterministic (filler removal, custom words, snippets) and currently has **no
number handling**, so spoken numbers pass through as words and the user must
hand-correct them.

## Decision: deterministic "everything → digits"

A pure deterministic normalizer converts every spoken cardinal/decimal number to
digits. Chosen over the fork's LLM refiner because, for "everything → digits", the
transformation is well-defined — so deterministic is instant, local, predictable,
and dependency-free, vs the LLM's latency / non-determinism / safety-gate
complexity. (An optional LLM "smart" mode remains a future option if context
awareness is ever wanted.)

## Scope (v1)

- **Cardinals incl. compounds:** `"twenty five"→25`, `"three hundred forty two"→342`,
  `"two thousand twenty four"→2024`, `"a hundred"→100`, "and" connective
  (`"three hundred and five"→305`). Scale words: hundred / thousand / million / billion.
- **Decimals via "point":** `"three point five"→3.5`.
- **Correct grouping:** composable runs merge (`"twenty five"`=25); non-composable
  adjacent runs stay separate (`"one two three"`=`1 2 3`).
- **Case/hyphen-insensitive:** `"Twenty-five"`→`25`.
- **Aggressive by design:** `"two reasons"→"2 reasons"` (the chosen behavior).

## Out of scope (v1 — noted follow-ups)

- **Ordinals** (`"second"`/`"third"` are homonyms — "wait a second"); needs context care.
- **Currency symbols** (`$`), **time colons** (`3:30`), negatives, fractions —
  these are *formatting* beyond words→digits.

## Components / boundaries

- **`NumberNormalizer`** — pure `static func normalize(_ text: String) -> String`
  in `Sources/MacParakeetCore/TextProcessing/`. No state, no dependencies.
  Tokenize → detect number-word runs → compose each run's value → emit digits,
  preserving surrounding text/whitespace/punctuation.
- **`TextProcessingPipeline`** — new deterministic step that calls
  `NumberNormalizer`, gated by a setting.
- **Settings** — a "Convert spoken numbers to digits" toggle (UserDefaults-backed
  via `SettingsViewModel`), default **ON**.

## Testing

Pure logic → TDD with a fixture table: compounds, decimals, "a"/"and", scale
words, non-composable adjacent runs, mixed prose, no-number passthrough,
case/hyphen variants, punctuation adjacency.

## Manual verification

Dictate *"I need twenty five dollars and three point five liters"* →
*"I need 25 dollars and 3.5 liters"*. Toggle off → words pass through unchanged.
