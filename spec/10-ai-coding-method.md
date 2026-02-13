# 10 - AI Coding Method

> Status: **ACTIVE** - Authoritative, current

## Purpose

This document defines how MacParakeet uses specs to drive implementation with coding agents.

Goal: reduce ambiguity, prevent drift, and make generated code maintainable over time.

## Philosophy

1. Specs are executable intent, not long-form notes.
2. Prose explains why; machine-readable artifacts define what.
3. Every behavior change must be traceable from requirement -> code -> test.
4. Determinism beats cleverness for core product flows.

## Context Zone (Probability Control)

Coding agents sample actions from context. In practice: weak context spreads probability mass across many plausible edits; strong context concentrates probability mass on valid edits.

The "context zone" is the bounded set of behaviors allowed by current requirements and contracts.

For every behavior change, define zone boundaries up front:

1. Target requirement IDs in `requirements.yaml`.
2. "Must not change" invariants in contracts/state machines.
3. Allowed transition/path updates (if flow logic changes).
4. Mapped tests that verify in-zone behavior and reject out-of-zone drift.

Any out-of-zone behavior change must be explicitly called out and added to kernel artifacts before implementation.

## External Evidence (Rationale)

The context-zone model is consistent with current research and vendor guidance:

1. Long-context reliability degrades with poor information placement ("lost in the middle").
   - https://arxiv.org/abs/2307.03172
2. Prompt structure and query placement materially affect long-context performance.
   - https://docs.anthropic.com/en/docs/build-with-claude/prompt-engineering/long-context-tips
3. Simpler, structured SWE workflows can outperform heavier autonomous setups.
   - https://arxiv.org/abs/2407.01489
4. Tool-grounded reasoning loops improve error recovery and reduce hallucination-style failures.
   - https://arxiv.org/abs/2210.03629
5. SWE benchmark results can be inflated by memorization/contamination; eval hygiene matters.
   - https://openai.com/index/introducing-swe-bench-verified/
   - https://arxiv.org/abs/2506.12286

Inference: strong boundary artifacts (requirements/contracts/state machines/tests) improve the probability that agent actions remain in-zone.

## Decision

Adopt a two-layer spec model:

1. **Narrative layer (existing):** `00-09` docs and ADRs for product context and rationale.
2. **Kernel layer (new, minimal):** structured requirements/contracts/state machines for implementation.

The kernel layer is optimized for coding agents and review automation.

## Source-of-Truth Order

When artifacts conflict, precedence is:

1. `spec/kernel/requirements.yaml`
2. `spec/kernel/contracts/*.yaml`
3. `spec/kernel/state_machines/*.yaml`
4. Accepted ADRs in `spec/adr/`
5. Narrative docs `spec/00-09`
6. Existing code/comments

If conflict is found, update lower-precedence artifacts in the same change.

## Kernel Schema (Minimal)

Create and maintain:

- `spec/kernel/requirements.yaml`
- `spec/kernel/contracts/*.yaml`
- `spec/kernel/state_machines/*.yaml`
- `spec/kernel/traceability.md`

### Requirement Shape

Each requirement must include:

- `id` (stable, e.g. `REQ-F11-001`)
- `title`
- `source` (feature/ADR reference)
- `priority`
- `status`
- `acceptance` (testable, explicit)

Allowed values:

- `priority`: `p0 | p1 | p2 | p3`
- `status`: `proposed | active | implemented | deprecated | historical`

Requirement ID format:

- `REQ-<feature>-<nnn>` where `<feature>` is stable (e.g. `F11`) and `<nnn>` is zero-padded (`001`, `002`, ...).

Example:

```yaml
version: 1
requirements:
  - id: REQ-F11-001
    title: YouTube URL transcription succeeds for valid YouTube URLs
    source: spec/02-features.md#F11
    priority: p0
    status: active
    acceptance:
      - Given a valid YouTube URL, when transcribeURL is called, then a completed transcription is returned
      - Progress emits download and transcription percentages
```

### Contract Shape

Each contract must include:

- `input`
- `output`
- `errors` (stable error codes)
- `invariants`

Example:

```yaml
name: transcribe_url
input:
  url: string
  onProgress: optional_callback_string
output:
  transcription:
    id: uuid
    status: completed
errors:
  - invalid_url
  - video_not_found
  - download_failed
  - timed_out
invariants:
  - sourceURL must equal request url for URL-based transcriptions
```

