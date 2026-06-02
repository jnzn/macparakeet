# ADR-023: Activity-Based Meeting Auto-Stop

> Status: **ACCEPTED** — Phase 0 (spike) done 2026-06-01; Phase 1 implemented (hard auto-stop, opt-in, default off); Phase 1.5 implemented 2026-06-02: detection is now allowlist-based (`MeetingCallApp`) — only user-configured call apps (pre-seeded: Teams, Zoom, FaceTime, Slack, Safari, Chrome) arm or release the detector. Phase 2 (VAD corroboration / soft-confirm) remains proposed.
> Date: 2026-05-29
> Related: ADR-014 (meeting recording), ADR-015 (concurrent dictation/meeting), ADR-017 (calendar auto-start; auto-stop withdrawn), ADR-019 (crash-resilient recording)

## Context

ADR-017 shipped calendar-driven meeting auto-*start*, then **withdrew** calendar-driven auto-*stop* (2026-05-22). The reasoning still holds: scheduled end times lie — meetings overrun or end early — so a clock-driven stop risks **truncating the recording mid-meeting**, and losing the end of a meeting is far worse than over-recording. Start and stop are asymmetric: starting early is cheap and trimmable; stopping early destroys data.

Today, stopping is manual (one click on the recording pill). The cost: if the user walks away after a call, the recording runs until they remember — trailing dead air (recoverable by trimming, but untidy and wasteful of disk/STT).

The owner's real meeting lifecycle is **not** calendar-bound: meetings "start when I open the Teams meeting and end when I click *End Call*," across Zoom / Teams / Google Meet, native apps or in-browser, often running longer or shorter than scheduled. The reliable signal is therefore not the clock but **call activity** — specifically, the meeting app's (or browser's) use of the microphone.

## Decision

### 1. Detect "in a call" via microphone capture by another process
When you join any call (native or browser), the meeting app/browser **acquires the microphone**; when you End Call, it **releases** it. That acquire/release is the one signal common to every app and browser. macOS Core Audio — which the app already uses for meeting recording via process taps (macOS 14.2+) — exposes the running audio processes and whether each is capturing input (`kAudioHardwarePropertyProcessObjectList` → per-process `kAudioProcessPropertyIsRunningInput` + `…BundleID`). The app can enumerate "which non-MacParakeet process is capturing the mic."

### 2. Bind auto-stop to the call being recorded
At meeting-record start, capture **which other process currently holds the mic** (the meeting app / browser tab). Watch *that* process. Auto-stop triggers when **it** releases the mic — not when any random app does. This ties the stop to the specific call and avoids music / voice-memo / other-app false positives.

### 3. Debounce + soft confirm — never truncate
- Require the mic release to persist for a debounce window (proposed **20–30 s**) before acting; brief blips (device switch, mute quirks) must not trigger.
- Per ADR-017's principle (truncation is the cardinal sin), the first implementation is a **soft confirm**, not a hard stop: a quiet *"Looks like your call ended — stop & save?"* prompt with a generous auto-dismiss, rather than instantly ending the recording. A later revision may offer hard auto-stop once proven.
- Corroborating signal: the bundled **Silero VAD** (F22) — sustained absence of speech in mic + system audio strengthens "the call actually ended."

### 4. Settings toggle — opt-in, user-controllable
Expose one toggle in Settings → Meetings: **"Auto-stop recording when the call ends."**
- Default **OFF** (opt-in), consistent with ADR-017's conservative auto-start default (`.off`) and the data-safety stance — nothing changes for existing users until they enable it.
- When OFF, behavior is unchanged (manual stop only).
- Backed by an `AppFeatures`/`UserDefaults` flag so it can ship behind a flag and be flipped without a rebuild.

### 5. Scope boundaries (what this ADR does NOT do)
- **No auto-START.** Calendar auto-start (ADR-017) stays as-is (opt-in, default off). Activity-based auto-start ("offer to record when a call starts") is explicitly **out of scope** — the owner does not want it.
- No new permissions beyond what meeting recording already requires.
- Local-only; no new telemetry beyond optional `meeting_auto_stop_*` counters.

## Open Questions / Risks
- **Mute behavior:** confirm each target app keeps the OS mic "in use" while muted (Teams/Zoom/Meet generally do — mute is app-level). If an app releases on mute, debounce + VAD corroboration covers it.
- **Browser multi-tab mic:** if another tab also holds the mic, the browser won't release until both end. Rare; debounce + VAD corroboration mitigates.
- **Core Audio per-process input API:** verified by the `mic-processes` spike (2026-06-01) — Teams acquire/release clean; `com.apple.avconferenced` holds the mic persistently on some Macs and is excluded. `kAudioProcessPropertyIsRunningInput` reliably reflects per-process input capture on macOS 14.2+.
- **Self-exclusion:** MacParakeet's own capture (`com.macparakeet` prefix) is excluded from detection via `MeetingCallActivity.excludedPrefixes`.

## Phased Rollout (proposed)
1. **Spike** — confirm Core Audio per-process input detection works and the meeting process can be identified at record-start.
2. **Phase 1** — detection + Settings toggle (default off) + soft-confirm prompt on sustained mic release.
3. **Phase 2** — VAD corroboration; optional hard auto-stop once proven reliable.

## Amendment: Phase 1.5 — Call-App Allowlist (2026-06-02)

Phase 1 treated any non-excluded mic-capturing process as "the call", which
meant any app touching the mic could arm auto-stop, and any app holding the
mic could block it forever. Phase 1.5 inverts the model:

- **Allowlist, not denylist.** A call is active iff a capturing process's
  bundle ID starts with a prefix in the user's call-app list
  (`MeetingCallApp`, persisted as JSON in UserDefaults, pre-seeded with
  Teams / Zoom / FaceTime / Slack / Safari / Chrome).
- **Prefix matching** covers browser helper processes (`com.apple.WebKit.*`,
  `com.google.Chrome.helper`).
- **Settings UI** lists the call apps under the auto-stop toggle; new apps are
  added by picking from a live "apps using the mic" view (MicInputProbe).
- **Empty list → auto-stop inert** (detector never arms).
- **Pause fix:** a dropped auto-stop delivery (recording paused) resets the
  detector so it can re-arm, instead of killing auto-stop for the recording.
- Accepted trade-off: with browsers allowlisted, any mic-using tab counts as a
  call. Scoped 2026-06-02: a false trigger requires recording + no real call +
  a tab acquiring then releasing the mic.

See `plans/completed/2026-06-meeting-auto-stop-call-app-allowlist.md` for the
full design.
