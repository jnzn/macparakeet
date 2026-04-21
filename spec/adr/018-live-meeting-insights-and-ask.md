# ADR-018: Live Meeting Insights and Ask Tabs

> Status: PROPOSED
> Date: 2026-04-19
> Related: ADR-011 (LLM providers), ADR-013 (prompt library + multi-summary), ADR-014 (meeting recording), ADR-016 (centralized STT runtime), ADR-017 (calendar auto-start)

## Context

ADR-014 ships live meeting recording with a single-pane panel: a rolling speaker-attributed transcript with Copy/Auto-scroll/Stop in the footer. After the meeting finalizes, the user is routed to `TranscriptResultView`, which already has Transcript / Result / Chat / Speakers tabs (ADR-013).

The user's ask is to bring a subset of that rich experience *into the live panel*, Granola.ai-style: while the meeting is running, the user can switch between watching the live transcript, glancing at an LLM-maintained interim summary / highlights / open questions, and asking "what did I miss?" mid-call. When the meeting ends, these live artifacts carry over to the post-finalize detail view so nothing is thrown away.

The underlying primitives already exist:

- `LLMService.generatePromptResultStream(transcript:systemPrompt:)` — AsyncThrowingStream of tokens against any system prompt
- `LLMService.chatStream(question:transcript:history:)` — same, with history
- `TranscriptChatViewModel` — already accepts a `transcriptText` parameter at configure time; the rolling live transcript can be fed through the same path
- `PromptResultsViewModel` — single-worker queued generation with snapshot persistence
- Live transcript itself is already yielded continuously via `MeetingRecordingService.transcriptUpdates`

What we don't have: a place for any of this in the *live* panel, and a service that periodically runs LLM work against an in-flight transcript with sensible debouncing and cancellation. This ADR fills both gaps.

## Decision

### 1. Three tabs in the live panel: Transcript / Insights / Ask

`MeetingRecordingPanelView` gains a tab bar between the header and the content area:

```
┌─────────────────────────────────────┐
│ Header (status · elapsed · words)   │
├─────────────────────────────────────┤
│ [Transcript] [ Insights ] [  Ask  ] │  ← new
├─────────────────────────────────────┤
│                                     │
│ content for selected tab            │
│                                     │
├─────────────────────────────────────┤
│ Copy · Auto-scroll · ... · Stop     │
└─────────────────────────────────────┘
```

- **Transcript** — unchanged from today; rolling speaker-attributed live transcript
- **Insights** — LLM-generated sections that refresh periodically as the meeting progresses
- **Ask** — chat UI; user asks questions against the live transcript; supports streaming

The tab bar mimics `TranscriptResultView`'s capsule style so the visual transition from live → finalized feels continuous. Default selected tab is `Transcript`.

### 2. Insights has four fixed sections

The Insights pane is **not** a free-form user-configurable prompt surface during the live meeting. It renders a fixed, structured LLM response with four sections:

1. **Interim Summary** — 2–3 sentence synopsis of the meeting so far
2. **Key Highlights** — bulleted important moments or decisions
3. **Open Questions** — questions raised but not yet answered
4. **Points to Clarify** — statements that were ambiguous or may need follow-up

The LLM is asked for all four sections in one structured call. The system prompt instructs the model to return sections in a fixed machine-parseable format (headers + bullets). The parser is defensive — if a section is missing or malformed, that section renders empty; it does not break the others.

**Why fixed?** User-configurable live prompts would be a distraction mid-meeting, mirror confusingly with post-meeting prompts (ADR-013), and explode the surface we have to maintain. The post-meeting Results tab (ADR-013) is where custom prompts live.

### 3. Insights refresh is debounced; one job at a time

A new `MeetingLiveInsightsService` actor runs the insight generation on demand. Its refresh policy:

- **Minimum interval**: do not start a new run less than 25 seconds after the previous run began
- **Delta gate**: do not start a new run unless ≥ 50 new words have been transcribed since the last run
- **First run**: the first run is allowed at 45 seconds of elapsed recording time (too early produces content-free hallucinations on 5 seconds of "Okay. Okay. Alright.")
- **In-flight cancellation**: if a refresh is requested while one is already running, the request is coalesced; we do not queue multiple insights
- **User-initiated refresh**: a "Refresh" button in the Insights pane bypasses the delta gate (but still respects the minimum interval)