### State Machine Shape

Each flow machine must include:

- `states`
- `events`
- `transitions`
- `terminal_states`

Example:

```yaml
name: dictation_flow
initial: idle
states: [idle, recording, processing, success, error]
events: [start_recording, stop_recording, stt_ok, stt_fail]
transitions:
  - { from: idle, event: start_recording, to: recording }
  - { from: recording, event: stop_recording, to: processing }
  - { from: processing, event: stt_ok, to: success }
  - { from: processing, event: stt_fail, to: error }
terminal_states: [success, error]
```

### Traceability Format

`spec/kernel/traceability.md` must use this table:

| Requirement ID | Contract(s) | Implementation | Tests | Status |
|---|---|---|---|---|
| `REQ-F11-001` | `contracts/transcribe_url.yaml` | `Sources/MacParakeetCore/Services/YouTubeDownloader.swift` | `Tests/MacParakeetTests/Services/YouTubeDownloaderTests.swift` | `active` |

Rules:

1. One row per active requirement.
2. `Implementation` and `Tests` must be concrete file paths.
3. If requirement is `implemented`, at least one mapped test must exist.

## Implementation Workflow

For any behavior change:

1. Select target requirement IDs.
2. Read linked contract/state machine.
3. Implement smallest change satisfying acceptance.
4. Add/update tests mapped to requirement IDs.
5. Update `traceability.md`.
6. Run tests per test-scope policy.

No feature work is complete without requirement + test mapping.

## Test-Scope Policy

During development:

1. Run focused tests for touched requirements (fast loop).
2. Run broader local suite when touching shared/core flows.

Before merge:

1. Run `swift test` locally or in CI for full-suite verification.

## Definition of Done

### PR-Ready DoD

A change is PR-ready only when all are true:

1. Requirement entries updated (`requirements.yaml`).
2. Contracts/state machine updated if behavior changed.
3. Code + tests linked in `traceability.md`.
4. Mapped tests pass for affected requirements.
5. Precedence conflicts reconciled.

### Merge Gate

A change is merge-complete only when all are true:

1. PR-Ready DoD is satisfied.
2. Full test suite (`swift test`) passes in CI.
3. Requirement status is updated appropriately (`active` or `implemented`).

## Coding Rules for Agents

1. Do not implement against prose alone if a kernel requirement exists.
2. Do not introduce new runtime behavior without requirement IDs.
3. Prefer explicit error codes over free-form strings for core flows.
4. Preserve local-first/privacy ADR constraints unless an ADR changes.

### Agent Discretion (Bounded)

Agents are expected to use judgment, but within explicit constraints:

1. For behavior changes, kernel workflow is mandatory (requirements + contracts/state machines as applicable + traceability + mapped tests).
2. For non-behavioral changes (formatting, comments, renames, internal refactors with unchanged behavior), agents may use a lighter process.
3. If a materially better third approach is identified, propose it and update this method before adopting it broadly.
4. Prefer the simplest process that preserves correctness, traceability, and ADR constraints.

## Anti-Patterns

Avoid:

1. "Spec says maybe" language in implementation contracts.
2. Requirement IDs that change over time.
3. Tests with no requirement mapping.
4. Silent behavior changes not reflected in kernel artifacts.

## Rollout Plan

### Phase 1 (now)

1. Add this methodology.
2. Start kernel for highest-risk flows: dictation lifecycle, transcription lifecycle, YouTube URL flow, export flow.
3. Assign owner: repository maintainers.

Success metric:

- At least 10 active requirements represented in kernel artifacts.

### Phase 2

1. Enforce traceability in PR checklist.
2. Add lightweight CI check for missing requirement/test mapping.

Success metric:

- CI fails on unmapped active requirements.

### Phase 3

1. Expand kernel coverage to all active features.
2. Keep narrative docs concise and linked to kernel IDs.

Success metric:

- 100% of active features map to kernel requirements and tests.

## Relationship to Existing Specs

Narrative docs remain the human-facing product and architecture guide.
The kernel is the implementation authority for coding agents.

Both are required:

- Narrative without kernel -> ambiguity and drift.
- Kernel without narrative -> local optimization, poor product decisions.
