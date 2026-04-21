# Granola-style Meeting Recording Completion

**Status:** Active
**Date:** 2026-04-19
**ADRs:** ADR-017 (calendar auto-start), ADR-018 (live insights + ask)
**Blocks:** GitHub #57 "meeting recording v0.6" final closeout

## What this plan closes out

ADR-014 shipped the bones of meeting recording. ADR-015 let it run alongside dictation. ADR-016 centralized STT ownership. What's left before we call this feature *done*:

1. **Calendar-driven auto-start** (ADR-017) — users forget to press record; the calendar already knows their meetings
2. **Live Insights tab** (ADR-018) — Granola's "glance view" of a meeting in progress
3. **Live Ask tab** (ADR-018) — mid-meeting "what did I miss?" without typing the transcript into a chatbot later
4. **Onboarding + settings surface** for all of the above

This plan is the file-by-file breakdown. It is sequenced in phases so each phase is an independently shippable slice; nothing is a big-bang.

## Scope boundaries

### In scope
- Calendar EventKit integration, polling coordinator, reminder + auto-start + auto-stop
- Port `CalendarService` / `MeetingMonitor` / `MeetingLinkParser` from `oatmeal` repo
- Add tabs to `MeetingRecordingPanelView`: Transcript / Insights / Ask
- New `MeetingLiveInsightsService` actor + viewmodel + pane
- Reuse `TranscriptChatViewModel` in the panel; add live-→-persisted promotion helper
- Settings UI (Calendar section) + onboarding step
- Telemetry cases + website allowlist mirror

### Out of scope
- Cross-meeting RAG, entity extraction, person graph (Oatmeal territory)
- Custom live prompts (lives on the post-meeting Results tab via ADR-013)
- ScreenCaptureKit / per-app audio isolation (ADR-014 locked Core Audio Taps)
- Late-join UI for meetings already in progress (enum case exists, UI deferred)
- Non-English starter pills and prompt copy

### Invariants
- Dictation continues to work unchanged, concurrently (ADR-015)
- Users without an LLM provider see no regression — recording still works end-to-end
- No new SQLite tables; reuse `prompt_results` and `chat_conversations`
- Local-first posture preserved — EventKit reads are on-device only
- STT scheduler (ADR-016) is untouched; LLM calls do not go through it

## Phased rollout

### Phase A — Tab shell in the live panel (visual-only, no new services)

Pure refactor. The existing single-pane panel becomes a three-tab panel where only Transcript has content; Insights and Ask show disabled empty states.

| File | Change |
|------|--------|
| `Sources/MacParakeetViewModels/MeetingRecordingPanelViewModel.swift` | Add `selectedTab: LivePanelTab` enum property (`.transcript` default, `.insights`, `.ask`). |
| `Sources/MacParakeet/Views/MeetingRecording/MeetingRecordingPanelView.swift` | Between `header` and `transcriptContent`, insert `tabBar`. Wrap existing transcript body as `LiveTranscriptPaneView`. Switch on `selectedTab` to render pane; Insights/Ask render a "Coming soon" stub. |
| `Sources/MacParakeet/Views/MeetingRecording/LiveTranscriptPaneView.swift` *(new)* | Extract the existing `transcriptContent` view body verbatim. No behavior change. |
| `Sources/MacParakeet/Views/MeetingRecording/LivePanelTabBar.swift` *(new)* | Capsule-style tab row matching `TranscriptResultView`'s pattern. |
| `Tests/MacParakeetTests/ViewModels/MeetingRecordingPanelViewModelTests.swift` | Default tab is `.transcript`; tab selection persists across `updatePreview` calls. |

**Ship criteria:** panel looks like today when on Transcript tab. Clicking Insights or Ask shows a styled stub. `swift test` green.

### Phase B — Live Insights service + pane

Introduces the `MeetingLiveInsightsService` actor, the viewmodel, and the rendered pane. Finalization wiring included.

