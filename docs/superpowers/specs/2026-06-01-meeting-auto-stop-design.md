# Activity-based meeting auto-stop — design

> Status: **APPROVED** (brainstorm 2026-06-01). Implements ADR-023 Phase 1
> (activity-based meeting auto-stop). Phase 0 spike is done — see "Spike result".

## Overview

When a recorded call ends, auto-stop the meeting recording. Detect "call ended"
by watching the meeting app release the microphone (Core Audio per-process input),
wait a configurable grace period (default 5s), then hard-stop via the normal
stop/handoff path. Opt-in via a Settings toggle (default OFF).

## Spike result (Phase 0, validated 2026-06-01)

The `mic-processes` CLI probe (commit `fd8ea3d4`) confirmed on the user's Mac:
- **Microsoft Teams** acquired the mic on join (`bundle=com.microsoft.teams2`) and
  released it on End Call — a clean, detectable acquire/release signal.
- **`com.apple.avconferenced`** held the mic for the *entire* session (a persistent
  macOS AV-conference daemon), before, during, and after the call. A naive "any
  non-MacParakeet process is capturing → in a call" detector would never fire.

**Conclusion:** the signal is sound, but detection must exclude MacParakeet's own
capture **and** system audio daemons (starting with `com.apple.avconferenced`).

## Detection — `MeetingCallActivityMonitor` (MacParakeetCore, macOS 14.2+)

A small service that, while running, polls every ~1.5s:
- Enumerate `kAudioHardwarePropertyProcessObjectList`; for each, read
  `kAudioProcessPropertyIsRunningInput` + `kAudioProcessPropertyBundleID`.
- **Excluded** bundle IDs: MacParakeet (`com.macparakeet.*`) and a daemon denylist
  `["com.apple.avconferenced"]` (extensible; the `mic-processes` probe stays as the
  diagnostic for adding more).
- **`isCallActive`** = ≥1 *non-excluded* process is capturing input.

The Core Audio enumeration is a thin adapter (`MicInputProbe`-style, promoted from
the CLI spike into Core). It exposes one pure function:
`callActiveBundleIDs() -> Set<String>` (non-excluded bundle IDs currently capturing
input). The monitor is the only consumer.

## Auto-stop logic (arm-then-fire state machine)

A pure state machine (`MeetingAutoStopDetector`), fed `isCallActive` samples +
timestamps, so it's unit-testable with no audio HW:

- **Disarmed** initially. When a sample reports `isCallActive == true`, transition to
  **Armed** (a call has been seen during this recording).
- While **Armed**, if `isCallActive == false` continuously for `delaySeconds`
  (default 5), emit **`.autoStop`** once, then go **Fired** (no repeat).
- Any `isCallActive == true` while waiting resets the "released since" timer.
- A recording that never sees a call (in-person) stays **Disarmed** → never fires.

The coordinator calls the detector on each poll; on `.autoStop`, it triggers the
**same stop path as the menu/hotkey** (`sendEvent(.stopRequested)` →
`.stopRecordingAndHandOff`), so finalize/handoff/background-transcription are
identical to a manual stop. Telemetry: a `meeting_auto_stopped` event.

## Settings — toggle + editable delay (Settings → Meetings)

Mirror the existing **"Auto-stop after silence"** dictation control (toggle + delay
field). Add a row:
- **Toggle:** "Auto-stop recording when the call ends." Default **OFF**.
- **Delay field** *next to the toggle*: editable seconds, default **5**, sensible
  bounds (e.g. 2–120s). Disabled/greyed when the toggle is off.

`UserDefaults` keys (in `AppRuntimePreferences`):
- `meetingAutoStopEnabled` (Bool, default `false`).
- `meetingAutoStopDelaySeconds` (Int, default `5`).
Surfaced through `AppRuntimePreferencesProtocol` + `SettingsViewModel`/`SettingsView`,
matching the silence-auto-stop wiring.

## Lifecycle / wiring

- The monitor runs **only** while a meeting recording is active **and**
  `meetingAutoStopEnabled` is on. `MeetingRecordingFlowCoordinator` starts it when
  it enters `.recording` (mirroring `startPillPolling`) and stops it on flow
  teardown (`stopPillPolling`/`.hidePill`). Reads the delay from preferences at start.
- Voice memos: out of scope for v1 (they're short, mic-only; auto-stop keys off a
  *call app* which a voice memo has none of). The monitor simply never arms for them.
- Concurrency: the monitor is `@MainActor` (it drives a flow action); Core Audio
  reads are quick and synchronous.

## Scope / known limits (deliberate)
- In-person meetings (no call app) → never auto-stop. Manual stop, as today.
- FaceTime → not auto-stopped (its audio surfaces as `com.apple.avconferenced`,
  which is excluded). The user records Teams/Zoom/Meet.
- Browser calls (Meet) may be less precise if the browser keeps the mic for other
  tabs; the 5s grace mitigates, and the denylist/delay are tunable.
- Hard stop carries a small truncation risk if a call app briefly drops the mic
  mid-call; the configurable delay + opt-in default mitigate (ADR-023 §3 / ADR-017).

## Components (isolation)

| Unit | Responsibility | Depends on |
|------|----------------|-----------|
| `MicInputProbe` (Core) | Core Audio: bundle IDs currently capturing input | CoreAudio |
| `MeetingCallActivityMonitor` (Core/app) | poll on a timer → `isCallActive` (excl. MacParakeet + daemons) → feed detector | `MicInputProbe`, prefs |
| `MeetingAutoStopDetector` (Core) | pure arm/fire state machine (samples → `.autoStop`) | — |
| `AppRuntimePreferences` | `meetingAutoStopEnabled` + `meetingAutoStopDelaySeconds` | UserDefaults |
| `MeetingRecordingFlowCoordinator` | start/stop the monitor with the recording; on `.autoStop` → `.stopRequested` | monitor, prefs |
| `SettingsViewModel`/`SettingsView` | toggle + delay field (Meetings card) | prefs |

## Testing
- `MeetingAutoStopDetector`: arm-then-fire, delay boundary, reset-on-reactivation,
  never-fires-without-a-call, fires-once. Pure, synthetic samples.
- `AppRuntimePreferences`: defaults (`false` / `5`) + override round-trip.
- `SettingsViewModel`: toggle + delay properties persist.
- `MicInputProbe`/Core Audio adapter: thin, spike-verified; not unit-tested (HW).

## Out of scope
Soft-confirm prompt (deferred; ADR-023 Phase 1 alt), VAD corroboration (Phase 2),
voice-memo auto-stop, FaceTime, per-app delay. ADR-023 status updated to "Phase 0
done, Phase 1 implemented (hard auto-stop, configurable delay, default off)".
