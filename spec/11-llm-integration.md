# 11 - LLM Integration

> Status: **ACTIVE** - Authoritative, current
> Baseline: Qwen3-8B 4-bit via MLX-Swift-LM (ADR-008)

This spec defines how MacParakeet integrates local LLM features with clean architecture, deterministic fallback behavior, and testable seams.

---

## Goals

1. Deliver AI text refinement modes (Formal, Email, Code) on top of deterministic cleanup.
2. Reuse one LLM integration path for command mode and future transcript chat.
3. Keep local-only guarantees and avoid Python/daemon dependencies.
4. Fail gracefully without breaking dictation/transcription flows.

## Non-Goals (This Phase)

1. Multi-model routing.
2. Agent/tool use orchestration.
3. Hard latency release gates.

---

## Architecture

```
Dictation/Command/Chat Call Site
    -> PromptBuilder
    -> LLMServiceProtocol
       -> MLXQwenService (Qwen3-8B)
    -> LLMResultAdapter
    -> FallbackPolicy (deterministic output on failure)
```

### Core Protocol

```swift
public protocol LLMServiceProtocol: Sendable {
    func generate(_ request: LLMRequest) async throws -> LLMResponse
}
```

### Request / Response Contract

```swift
public struct LLMRequest: Sendable {
    public let task: LLMTask
    public let input: String
    public let context: LLMContext
}

public enum LLMTask: Sendable {
    case refine(mode: RefinementMode)      // formal/email/code
    case commandTransform(command: String) // "translate to spanish", etc.
    case transcriptChat(query: String)     // future
}

public struct LLMResponse: Sendable {
    public let output: String
    public let meta: LLMResponseMeta
}
```

### Fallback Policy (Required)

If LLM invocation fails, times out, or yields empty output:

1. Return deterministic-clean text where applicable.
2. Keep UX non-blocking (small info/error surface, no hard stop).
3. Emit structured log/telemetry event for diagnosis.

No data loss and no silent crash paths are allowed.

---

## Feature Wiring

1. **Dictation modes**
- `raw`: no transform
- `clean`: deterministic pipeline only
- `formal/email/code`: deterministic pipeline -> LLM request -> fallback if needed

2. **Command mode**
- selected text + spoken command -> LLM request (`commandTransform`) -> replace selection

3. **Transcript chat (future)**
- query + transcript context chunking -> LLM request (`transcriptChat`)

---

## Model and Runtime Baseline

| Property | Value |
|----------|-------|
| Runtime | `mlx-swift-lm` |
| Model | `mlx-community/Qwen3-8B-4bit` |
| Loading | lazy-load on first use |
| Unload | idle timeout (default 5 min) |
| Context strategy | bounded prompt assembly with truncation/chunking |

---

## Error Categories

1. `modelUnavailable` - model missing or load failure
2. `generationFailed` - runtime/generation error
3. `timeout` - call exceeded configured budget
4. `invalidOutput` - empty/unsafe output

All categories must map to user-safe fallback behavior.

---

## Testing Requirements

### Unit

1. `PromptBuilder` per task and mode.
2. `FallbackPolicy` for all error categories.
3. `LLMServiceProtocol` mock-driven tests in dictation/command flows.

### Integration

1. First-load path (cold start).
2. Warm invocation path.
3. Idle unload + reload behavior.

### Regression

1. Deterministic mode behavior unchanged.
2. LLM failure cannot block transcription completion.

---

## Acceptance Criteria

1. AI modes produce transformed output with Qwen3-8B.
2. Failure path returns deterministic-safe output and surfaces recoverable UI notice.
3. No Python runtime or daemon dependency introduced.
4. `swift test` remains green with new LLM seam tests.

Latency metrics are tracked and monitored, but not used as hard release gates in this phase.
