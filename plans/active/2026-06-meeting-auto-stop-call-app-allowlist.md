# Meeting Auto-Stop: Call-App Allowlist

> Status: **PROPOSAL** — design approved in conversation 2026-06-02; implementation pending.
> Related: ADR-023 (activity-based meeting auto-stop), `MeetingCallActivity`, `MeetingCallActivityMonitor`, `MicInputProbe`.

## Problem

ADR-023 Phase 1 detection treats **any** non-excluded mic-capturing process as
"the call":

- Any app that touches the mic arms the detector — even apps that have nothing
  to do with the meeting being recorded.
- Any app that *keeps holding* the mic after the real call ends blocks auto-stop
  forever (the detector requires zero non-excluded capture for the full delay).
- The exclusion list is a denylist (`com.macparakeet` prefix +
  `com.apple.avconferenced`), which has to anticipate every irrelevant
  mic user instead of naming the relevant ones.

The owner's request: name the apps auto-stop should key off (Teams, Zoom,
browsers, …) instead of reacting to any and all mic activity.

## Decision

Replace the denylist detection with a **user-editable allowlist of call apps**,
matched by **bundle-ID prefix**.

> A call is active **iff** any mic-capturing process's bundle ID starts with
> any prefix in the allowlist.

- Pre-seeded with common call apps (including Safari and Chrome — the owner
  wants browser meetings to work with zero configuration).
- Apps are added by picking from **what is using the mic right now**
  (reuses `MicInputProbe`), so the stored ID is exactly what the detector
  will observe.
- **Empty allowlist → the detector never arms → auto-stop is inert.** The
  Settings UI shows a hint when the list is empty while the toggle is on.
- The existing exclusion lists become unnecessary for detection. MacParakeet
  itself can never enter the allowlist (the picker hides it).

### Accepted trade-off (browsers in the allowlist)

Any browser tab using the mic counts as a call. Scoping (confirmed with owner
2026-06-02):

- During a real call that holds the mic, a random mic tab cannot cause a
  premature stop — the detector fires only when **all** allowlisted apps have
  released the mic for the full delay.
- A false trigger requires: recording active + no real call holding the mic +
  a tab grabs the mic (arms) + releases it (fires after delay). Acceptable.
- A lingering mic tab can *delay* auto-stop after the real call ends. Also
  acceptable; the configurable delay (2–120 s) is the guardrail.

## Data Model

New Core type in `Sources/MacParakeetCore/MeetingRecording/MeetingCallApp.swift`
(mirrors the `AppProfile.bundleIDs` pattern):

```swift
public struct MeetingCallApp: Codable, Equatable, Sendable, Identifiable {
    public var id: String { displayName }
    public var displayName: String
    /// Matched with `hasPrefix` against CoreAudio-reported bundle IDs.
    public var bundleIDPrefixes: [String]
}
```

Storage: JSON-encoded array in `UserDefaults` under
`UserDefaultsAppRuntimePreferences.meetingAutoStopCallAppsKey`. Written with
pre-seeded defaults on first read; fully user-editable afterwards.

### Pre-seeded defaults

| App | Prefixes |
|---|---|
| Microsoft Teams | `com.microsoft.teams2`, `com.microsoft.teams` |
| Zoom | `us.zoom.xos` |
| FaceTime | `com.apple.FaceTime` |
| Slack | `com.tinyspeck.slackmacgap` |
| Safari | `com.apple.Safari`, `com.apple.WebKit` |
| Google Chrome | `com.google.Chrome` |

Browser capture is often attributed to helper processes
(`com.apple.WebKit.GPU`, `com.google.Chrome.helper`), which is why matching is
prefix-based and Safari carries the `com.apple.WebKit` prefix.

> **Verification step (required during implementation):** run
> `macparakeet-cli mic-processes --watch`, perform a Safari mic test and a
> Chrome mic test, and record the exact bundle IDs CoreAudio reports. Adjust
> the pre-seed prefixes if reality differs from the table.

## Detection Changes

