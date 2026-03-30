# ADR-006: Trial + License Key Activation

> Status: **HISTORICAL** — Superseded by open-source release (GPL-3.0) in v0.5.
> MacParakeet is now free with unlimited features. Trial and license activation removed.
> LemonSqueezy kept as $0 product for download tracking only.
> Date: 2026-02-12

## Context

MacParakeet needs a simple, local-first way to let users try the product and then unlock Pro permanently, without accounts.

The implementation uses:
- A time-based trial that allows full feature evaluation.
- A one-time purchase Pro unlock via license key activation.

## Decision

1. **Trial model**
   - Provide a **7-day full-feature trial**, starting at onboarding completion (not first launch — user doesn't lose trial days to permission setup).
   - After the trial ends (and without a valid Pro license), dictation and transcription are **blocked**.

2. **Pro unlock**
   - Pro is unlocked via **license key activation** (one-time purchase) via LemonSqueezy.
   - License validation is cached locally with an **unlimited grace period** — validate once on activation, never expire. One-time purchase = yours forever.

3. **No accounts**
   - No user accounts are required for trial or Pro.

## Consequences

### Positive

- Users can fully evaluate the product before paying.
- No accounts and no subscriptions.
- Clear gating boundary: transcribe features are either enabled (trial/unlocked) or disabled (locked).

### Negative

- Requires a licensing backend for activation/validation.
- Users without network access may be unable to activate Pro (trial still works until it expires).

