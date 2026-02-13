# Qwen3-8B Integration Checklist (Execution Order)

Status: Active
Owner: Core app team
Updated: 2026-02-13

## Objective

Ship production-ready local LLM integration for refinement + command mode using Qwen3-8B with robust fallback behavior.

## PR Slice Plan

1. **Foundation seam**
- Add `LLMServiceProtocol`, request/response models, and error taxonomy.
- Add no-op/mock implementation for tests.
- Wire dependency injection in call sites.

2. **Fallback-safe wiring**
- Integrate deterministic-first -> LLM-second flow for formal/email/code.
- Implement timeout + empty-output guards.
- Ensure fallback returns deterministic-safe output.

3. **Qwen runtime integration**
- Add `MLXQwenService` implementation for `mlx-swift-lm`.
- Implement lazy load + idle unload lifecycle.
- Add model availability and load-state handling.

4. **Command mode integration**
- Route selected text + spoken command through shared LLM seam.
- Preserve current selection-replace UX behavior and error paths.

5. **Transcript chat baseline scaffolding**
- Add transcript context assembly utilities (bounded chunking/truncation).
- Add chat request pathway behind feature flag if UI not ready.

6. **Benchmark + hardening**
- Run benchmark protocol in `docs/planning/2026-02-qwen3-8b-benchmark-plan.md`.
- Tune prompt templates and timeout budgets.
- Fix memory/lifecycle edge cases discovered in test runs.

## Tests Required per Slice

1. Unit: prompt and fallback behavior.
2. Unit: service lifecycle (load, warm invoke, unload).
3. Integration: dictation AI mode path with mock LLM.
4. Integration: command mode transform path with mock LLM.
5. Regression: deterministic mode unchanged.

## Exit Criteria

1. `swift test` green.
2. AI modes produce valid transformed output with Qwen3-8B.
3. LLM failure path is graceful and non-blocking.
4. No Python/runtime-daemon dependency added.

## Deferred (Explicitly Out of Scope)

1. Multi-model runtime routing.
2. Automatic model switching by hardware class.
3. Long-context retrieval pipeline beyond bounded transcript chunking.