| File | Change |
|------|--------|
| `Sources/MacParakeetCore/MeetingRecording/MeetingLiveInsightsService.swift` *(new)* | Actor. Debounce (25s minimum interval, 50-word delta, 45s first-run floor). Uses `LLMService.generatePromptResultStream(transcript:systemPrompt:)`. Emits `AsyncStream<MeetingInsightsSnapshot>`. Exposes `update(...)`, `refreshNow()`, `finalize() async -> MeetingInsights`. |
| `Sources/MacParakeetCore/MeetingRecording/MeetingInsights.swift` *(new)* | `MeetingInsights` (four optional section strings), `MeetingInsightsSnapshot`, parsing from the LLM response. |
| `Sources/MacParakeetCore/MeetingRecording/MeetingInsightsPrompt.swift` *(new)* | Static built-in system prompt (returns fixed markdown sections). |
| `Sources/MacParakeetViewModels/MeetingInsightsViewModel.swift` *(new)* | `@MainActor @Observable`. Subscribes to service. Exposes `snapshot`, `isRefreshing`, `hasLLM`, `providerDisplayName`, `refresh()`. |
| `Sources/MacParakeetViewModels/MeetingRecordingPanelViewModel.swift` | Compose `insightsViewModel`. Expose to panel view. |
| `Sources/MacParakeet/Views/MeetingRecording/LiveInsightsPaneView.swift` *(new)* | Renders four sections with staleness dot + Refresh button + provider footer. Empty state routes to Settings → AI Providers. |
| `Sources/MacParakeet/App/MeetingRecordingFlowCoordinator.swift` | Instantiate `MeetingLiveInsightsService` on start. Feed `transcriptUpdates` into `service.update(...)`. On stop, call `service.finalize()`, persist as `PromptResult` via `PromptResultRepository` using the built-in "Meeting Insights" prompt snapshot, *then* fire `onTranscriptionReady`. |
| `Sources/MacParakeetCore/Services/TelemetryEvent.swift` | Add `.meetingLiveInsightsRun(...)`, `.meetingLiveInsightsFailed(...)`. |
| `../macparakeet-website/functions/api/telemetry.ts` | Add both new event names to `ALLOWED_EVENTS`. **Two-repo change — see `MEMORY.md`.** |
| `Tests/MacParakeetTests/MeetingRecording/MeetingLiveInsightsServiceTests.swift` *(new)* | Debounce under delta gate. Cancellation on new update. First-run floor. Finalize uses full transcript. Parser handles missing sections. |

**Ship criteria:** Insights pane renders with a provider configured. Four sections appear after ≥45s of content. Refresh respects 25s floor. Stopping the meeting persists one `PromptResult` row bound to the finalized transcription; it appears on `TranscriptResultView`'s tabs automatically. No-LLM state shows empty-state CTA; recording still works.

### Phase C — Live Ask

Reuses `TranscriptChatViewModel`. The work is (1) wire it into the panel, (2) implement the in-memory → persisted handoff, (3) build the starter pill row.

| File | Change |
|------|--------|
| `Sources/MacParakeetViewModels/TranscriptChatViewModel.swift` | Add `public func bindPersistedConversation(transcriptionId: UUID, transcriptionRepo: TranscriptionRepositoryProtocol, conversationRepo: ChatConversationRepositoryProtocol) async`. Promotes existing in-memory `messages` to a newly saved `ChatConversation`. Also: add `public func updateTranscriptText(_ newValue: String)` so the VM can be fed the rolling live transcript on each send. |
| `Sources/MacParakeetViewModels/MeetingRecordingPanelViewModel.swift` | Compose `chatViewModel: TranscriptChatViewModel`. On each preview update, call `chatViewModel.updateTranscriptText(rollingTranscript)`. |
| `Sources/MacParakeet/Views/MeetingRecording/LiveAskPaneView.swift` *(new)* | Chat UI with starter pills ("Summarize so far", "What did I miss?", "What are the action items?", "Was anything left unresolved?"), message list, input bar. No reuse of `TranscriptResultView`'s chat view body — the layout constraints differ — but visually consistent. |
| `Sources/MacParakeet/Views/MeetingRecording/StarterPromptPillRow.swift` *(new)* | Horizontal row of pills; tapping fills input + sends. Hidden after first user message. |
| `Sources/MacParakeet/App/MeetingRecordingFlowCoordinator.swift` | After Phase B's `onTranscriptionReady`: call `chatViewModel.bindPersistedConversation(...)` with the new transcription id so live messages are preserved on the finalized detail view. |
| `Sources/MacParakeetCore/Services/TelemetryEvent.swift` | Add `.meetingLiveAskUsed(provider:messageCount:)`. |
| `../macparakeet-website/functions/api/telemetry.ts` | Mirror the new event name. |
| `Tests/MacParakeetTests/ViewModels/TranscriptChatViewModelLivePersistenceTests.swift` *(new)* | `bindPersistedConversation` creates one conversation, inserts N existing messages in order, sets `transcriptionId`, does not double-write. `updateTranscriptText` is picked up on next send. |

**Ship criteria:** Meeting panel's Ask tab accepts messages and streams responses mid-recording. After Stop, the conversation appears on the finalized transcription's Chat tab with the full history intact. Starter pills fire the right prompts. No-LLM empty state mirrors Insights.

### Phase D — Calendar auto-start: notify-only (ADR-017 phase 1)

Port the three core files from Oatmeal, add settings + onboarding, wire a coordinator that only does `.notify` (no auto-start yet). Safe to ship without Phase E.