`Sources/MacParakeetCore/MeetingRecording/MeetingCallActivity.swift`:

- `isCall(capturingBundleIDs:)` → `isCall(capturingBundleIDs:allowedPrefixes:)`.
- A capturing bundle ID counts iff it `hasPrefix` any allowlisted prefix.
- `excludedBundleIDs` / `excludedPrefixes` no longer participate in call
  detection. They are retained on `MeetingCallActivity` for one purpose only:
  the Settings add sheet uses them to hide MacParakeet itself and
  `com.apple.avconferenced` from the "apps using the mic" picker.

`MeetingAutoStopDetector` is unchanged — it already consumes a boolean
`isCallActive` sample.

## Monitor + Coordinator Changes

`Sources/MacParakeet/App/MeetingCallActivityMonitor.swift`:

- Takes `allowedPrefixes: [String]` at construction — snapshotted at recording
  start, same as the delay value. List edits mid-recording apply to the next
  recording.
- **Pause bug fix:** today, if the detector fires while the recording is
  paused, `onAutoStop` is dropped (`guard state == .recording`) but the poll
  loop `break`s — auto-stop is dead for the rest of that recording. Fix: only
  `break` when the stop was actually delivered; otherwise reset the detector
  and keep polling.
- **Logging:** add `Logger(subsystem: "com.macparakeet", category: "MeetingAutoStop")`
  lines for: monitor started (with allowlist), armed (by which bundle ID),
  release window started, fired, and blocked-by (which bundle IDs are still
  capturing). Without this the feature is undiagnosable from logs.

`Sources/MacParakeet/App/MeetingRecordingFlowCoordinator.swift`:

- `startCallActivityMonitorIfEnabled()` reads the call-app list from prefs and
  passes the flattened prefixes to the monitor.

## Settings UI

`Sources/MacParakeet/Views/Settings/SettingsView.swift` +
`Sources/MacParakeetViewModels/SettingsViewModel.swift`.

Under the existing "Auto-stop recording when the call ends" toggle (visible
only when the toggle is on):

```
Call apps                                    [+ Add app…]
┌──────────────────────────────────────────────┐
│ Microsoft Teams   com.microsoft.teams2…   ⊖  │
│ Zoom              us.zoom.xos             ⊖  │
│ Safari            com.apple.Safari…       ⊖  │
│ Google Chrome     com.google.Chrome       ⊖  │
└──────────────────────────────────────────────┘
```

- Row: display name + first prefix (truncated) + remove button.
- Empty-list state shows: *"Auto-stop needs at least one call app to watch."*
- **Add sheet:** polls `MicInputProbe.capturingInputBundleIDs()` every ~1.5 s
  and lists apps currently capturing the mic — hiding MacParakeet itself and
  `com.apple.avconferenced`. Display names resolved via
  `NSRunningApplication`. Click to add (stores the exact observed bundle ID).
  Empty state: *"No apps are using the microphone right now. Join a call,
  then add it from here."*

## Testing

- `MeetingCallActivity.isCall` allowlist semantics: match, prefix match,
  no match, empty allowlist, nil/empty bundle IDs.
- `MeetingCallApp` prefs JSON round-trip + first-read seeding.
- Monitor with stubbed `capturingBundleIDs`: arm → release → fire; pause →
  dropped stop → detector re-arms → fires after resume.
- SettingsViewModel: add/remove/persist call apps.

## Documentation

- ADR-023 amendment: Phase 1.5 — allowlist detection replaces any-app
  detection; record the trade-off scoping above.
- `mic-processes` CLI: label allowlisted apps (`<- call app (allowlisted)`)
  instead of the current exclusion labels.

## Out of Scope

- Auto-bind to the mic holder at record start (ADR-023 §2 original design) —
  superseded by the allowlist.
- Soft-confirm prompt before stopping (ADR-023 Phase 2) — unchanged, still
  proposed.
- Re-arming the monitor when the toggle/list changes mid-recording.
- Activity-based auto-*start* — explicitly out of scope per ADR-023 §5.
