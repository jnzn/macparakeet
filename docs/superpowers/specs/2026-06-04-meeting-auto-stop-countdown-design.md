# Meeting auto-stop — cancellable countdown pill (design)

> **Date:** 2026-06-04 · **Status:** approved, implementing · **Fixes:** audit PDX-014
> (`docs/audits/2026-06-04-pdx-subsystems-audit.md`).

## Problem

ADR-023 activity auto-stop fires `.stopRequested` directly with no confirmation or
undo (`MeetingRecordingFlowCoordinator.swift:760-765`). A background browser tab that
grabbed then released the mic can stop a recording the user wanted to keep — silent,
irreversible loss of the remainder (invariant 1).

## Goal

When auto-stop fires, give the user a brief, visible, cancellable grace window before
the recording actually stops. **No change to detection** (detector / monitor /
`MicInputProbe` / allowlist stay exactly as-is — owner declined the frontmost gate and
allowlist trim).

## Design

**Timing (contained):** keep the detector's existing release-debounce. When it fires,
the coordinator starts a visible countdown of `meetingAutoStopDelaySeconds` (default 5s)
instead of stopping, and tears the monitor down (so it can't re-fire this session).

**Authoritative timing** lives in a new `MeetingAutoStopCountdown` (`@MainActor`,
`Sources/MacParakeet/App/`): `start(seconds:onExpire:)` runs a cancellable `Task`;
`cancel()` stops it; `isActive` reflects state. `sleep` is injectable so the
cancel-prevents-stop behavior is unit-testable deterministically.

**View model** (`MeetingRecordingPanelViewModel`): add
`autoStopCountdownDuration: TimeInterval?` (nil = inactive) and
`onCancelAutoStop: (() -> Void)?`. No other logic.

**View** (`MeetingRecordingPanelView.header`): when `autoStopCountdownDuration != nil`,
replace the left identity cluster (audio orb + "Recording" + elapsed timer,
`:206-228`) with a **red/pink countdown pill** that mirrors `StopRecordingButton`'s
confirm state (`MeetingRecordingStopButton.swift:31-46,90-106`): a `Capsule` with a
depleting `errorRed`-tinted fill animated 1→0 over the duration, labeled
**"Keep recording"**. The whole pill is the cancel button → `onCancelAutoStop`. The
right-side mute / pause / **manual Stop** buttons stay visible (the user can still end
now).

**Outcomes:**
- Countdown expires → coordinator `sendEvent(.stopRequested)` (the recording stops).
- User clicks the pill → `cancel()` + clear `autoStopCountdownDuration`; recording
  continues; monitor stays down (auto-stop killed for this recording — no re-pester).
- Recording stopped / paused / cancelled by any other path during the countdown →
  cancel the countdown and clear state.

## Testing

- `MeetingAutoStopCountdownTests` (new): cancel-before-expiry never calls `onExpire`;
  expiry calls `onExpire` exactly once; restart supersedes a prior countdown. Injected
  `sleep` gate → deterministic, no wall-clock flake.
- Build verification for the SwiftUI pill; manual/visual check of the countdown + cancel.

## Out of scope

Detection heuristics (frontmost check / allowlist contents) — explicitly unchanged.