| File | Change |
|------|--------|
| `Sources/MacParakeetCore/Calendar/CalendarService.swift` *(new, ported)* | EventKit wrapper. Permission check + request, `fetchUpcomingEvents(withinDays:)`, `availableCalendars()`. Strip Oatmeal's telemetry category prefixes. |
| `Sources/MacParakeetCore/Calendar/CalendarEvent.swift` *(new, ported)* | `CalendarEvent`, `EventParticipant`, `CalendarInfo` — plain `Sendable` structs, no GRDB. |
| `Sources/MacParakeetCore/Calendar/MeetingLinkParser.swift` *(new, ported verbatim)* | Zoom/Meet/Teams/Webex/Around regex extractor. |
| `Sources/MacParakeetCore/Calendar/MeetingMonitor.swift` *(new, ported verbatim)* | Pure state machine: `evaluate(events, now, config, activeRecording, dismissedIds, remindedIds, countdownShownIds) -> [MonitorEvent]`. |
| `Sources/MacParakeetCore/Calendar/CalendarAutoStartMode.swift` *(new)* | `.off` / `.notify` / `.autoStart`. |
| `Sources/MacParakeetCore/Calendar/MeetingTriggerFilter.swift` *(new)* | `.withLink` / `.withParticipants` / `.allEvents`. |
| `Sources/MacParakeetViewModels/SettingsViewModel.swift` | New properties: `calendarAutoStartMode`, `calendarReminderMinutes`, `meetingTriggerFilter`, `calendarAutoStopEnabled`, `calendarIncludedIdentifiers: Set<String>`. Persist via `UserDefaults` under a `CalendarAutoStart.*` namespace. `didSet` posts a new notification. |
| `Sources/MacParakeetCore/AppNotifications.swift` | Add `macParakeetCalendarSettingsDidChange`. |
| `Sources/MacParakeet/App/MeetingAutoStartCoordinator.swift` *(new)* | `@MainActor` class. 60s poll (5s near events). Subscribes to `.EKEventStoreChanged`. Calls `MeetingMonitor.evaluate`, fires `UNUserNotificationCenter` notifications for `.reminderDue`. Does **not** start recordings in this phase. Owned by `AppDelegate`, configured in `AppEnvironmentConfigurer`, observed via `AppSettingsObserverCoordinator`. |
| `Sources/MacParakeet/Views/Settings/CalendarSettingsView.swift` *(new)* | Mode picker + reminder lead time picker + trigger filter picker + per-calendar checkboxes + permission CTA. |
| `Sources/MacParakeet/Views/Settings/SettingsView.swift` | Mount `CalendarSettingsView` as a new section. |
| `Sources/MacParakeet/Views/Onboarding/OnboardingCalendarView.swift` *(new)* | Explainer + "Grant Calendar access" button + "Skip" button. Sets `calendarAutoStartMode = .off` on skip. |
| `Sources/MacParakeet/Views/Onboarding/OnboardingFlowView.swift` | Slot the new step after permissions, before model download. |
| `Sources/MacParakeetCore/Services/TelemetryEvent.swift` | Add `.calendarPermissionGranted`, `.calendarPermissionDenied`, `.settingChanged(.calendarAutoStartMode)` etc. |
| `../macparakeet-website/functions/api/telemetry.ts` | Mirror all new event names. |
| `Tests/MacParakeetTests/Calendar/MeetingMonitorTests.swift` *(new)* | Ported from Oatmeal if available; otherwise write: reminder fires exactly once per event, auto-start window is T±30s, dismissed ids suppress further events, trigger filter correctness. |
| `Tests/MacParakeetTests/Calendar/MeetingLinkParserTests.swift` *(new)* | Zoom/Meet/Teams URL extraction from location/notes/url fields. |

**Ship criteria:** User grants Calendar permission through onboarding or Settings. At T-5min of a calendar event with a video link, a macOS notification appears. `.autoStart` mode is exposed in the UI but is a no-op (shows a "Coming soon" hint if selected, or clamp the picker to not expose it yet — plan says clamp).

### Phase E — Calendar auto-start: countdown + auto-stop (ADR-017 phase 2)

Add the countdown toast and the actual recording triggers.