When the meeting stops, the service is asked for one final refresh using the full transcript, and the result is persisted as a `PromptResult` with the built-in "Meeting Insights" prompt snapshot.

### 4. Insights are ephemeral during recording; persisted on stop

During the live session, generated insights live in-memory only (on the `MeetingLiveInsightsService` and its view model). We do not write them to disk every 30 seconds.

On stop:
- The final post-finalize run produces the authoritative insights
- That result is saved as one `PromptResult` row linked to the finalized `Transcription` via the existing `PromptResultRepository`
- The prompt snapshot (name = "Meeting Insights", content = the built-in template) makes the result self-contained per ADR-013

**Why not persist intermediate runs?** They'd inflate the `prompt_results` table without user value — nobody wants to browse ten variants of the same insights. Only the final one matters, and we already have the finalization hook to save it.

### 5. Ask reuses TranscriptChatViewModel with rolling transcript

`TranscriptChatViewModel` already takes `transcriptText: String` at `configure(...)` time. For the live Ask tab:

- On panel show: configure the chat VM with the current live transcript text; leave `transcriptionRepo` and `conversationRepo` as `nil` so messages stay in-memory
- On each user send: re-inject the latest rolling transcript (rebuild the VM's internal `transcriptText`) before calling `sendMessage()`
- On meeting stop + finalize: call `configure(...)` again with the finalized transcript + the real `transcriptionId` and `conversationRepo`, then bulk-insert the in-memory messages into the new `ChatConversation`

Design note for implementation: the cleanest path is a new internal helper on `TranscriptChatViewModel` like `bindPersistedConversation(transcriptionId:, transcriptionRepo:, conversationRepo:)` that takes the existing in-memory messages and promotes them to a persisted conversation. This avoids duplicating send/stream logic and keeps the live/finalized boundary a single function call.

### 6. Starter prompt pills for Ask

The live Ask tab shows a horizontal row of four starter prompts when the conversation is empty (or dismissed after the first send):

- "Summarize so far"
- "What did I miss?"
- "What are the action items?"
- "Was anything left unresolved?"

Tapping a pill fills the input and sends. The pill copy is hardcoded in v1 (English-first). Additional languages and user customization are deferred — TranscriptChatViewModel already has a `suggestedPrompts` array that can be broadened later.

### 7. No-LLM-key empty state is non-blocking

If no LLM provider is configured, both Insights and Ask tabs render an empty state:

> *"Insights and Ask need an AI provider. This is optional — recording still works and you can add a provider anytime in Settings → AI Providers."*

With an "Open Settings" button. The recording itself continues uninterrupted; the Transcript tab is unaffected; finalize still works. Users who never configure LLM can use MacParakeet's meeting recording exactly as it works today.

### 8. Live tabs do not compete with STT for the scheduler

The `LLMService` calls run against cloud or local LLM providers over HTTP. They do **not** go through `STTScheduler` (ADR-016). There is no contention with dictation or meeting live-chunk transcription: LLM and STT are separate compute paths (LLM = network or local Ollama process; STT = ANE/CoreML).

That said: local LLM (Ollama / LM Studio) on the same machine is CPU/GPU-bound. The debouncing in §3 and the single-worker queue are what keep local-LLM insight runs from slowing down the machine mid-meeting. The existing `LLMService` context budget (24k chars for local, 100k for cloud) already handles long meetings via middle-truncation.

### 9. Post-finalize view still owns the rich experience

The post-finalize `TranscriptResultView` (ADR-013) is unchanged. What's new:

- The final insights run is already saved as a `PromptResult` and appears as a tab automatically
- The live Ask conversation is already persisted as a `ChatConversation` on the finalized transcription; the Chat tab shows those messages continuously

The user experience across the transition should feel like "the panel grew into a window." No data is lost, no duplication, no re-asking.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                   MeetingRecordingPanelView                      │
│   ┌────────────┐ ┌──────────┐ ┌─────────┐                       │
│   │ Transcript │ │ Insights │ │   Ask   │   ← tab bar            │
│   └────────────┘ └──────────┘ └─────────┘                       │
│                                                                  │
│   ┌──────────────────────────────────────────────────────────┐  │
│   │ MeetingRecordingPanelViewModel                           │  │
│   │   ├── previewLines (existing)                            │  │
│   │   ├── insightsViewModel : MeetingInsightsViewModel (new) │  │
│   │   └── chatViewModel    : TranscriptChatViewModel (exists)│  │
│   └──────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                               │
                 ┌─────────────┴──────────────┐
                 ▼                            ▼
┌─────────────────────────────┐    ┌──────────────────────────┐
│ MeetingLiveInsightsService  │    │ TranscriptChatViewModel  │
│   ├── actor                 │    │   (existing)             │
│   ├── debounce policy       │    │                          │
│   ├── cancellation          │    │                          │
│   └── uses LLMService       │    │                          │
│        .generatePromptResult│    │   uses LLMService        │
│        Stream(systemPrompt:)│    │        .chatStream       │
└─────────────────────────────┘    └──────────────────────────┘
                 │                            │
                 └─────────────┬──────────────┘
                               ▼
                      ┌──────────────────┐
                      │   LLMService     │
                      │   (existing)     │
                      └──────────────────┘
```

## Rationale

### Why four fixed sections instead of a chat-only live experience?

Granola's single biggest differentiator is that you can *glance* at an LLM-maintained view of the meeting without asking anything. Requiring a chat question means the user has to type during a call. Fixed sections that refresh in the background are the point.

### Why not stream the insights live (token-by-token) on the Insights tab?

We considered it. The problem: insights refresh every ~30 seconds, and each run takes 5–10 seconds to stream. If the user is watching the Insights tab, they'd see shimmering text constantly. We decided on a cleaner UX: show the previous run steady on screen; when the new run completes, swap with a brief crossfade. Streaming happens under the hood for cancellation/backpressure reasons, not for UI animation.

### Why reuse `TranscriptChatViewModel` instead of writing a live-specific chat VM?

The chat VM is already built for streaming messages against a transcript with history. The only thing it doesn't know is that the transcript is growing. That's a one-line update — re-setting `transcriptText` before each send. Writing a parallel `LiveChatViewModel` is duplication.

### Why save final insights but not live chat messages as a separate artifact?

Live chat messages are already a first-class artifact (`ChatConversation`). Live insights aren't — they'd have to be modeled as a special kind of prompt result. We picked the simpler mapping: treat final insights as a `PromptResult` with the built-in "Meeting Insights" prompt, save the live chat as a normal `ChatConversation`. Both drop into their respective tabs on the finalized view.

### Why 25-second minimum interval and 50-word delta?

Heuristics, tuned for a voice call pace of ~150 wpm (average English conversation). 50 words is ~20 seconds of talk; adding the 25-second minimum gives a natural one-run-per-half-minute cadence under active speech and drops to "no refresh" during long silences. Both numbers are constants in v1; make them settings only if telemetry shows users want control.

### Why not auto-expand meeting panel on auto-start (ADR-017) so Insights/Ask are visible?

The panel's default collapse behavior is a separate UX question. v1 keeps it as-is: pill on, panel opens when the user clicks. If the user never opens the panel, insights and chat still run invisibly — but cheaply, because an unopened panel means no UI work is happening. The only overhead is the LLM calls themselves, governed by §3.

## Consequences

### Positive

- Meeting recording reaches feature parity with the "observable AI view of your meeting" use case that Granola-class tools provide
- No new data model on top of existing `PromptResult` + `ChatConversation`
- Live and finalized experiences share state — no data loss on the transition
- No-LLM-key users get the same recording they have today; feature is pure addition
- Post-finalize `TranscriptResultView` gets richer with zero view-layer changes
- `LLMService` and `TranscriptChatViewModel` are both reused, not cloned

### Negative

- **LLM cost**: every active meeting makes periodic LLM calls. For cloud providers this costs real money per minute of meeting. Mitigate: the default `llm` setup after onboarding is still unset (nothing fires until the user configures a provider). Surface meeting-level cost estimates in settings later if this becomes an issue.
- **Privacy shift**: LLM features are local-first by default (ADR-002 amendment), but cloud LLM users are now streaming meeting content to a third party every 30 seconds — a more aggressive privacy posture than single post-meeting summaries. Mitigate: clearly documented; remains opt-in at the provider layer.
- **UI complexity in the panel**: the panel was a single pane; it's now three panes plus a tab bar. More layout surface, more places for regressions.
- **Delta-gate heuristic is not language-aware**: 50 words in English ≠ 50 words in Korean for the same duration. Acceptable for v1; re-tune if multilingual use cases surface.
- **Live insights can be wrong**: the LLM may hallucinate on thin context or disagree with itself across runs. Prompt engineering and the "Points to Clarify" section are deliberate framings to keep the model humble, but we must set user expectations that live insights are directional.

## Implementation Direction

### Core (MacParakeetCore)

- `MeetingLiveInsightsService` (actor) — exposes:
  - `start()` / `stop()`
  - `update(transcript: String, wordCount: Int, elapsedSeconds: Int)` — called from `MeetingRecordingFlowCoordinator` on every `transcriptUpdates` tick; internal debounce logic
  - `refreshNow()` — user-initiated, honors minimum interval
  - `insights: AsyncStream<MeetingInsightsSnapshot>` — emits `(sections, generatedAt, isStale)` snapshots
  - `finalize() async -> MeetingInsights` — one synchronous run on the full transcript post-stop
- `MeetingInsights` value type with four optional `Section` fields
- `MeetingInsightsPrompt` — static system-prompt template (built-in)

### ViewModels (MacParakeetViewModels)

- `MeetingInsightsViewModel` (@MainActor @Observable) — subscribes to `MeetingLiveInsightsService.insights`; exposes current snapshot + `isRefreshing` + `hasLLM` + `refresh()` action
- Extend `MeetingRecordingPanelViewModel` with:
  - `selectedTab: LivePanelTab`
  - `insightsViewModel: MeetingInsightsViewModel`
  - `chatViewModel: TranscriptChatViewModel`
  - `rollingTranscript: String` computed from `previewLines`
- Extend `TranscriptChatViewModel` with `bindPersistedConversation(transcriptionId:, transcriptionRepo:, conversationRepo:)` for the live→persisted promotion

### View layer (MacParakeet)

- Update `MeetingRecordingPanelView` with the tab bar; introduce three pane views:
  - `LiveTranscriptPaneView` — the existing content, extracted
  - `LiveInsightsPaneView` — renders four sections with staleness indicator + Refresh button
  - `LiveAskPaneView` — chat UI + starter pill row, input at bottom
- Keep the footer (Copy/Auto-scroll/Stop) context-aware per tab (Copy copies the visible pane's content)

### Wiring (MacParakeet App)

- `MeetingRecordingFlowCoordinator` instantiates `MeetingLiveInsightsService` on recording start, feeds it transcript updates, calls `finalize()` on stop
- The finalized `PromptResult` is persisted right before `onTranscriptionReady` fires
- The in-memory live chat conversation is promoted via the new `bindPersistedConversation` helper at the same point

### Telemetry (new cases, must mirror to website allowlist)

- `.meetingLiveInsightsRun(provider: String, durationSeconds: Double, transcriptChars: Int, sections: Int)`
- `.meetingLiveInsightsFailed(provider: String, errorType: String)`
- `.meetingLiveAskUsed(provider: String, messageCount: Int)`

## Phased Rollout

1. **Phase 1 — Tab shell + Transcript extraction:** Panel grows tabs, Transcript pane is the old content moved wholesale. No new services. Ship as a visual-only change.
2. **Phase 2 — Insights service + pane:** Implement `MeetingLiveInsightsService`, wire up the Insights pane. Ship behind its own telemetry; default empty state when no LLM.
3. **Phase 3 — Live Ask:** Wire `TranscriptChatViewModel` into the panel, starter pills, live→persisted promotion. Ship.
4. **Phase 4 — Copy polish:** Per-tab Copy, per-tab Share, consistency with `TranscriptResultView` affordances.

## Open Questions

- **Panel size**: current `idealWidth: 420, idealHeight: 460` is sized for a single transcript pane. Insights with four sections and Ask with chat bubbles both want more vertical space. Either raise defaults or ensure each pane handles the current size gracefully.
- **Voice of the built-in insights prompt**: tone (terse vs friendly), format (plain markdown vs a fixed schema), and instruction strength all affect quality. This is prompt engineering, not architecture — owned by whoever implements Phase 2.
- **Handling speaker labels in the LLM prompt**: the live transcript already carries `Me` / `Others` labels. Including them in the prompt helps the LLM produce attributed highlights ("Alice asked about X"), but the labels are generic — worth testing if it helps or confuses the model.
- **Should the Insights pane expose which LLM produced the current snapshot?** Probably yes — one small text line at the bottom. Cheap to implement, useful for debugging and user trust.