| File | Change |
|------|--------|
| `Sources/MacParakeet/Views/MeetingRecording/MeetingCountdownToastController.swift` *(new)* | `NSPanel` subclass via `KeylessPanel`. 5-second countdown with cancel button. Public `show(title:subtitle:onConfirm:onCancel:)`. |
| `Sources/MacParakeet/Views/MeetingRecording/MeetingCountdownToastView.swift` *(new)* | SwiftUI view for the toast body. Fills a progress bar over 5s. |
| `Sources/MacParakeet/App/MeetingAutoStartCoordinator.swift` | Handle `.autoStartDue` → show countdown toast → on confirm, call `MeetingRecordingFlowCoordinator.startRecording(triggeredBy: .calendar(event))`. Handle `.autoStopDue` → show "meeting ending" toast → on confirm, call `stopRecording()`. Respect `activeRecording` — do not fire a second start if manual start already took. |
| `Sources/MacParakeet/App/MeetingRecordingFlowCoordinator.swift` | Accept an optional `triggeredBy: MeetingRecordingTrigger` parameter (`.manual` / `.hotkey` / `.calendar(CalendarEvent)`). Stash it on the session so title defaults use the calendar event title. |
| `Sources/MacParakeet/Views/Settings/CalendarSettingsView.swift` | Unclamp `.autoStart` option and expose the auto-stop toggle. |
| `Sources/MacParakeetCore/Services/TelemetryEvent.swift` | Add `.calendarAutoStartTriggered(mode:)`, `.calendarAutoStartCancelled(reason:)`, `.meetingRecordingStarted(trigger:)` (if not already present). |
| `../macparakeet-website/functions/api/telemetry.ts` | Mirror. |
| `Tests/MacParakeetTests/App/MeetingAutoStartCoordinatorTests.swift` *(new)* | Countdown countdown-cancel does not start recording. Active recording suppresses subsequent `.autoStartDue` for the same event. Auto-stop confirmation stops an active recording. |

**Ship criteria:** End-to-end: calendar event at T-5min fires notification; at T-0 shows a 5s cancellable toast; on confirm (or timeout) starts meeting recording; at event-end shows auto-stop toast; on confirm stops recording and runs the normal finalize pipeline.

### Phase F — Copy polish, naming unification, changelog

Low-value-per-unit cleanup that's better done in one pass.

| File | Change |
|------|--------|
| All calendar-related copy | Unify on "Auto-record" (not "Auto-start") or vice versa — pick and grep. |
| `README.md`, `CLAUDE.md`, `spec/02-features.md`, `spec/README.md` | Update test counts, mark meeting recording as shipped, add calendar section to feature list. |
| `docs/commit-guidelines.md` | No change. |
| `CHANGELOG` (website release notes) | v0.6.x bullet points for each phase that shipped. |

## Testing matrix

- `swift test` baseline before each phase; all green after.
- Manual smoke per phase in the ship criteria above.
- Long-meeting smoke (60-minute test recording) for Phase B to confirm debounce and memory behavior.
- Calendar smoke requires a test calendar with a Zoom-link event 5 minutes out; confirm notification, then confirm auto-start with countdown.
- No-LLM-key smoke: verify Insights and Ask tabs show empty state and recording still works.

## Risk register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| LLM cost spikes mid-meeting | Medium (for cloud users) | Medium | Debounce per ADR-018; surface per-meeting cost in a follow-up if telemetry justifies |
| Insights hallucinate on thin context | Medium | Low | 45s first-run floor; "Points to Clarify" section framed to invite skepticism |
| Calendar poll fires during sleep | Low | Low | EventKit reads on wake are cheap; `.EKEventStoreChanged` catches missed changes |
| Oatmeal ports drift | Low | Low | No shared packaging; local copies can evolve |
| User denies Calendar permission mid-onboarding then can't find it | Low | Medium | Permission CTA in `CalendarSettingsView` handles denied state with deep-link to System Settings |
| Auto-start fires for a declined event | Medium | Low | Trigger filter defaults to `.withLink`; countdown toast is a 5-second safety valve |
| Live Ask chat VM persistence handoff loses messages | Low | High | Phase C test `TranscriptChatViewModelLivePersistenceTests` covers exactly this; promotion is atomic |

## Timeline estimate (optimistic, uninterrupted)

- Phase A: 0.5 day (pure refactor)
- Phase B: 2 days (service + parsing + wiring + finalize)
- Phase C: 1.5 days (VM helper + live pane + handoff test)
- Phase D: 2 days (ports + settings + onboarding + notifications)
- Phase E: 1 day (countdown toast + flow wiring)
- Phase F: 0.5 day

Total: ~7.5 engineering days. Shippable per phase; nothing requires all six to land before releasing v0.6.x.

## Changelog line (when all phases land)

> **Meeting Recording (completed):** Meetings now open with live Transcript, Insights, and Ask tabs so you can glance at a rolling AI summary or ask "what did I miss?" without leaving the panel. Calendar-driven auto-start can remind you before a meeting begins and (optionally) start recording for you. Works with Zoom, Google Meet, Microsoft Teams, and Webex links on your macOS calendar.
