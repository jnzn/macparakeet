# Activity-Based Meeting Auto-Stop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Auto-stop a meeting recording a configurable number of seconds (default 5) after the recorded call app releases the microphone — opt-in via a Settings toggle (default off) with an editable delay.

**Architecture:** A pure `MeetingAutoStopDetector` state machine (arm on first call-active, fire after N seconds of call-inactive) is fed by a `MeetingCallActivityMonitor` that polls the macOS Core Audio per-process input API (`MicInputProbe`, validated by the `mic-processes` spike) and computes "is a call active" via a pure filter that excludes MacParakeet + `com.apple.avconferenced`. `MeetingRecordingFlowCoordinator` runs the monitor during a recording (when the toggle is on) and, on fire, routes through the normal `.stopRequested` path.

**Tech Stack:** Swift 6, CoreAudio (macOS 14.2+), `@MainActor @Observable`, GRDB-adjacent UserDefaults prefs, XCTest. Work in `/Users/jnzn08/Developer/macparakeet`. Build `swift build`; focused tests only (`swift test --filter …` — the full suite hangs). Commit per task. Spec: `docs/superpowers/specs/2026-06-01-meeting-auto-stop-design.md`; ADR `spec/adr/023-activity-based-meeting-auto-stop.md`.

---

## File Structure

| File | Responsibility | Action |
|------|----------------|--------|
| `Sources/MacParakeetCore/MeetingRecording/MeetingAutoStopDetector.swift` | pure arm/fire state machine | Create |
| `Sources/MacParakeetCore/MeetingRecording/MeetingCallActivity.swift` | pure "is a call active" filter (exclusions) | Create |
| `Sources/MacParakeetCore/Audio/MicInputProbe.swift` | Core Audio: bundle IDs capturing mic input | Create |
| `Sources/MacParakeet/App/MeetingCallActivityMonitor.swift` | timer poll → filter → detector → onAutoStop | Create |
| `Sources/MacParakeetCore/AppRuntimePreferences.swift` | `meetingAutoStopEnabled` + `meetingAutoStopDelaySeconds` | Modify |
| `Sources/MacParakeet/App/MeetingRecordingFlowCoordinator.swift` | start/stop monitor with recording; fire → `.stopRequested` | Modify |
| `Sources/MacParakeetViewModels/SettingsViewModel.swift` | toggle + delay properties | Modify |
| `Sources/MacParakeet/Views/Settings/SettingsView.swift` | toggle + editable delay in Meetings card | Modify |
| `Sources/CLI/Commands/MicProcessesCommand.swift` | repoint spike to the promoted `MicInputProbe` | Modify |
| `spec/adr/023-activity-based-meeting-auto-stop.md` | status → Phase 1 implemented | Modify |
| Tests: `MeetingAutoStopDetectorTests`, `MeetingCallActivityTests`, `AppRuntimePreferencesTests` (extend), `SettingsViewModelTests` (extend) | | Create/Modify |

---

## Task 1: MeetingAutoStopDetector (pure state machine)

**Files:**
- Create: `Sources/MacParakeetCore/MeetingRecording/MeetingAutoStopDetector.swift`
- Test: `Tests/MacParakeetTests/MeetingRecording/MeetingAutoStopDetectorTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import MacParakeetCore

final class MeetingAutoStopDetectorTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func testNeverFiresWithoutACall() {
        var d = MeetingAutoStopDetector(delaySeconds: 5)
        for s in stride(from: 0.0, through: 30.0, by: 1.5) {
            XCTAssertEqual(d.sample(isCallActive: false, now: at(s)), .none)
        }
    }

    func testFiresAfterDelayOnceArmed() {
        var d = MeetingAutoStopDetector(delaySeconds: 5)
        XCTAssertEqual(d.sample(isCallActive: true, now: at(0)), .none)   // arm
        XCTAssertEqual(d.sample(isCallActive: false, now: at(1)), .none)  // released @1
        XCTAssertEqual(d.sample(isCallActive: false, now: at(5)), .none)  // 4s < 5
        XCTAssertEqual(d.sample(isCallActive: false, now: at(6)), .autoStop) // 5s elapsed
    }

    func testReactivationResetsTheTimer() {
        var d = MeetingAutoStopDetector(delaySeconds: 5)
        _ = d.sample(isCallActive: true, now: at(0))    // arm
        _ = d.sample(isCallActive: false, now: at(1))   // released @1
        XCTAssertEqual(d.sample(isCallActive: true, now: at(3)), .none)  // call back -> reset
        XCTAssertEqual(d.sample(isCallActive: false, now: at(4)), .none) // released @4
        XCTAssertEqual(d.sample(isCallActive: false, now: at(8)), .none) // 4s < 5
        XCTAssertEqual(d.sample(isCallActive: false, now: at(9)), .autoStop) // 5s from @4
    }

    func testFiresOnlyOnce() {
        var d = MeetingAutoStopDetector(delaySeconds: 5)
        _ = d.sample(isCallActive: true, now: at(0))
        _ = d.sample(isCallActive: false, now: at(1))
        XCTAssertEqual(d.sample(isCallActive: false, now: at(6)), .autoStop)
        XCTAssertEqual(d.sample(isCallActive: false, now: at(7)), .none)
        XCTAssertEqual(d.sample(isCallActive: true, now: at(8)), .none)   // stays fired
        XCTAssertEqual(d.sample(isCallActive: false, now: at(20)), .none)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MeetingAutoStopDetectorTests`
Expected: FAIL — `MeetingAutoStopDetector` not found.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Pure arm/fire state machine for activity-based meeting auto-stop (ADR-023).
/// Fed one `isCallActive` sample per poll; emits `.autoStop` exactly once, after
/// the call has been inactive for `delaySeconds` — but only after a call was seen
/// at least once during this recording (so in-person recordings never fire).
public struct MeetingAutoStopDetector {
    public enum Decision: Equatable { case none, autoStop }

    private enum Phase: Equatable {
        case disarmed
        case armed(releasedSince: Date?)
        case fired
    }

    public let delaySeconds: TimeInterval
    private var phase: Phase = .disarmed

    public init(delaySeconds: TimeInterval) {
        self.delaySeconds = delaySeconds
    }

    public mutating func sample(isCallActive: Bool, now: Date) -> Decision {
        switch phase {
        case .fired:
            return .none
        case .disarmed:
            if isCallActive { phase = .armed(releasedSince: nil) }
            return .none
        case .armed:
            if isCallActive {
                phase = .armed(releasedSince: nil)   // reset the release timer
                return .none
            }
            let since: Date
            if case .armed(let r) = phase, let r { since = r } else { since = now }
            if now.timeIntervalSince(since) >= delaySeconds {
                phase = .fired
                return .autoStop
            }
            phase = .armed(releasedSince: since)
            return .none
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MeetingAutoStopDetectorTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacParakeetCore/MeetingRecording/MeetingAutoStopDetector.swift Tests/MacParakeetTests/MeetingRecording/MeetingAutoStopDetectorTests.swift
git commit -m "feat(pdx): MeetingAutoStopDetector arm/fire state machine (ADR-023)"
```

---

## Task 2: MeetingCallActivity (pure exclusion filter)

**Files:**
- Create: `Sources/MacParakeetCore/MeetingRecording/MeetingCallActivity.swift`
- Test: `Tests/MacParakeetTests/MeetingRecording/MeetingCallActivityTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import MacParakeetCore

final class MeetingCallActivityTests: XCTestCase {
    func testTeamsCountsAsCall() {
        XCTAssertTrue(MeetingCallActivity.isCall(capturingBundleIDs: ["com.microsoft.teams2"]))
    }
    func testExcludesAVConferencedDaemon() {
        XCTAssertFalse(MeetingCallActivity.isCall(capturingBundleIDs: ["com.apple.avconferenced"]))
    }
    func testExcludesMacParakeetOwnCapture() {
        XCTAssertFalse(MeetingCallActivity.isCall(capturingBundleIDs: ["com.macparakeet.pdx"]))
        XCTAssertFalse(MeetingCallActivity.isCall(capturingBundleIDs: ["com.macparakeet.MacParakeet"]))
    }
    func testCallAlongsideDaemonStillCounts() {
        XCTAssertTrue(MeetingCallActivity.isCall(capturingBundleIDs: ["com.apple.avconferenced", "us.zoom.xos"]))
    }
    func testNilOrEmptyIsNotACall() {
        XCTAssertFalse(MeetingCallActivity.isCall(capturingBundleIDs: []))
        XCTAssertFalse(MeetingCallActivity.isCall(capturingBundleIDs: [nil]))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MeetingCallActivityTests`
Expected: FAIL — `MeetingCallActivity` not found.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Decides whether any *non-MacParakeet, non-system-daemon* process is capturing
/// the microphone — i.e. "we appear to be in a call." The `avconferenced`
/// exclusion came from the ADR-023 Phase 0 spike (it holds the mic persistently
/// on some Macs and would otherwise never release).
public enum MeetingCallActivity {
    /// System audio daemons that hold the mic but do not represent a user call.
    public static let excludedBundleIDs: Set<String> = ["com.apple.avconferenced"]
    /// MacParakeet's own meeting capture (varies by edition/bundle id).
    public static let excludedPrefixes: [String] = ["com.macparakeet"]

    public static func isCall(capturingBundleIDs: [String?]) -> Bool {
        capturingBundleIDs.contains { bundleID in
            guard let bundleID, !bundleID.isEmpty else { return false }  // unknown → ignore
            if excludedBundleIDs.contains(bundleID) { return false }
            if excludedPrefixes.contains(where: { bundleID.hasPrefix($0) }) { return false }
            return true
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MeetingCallActivityTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacParakeetCore/MeetingRecording/MeetingCallActivity.swift Tests/MacParakeetTests/MeetingRecording/MeetingCallActivityTests.swift
git commit -m "feat(pdx): MeetingCallActivity filter (exclude MacParakeet + avconferenced)"
```

---

## Task 3: MicInputProbe in Core (promote from the CLI spike)

**Files:**
- Create: `Sources/MacParakeetCore/Audio/MicInputProbe.swift`
- Modify: `Sources/CLI/Commands/MicProcessesCommand.swift` (use the Core type)

No unit test (Core Audio HW adapter — the spike already validated it live). Verified by `swift build` + the CLI probe still running.

- [ ] **Step 1: Create the Core probe**

Move the probe logic from `MicProcessesCommand.swift` into Core, as the single source of truth:

```swift
import CoreAudio
import Foundation

/// Read-only Core Audio probe (macOS 14.2+): bundle IDs of processes currently
/// capturing microphone input. Validated by the ADR-023 Phase 0 `mic-processes`
/// spike. Pair with `MeetingCallActivity.isCall(capturingBundleIDs:)`.
public enum MicInputProbe {
    /// Bundle IDs of every process currently running audio input (incl. nil for
    /// processes without a bundle id). No filtering — callers apply exclusions.
    public static func capturingInputBundleIDs() -> [String?] {
        processObjectIDs()
            .filter { boolProperty($0, kAudioProcessPropertyIsRunningInput) }
            .map { stringProperty($0, kAudioProcessPropertyBundleID) }
    }

    private static func processObjectIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func boolProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &address) else { return false }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    private static func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var cfString: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &cfString) == noErr else { return nil }
        return cfString as String?
    }
}
```

- [ ] **Step 2: Repoint the CLI spike to the Core probe**

In `MicProcessesCommand.swift`, delete the local `MicInputProbe` enum and rewrite `printSnapshot()` to use the Core type:

```swift
    private func printSnapshot() {
        let ids = MicInputProbe.capturingInputBundleIDs()
        let stamp = MicProcessesCommand.timeFormatter.string(from: Date())
        if ids.isEmpty {
            print("[\(stamp)] (no process is capturing mic input)")
            return
        }
        print("[\(stamp)] capturing mic input:")
        for id in ids.map({ $0 ?? "(unknown)" }).sorted() {
            let tag = (id.hasPrefix("com.macparakeet")) ? "  <- MacParakeet (excluded)"
                : MeetingCallActivity.excludedBundleIDs.contains(id) ? "  <- system daemon (excluded)" : ""
            print("    bundle=\(id)\(tag)")
        }
    }
```
(Keep `import MacParakeetCore`; drop `import CoreAudio` if now unused.)

- [ ] **Step 3: Build + smoke-test the CLI**

Run: `swift build && swift run macparakeet-cli mic-processes`
Expected: build succeeds; prints a snapshot (exit 0).

- [ ] **Step 4: Commit**

```bash
git add Sources/MacParakeetCore/Audio/MicInputProbe.swift Sources/CLI/Commands/MicProcessesCommand.swift
git commit -m "refactor(pdx): promote MicInputProbe to Core; CLI spike reuses it"
```

---

## Task 4: AppRuntimePreferences — toggle + delay keys

**Files:**
- Modify: `Sources/MacParakeetCore/AppRuntimePreferences.swift`
- Test: `Tests/MacParakeetTests/AppRuntimePreferencesTests.swift` (create if absent)

- [ ] **Step 1: Write the failing tests**

Create/extend `Tests/MacParakeetTests/AppRuntimePreferencesTests.swift`:

```swift
import XCTest
@testable import MacParakeetCore

final class AppRuntimePreferencesAutoStopTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let s = "prefs-\(UUID().uuidString)"; let d = UserDefaults(suiteName: s)!
        d.removePersistentDomain(forName: s); return d
    }
    func testDefaults() {
        let p = UserDefaultsAppRuntimePreferences(defaults: defaults())
        XCTAssertFalse(p.meetingAutoStopEnabled)
        XCTAssertEqual(p.meetingAutoStopDelaySeconds, 5)
    }
    func testOverrides() {
        let d = defaults()
        d.set(true, forKey: UserDefaultsAppRuntimePreferences.meetingAutoStopEnabledKey)
        d.set(12, forKey: UserDefaultsAppRuntimePreferences.meetingAutoStopDelaySecondsKey)
        let p = UserDefaultsAppRuntimePreferences(defaults: d)
        XCTAssertTrue(p.meetingAutoStopEnabled)
        XCTAssertEqual(p.meetingAutoStopDelaySeconds, 12)
    }
}
```

- [ ] **Step 2: Run to verify fail**

Run: `swift test --filter AppRuntimePreferencesAutoStopTests`
Expected: FAIL — members don't exist.

- [ ] **Step 3: Implement**

In `AppRuntimePreferences.swift`: add to the protocol `AppRuntimePreferencesProtocol`:
```swift
    var meetingAutoStopEnabled: Bool { get }
    var meetingAutoStopDelaySeconds: Int { get }
```
Add the static keys in `UserDefaultsAppRuntimePreferences` (next to the other keys):
```swift
    public static let meetingAutoStopEnabledKey = "meetingAutoStopEnabled"
    public static let meetingAutoStopDelaySecondsKey = "meetingAutoStopDelaySeconds"
```
Add the concrete accessors:
```swift
    public var meetingAutoStopEnabled: Bool {
        defaults.object(forKey: Self.meetingAutoStopEnabledKey) as? Bool ?? false
    }
    public var meetingAutoStopDelaySeconds: Int {
        let v = defaults.object(forKey: Self.meetingAutoStopDelaySecondsKey) as? Int ?? 5
        return min(max(v, 2), 120)   // clamp to sane bounds
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter AppRuntimePreferencesAutoStopTests`
Expected: PASS (2 tests). (Search for other `AppRuntimePreferencesProtocol` conformances — e.g. a test mock — and add the two members; build will flag them.)

- [ ] **Step 5: Build (catch other conformers) + commit**

Run: `swift build` — fix any mock conformances (add `var meetingAutoStopEnabled: Bool { false }` / `var meetingAutoStopDelaySeconds: Int { 5 }`).
```bash
git add Sources/MacParakeetCore/AppRuntimePreferences.swift Tests/MacParakeetTests/AppRuntimePreferencesTests.swift <any mocks>
git commit -m "feat(pdx): meetingAutoStop enabled + delay prefs (default off / 5s)"
```

---

## Task 5: MeetingCallActivityMonitor (timer poll → detector)

**Files:**
- Create: `Sources/MacParakeet/App/MeetingCallActivityMonitor.swift`

No unit test (timer + Core Audio). Logic is covered by Tasks 1–2. Verified by `swift build`.

- [ ] **Step 1: Implement**

```swift
import Foundation
import MacParakeetCore

/// Polls mic-capturing processes while a meeting recording is active and, when the
/// recorded call ends (call app releases the mic for the configured delay), invokes
/// `onAutoStop`. Only created/started when the meeting auto-stop toggle is on.
@MainActor
final class MeetingCallActivityMonitor {
    private var task: Task<Void, Never>?
    private var detector: MeetingAutoStopDetector
    private let pollInterval: TimeInterval
    private let capturingBundleIDs: @MainActor () -> [String?]
    private let onAutoStop: @MainActor () -> Void

    init(
        delaySeconds: Int,
        pollInterval: TimeInterval = 1.5,
        capturingBundleIDs: @escaping @MainActor () -> [String?] = { MicInputProbe.capturingInputBundleIDs() },
        onAutoStop: @escaping @MainActor () -> Void
    ) {
        self.detector = MeetingAutoStopDetector(delaySeconds: TimeInterval(delaySeconds))
        self.pollInterval = pollInterval
        self.capturingBundleIDs = capturingBundleIDs
        self.onAutoStop = onAutoStop
    }

    func start() {
        task?.cancel()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let active = MeetingCallActivity.isCall(capturingBundleIDs: self.capturingBundleIDs())
                if self.detector.sample(isCallActive: active, now: Date()) == .autoStop {
                    self.onAutoStop()
                    break   // fire once; coordinator tears the monitor down
                }
                try? await Task.sleep(for: .seconds(self.pollInterval))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
```

- [ ] **Step 2: Build + commit**

Run: `swift build` (expected: succeeds).
```bash
git add Sources/MacParakeet/App/MeetingCallActivityMonitor.swift
git commit -m "feat(pdx): MeetingCallActivityMonitor (poll mic-process activity → auto-stop)"
```

---

## Task 6: Wire the monitor into the recording flow

**Files:**
- Modify: `Sources/MacParakeet/App/MeetingRecordingFlowCoordinator.swift`

No unit test (app wiring). Verified by `swift build` + existing meeting tests.

- [ ] **Step 1: Add a stored monitor + a preferences read**

`grep -n "private var pillPollingTask" Sources/MacParakeet/App/MeetingRecordingFlowCoordinator.swift` and add nearby:
```swift
    private var callActivityMonitor: MeetingCallActivityMonitor?
```
The coordinator already has access to a `UserDefaults`/preferences source for meeting audio mode (`meetingAudioSourceModeProvider`). Add an injected preferences accessor the same way, or read `UserDefaultsAppRuntimePreferences()` directly. Use `UserDefaultsAppRuntimePreferences(defaults: .standard)` for the two new flags (consistent with how other one-off reads are done — confirm with `grep -n "UserDefaultsAppRuntimePreferences(" Sources/MacParakeet/App/*.swift`).

- [ ] **Step 2: Start the monitor when capture begins; stop it on teardown**

`grep -n "startPillPolling()" Sources/MacParakeet/App/MeetingRecordingFlowCoordinator.swift` — the monitor's lifecycle mirrors the pill polling. Where `startPillPolling()` is invoked (entering the recording/pill flow), add:
```swift
        startCallActivityMonitorIfEnabled()
```
Where `stopPillPolling()` is invoked (`.hidePill`, error, teardown), add `stopCallActivityMonitor()`. Then implement:
```swift
    private func startCallActivityMonitorIfEnabled() {
        let prefs = UserDefaultsAppRuntimePreferences(defaults: .standard)
        guard prefs.meetingAutoStopEnabled else { return }
        callActivityMonitor?.stop()
        let monitor = MeetingCallActivityMonitor(
            delaySeconds: prefs.meetingAutoStopDelaySeconds,
            onAutoStop: { [weak self] in
                guard let self else { return }
                guard self.stateMachine.state == .recording else { return }
                Telemetry.send(.settingChanged(setting: .silenceAutoStop)) // placeholder; replace per Step 4 telemetry note
                self.sendEvent(.stopRequested)
            }
        )
        callActivityMonitor = monitor
        monitor.start()
    }

    private func stopCallActivityMonitor() {
        callActivityMonitor?.stop()
        callActivityMonitor = nil
    }
```

- [ ] **Step 3: Guard against double-stop**

In the `onAutoStop` closure, the `guard self.stateMachine.state == .recording` ensures we only auto-stop a live recording (not while already stopping/idle). `sendEvent(.stopRequested)` is the same path the menu/hotkey use.

- [ ] **Step 4: Telemetry (replace the placeholder)**

`grep -n "case meetingRecording\|enum TelemetryEvent\|meetingRecordingCompleted" Sources/MacParakeetCore/Services/Telemetry/TelemetryEvent.swift`. If adding a dedicated event is heavy, drop the telemetry line entirely for v1 (no event) rather than misusing `silenceAutoStop`. Minimum: remove the placeholder `Telemetry.send(...)` line so no wrong event is emitted.

- [ ] **Step 5: Build + run meeting tests**

Run: `swift build && swift test --filter MeetingRecordingFlowStateMachineTests`
Expected: build succeeds; state-machine tests pass (the monitor doesn't change the state machine).

- [ ] **Step 6: Commit**

```bash
git add Sources/MacParakeet/App/MeetingRecordingFlowCoordinator.swift
git commit -m "feat(pdx): run call-activity monitor during recording; auto-stop on call end"
```

---

## Task 7: Settings — toggle + editable delay (Meetings card)

**Files:**
- Modify: `Sources/MacParakeetViewModels/SettingsViewModel.swift`
- Modify: `Sources/MacParakeet/Views/Settings/SettingsView.swift`
- Test: `Tests/MacParakeetTests/ViewModels/SettingsViewModelTests.swift` (extend)

- [ ] **Step 1: Write the failing VM test**

Append to `SettingsViewModelTests.swift` (mirror existing property tests):
```swift
    func testMeetingAutoStopPropertiesPersist() {
        let d = UserDefaults(suiteName: "svm-\(UUID().uuidString)")!
        let vm = SettingsViewModel(defaults: d)   // use the existing init pattern
        vm.meetingAutoStopEnabled = true
        vm.meetingAutoStopDelaySeconds = 15
        XCTAssertTrue(d.bool(forKey: UserDefaultsAppRuntimePreferences.meetingAutoStopEnabledKey))
        XCTAssertEqual(d.integer(forKey: UserDefaultsAppRuntimePreferences.meetingAutoStopDelaySecondsKey), 15)
    }
```
(Confirm the `SettingsViewModel` test init signature with `grep -n "SettingsViewModel(" Tests/MacParakeetTests/ViewModels/SettingsViewModelTests.swift`.)

- [ ] **Step 2: Run to verify fail**

Run: `swift test --filter SettingsViewModelTests/testMeetingAutoStopPropertiesPersist`
Expected: FAIL — properties don't exist.

- [ ] **Step 3: Add VM properties (mirror `silenceAutoStop`/`silenceDelay`)**

In `SettingsViewModel.swift`, next to `silenceAutoStop`/`silenceDelay`:
```swift
    public var meetingAutoStopEnabled: Bool {
        didSet { defaults.set(meetingAutoStopEnabled, forKey: UserDefaultsAppRuntimePreferences.meetingAutoStopEnabledKey) }
    }
    public var meetingAutoStopDelaySeconds: Int {
        didSet { defaults.set(meetingAutoStopDelaySeconds, forKey: UserDefaultsAppRuntimePreferences.meetingAutoStopDelaySecondsKey) }
    }
```
In the VM init/load (where `silenceAutoStop`/`silenceDelay` are loaded, ~line 561):
```swift
        meetingAutoStopEnabled = defaults.object(forKey: UserDefaultsAppRuntimePreferences.meetingAutoStopEnabledKey) as? Bool ?? false
        let autoStopDelay = defaults.object(forKey: UserDefaultsAppRuntimePreferences.meetingAutoStopDelaySecondsKey) as? Int ?? 5
        meetingAutoStopDelaySeconds = min(max(autoStopDelay, 2), 120)
```
(Initialize them before first use if the VM uses a phased init; match the surrounding pattern.)

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter SettingsViewModelTests`
Expected: PASS.

- [ ] **Step 5: Add the Settings UI (Meetings card)**

In `SettingsView.swift`, in the **Meeting Recording** card (`grep -n "Meeting Recording" Sources/MacParakeet/Views/Settings/SettingsView.swift` for the section), add a toggle + an inline editable delay box:
```swift
                Divider()
                settingsToggleRow(
                    title: "Auto-stop recording when the call ends",
                    detail: "Stops & saves automatically a few seconds after the meeting app (Zoom, Teams, Meet…) releases the microphone.",
                    isOn: $viewModel.meetingAutoStopEnabled
                )
                if viewModel.meetingAutoStopEnabled {
                    Divider()
                    HStack(alignment: .center) {
                        rowText(
                            title: "Auto-stop delay",
                            detail: "Seconds of no call audio before the recording stops."
                        )
                        Spacer(minLength: DesignSystem.Spacing.md)
                        Stepper(value: $viewModel.meetingAutoStopDelaySeconds, in: 2...120) {
                            TextField("", value: $viewModel.meetingAutoStopDelaySeconds, format: .number)
                                .frame(width: 44)
                                .multilineTextAlignment(.trailing)
                                .textFieldStyle(.roundedBorder)
                            Text("sec")
                        }
                        .frame(width: 140)
                    }
                }
```
(If `Stepper` with an embedded `TextField` label renders awkwardly, fall back to a plain `TextField` + `Stepper` side by side in the `HStack`. The requirement is an editable box + a toggle.)

- [ ] **Step 6: Build + run app**

Run: `swift build` (succeeds). Then `scripts/dev/run_app.sh` — Settings → Meeting Recording shows the toggle (off) and, when on, an editable delay box defaulting to 5.

- [ ] **Step 7: Commit**

```bash
git add Sources/MacParakeetViewModels/SettingsViewModel.swift Sources/MacParakeet/Views/Settings/SettingsView.swift Tests/MacParakeetTests/ViewModels/SettingsViewModelTests.swift
git commit -m "feat(pdx): Settings — meeting auto-stop toggle + editable delay (default off / 5s)"
```

---

## Task 8: Docs — ADR-023 status + Feature Inventory

**Files:**
- Modify: `spec/adr/023-activity-based-meeting-auto-stop.md`
- Vault Feature Inventory (not git)

- [ ] **Step 1: Update ADR-023 status**

Change the status line from `**PROPOSAL** — not implemented` to:
`**ACCEPTED** — Phase 0 (spike) done 2026-06-01; Phase 1 implemented: hard auto-stop after a configurable delay (default 5s), opt-in Settings toggle (default off), detection excludes MacParakeet + com.apple.avconferenced. Phase 2 (VAD corroboration / soft-confirm) remains proposed.`
Add a one-line note under "Open Questions" that the Core Audio per-process input API was verified by the `mic-processes` spike (Teams acquire/release clean; `avconferenced` is persistent and excluded).

- [ ] **Step 2: Commit**

```bash
git add spec/adr/023-activity-based-meeting-auto-stop.md
git commit -m "docs(adr): ADR-023 → accepted; Phase 1 (activity-based auto-stop) implemented"
```

- [ ] **Step 3: Feature Inventory (vault)** — add a Layer-2 row (e.g. F28) for "Activity-based meeting auto-stop" with: detection (Core Audio mic-process, excl. MacParakeet + avconferenced), hard auto-stop after configurable delay (default 5s), opt-in toggle in Settings → Meetings, files (`MeetingAutoStopDetector`, `MeetingCallActivity`, `MicInputProbe`, `MeetingCallActivityMonitor`, flow wiring, prefs, settings), and the `mic-processes` dev probe. Verify-on-merge: re-check the avconferenced exclusion still filters cleanly.

---

## Self-Review

**Spec coverage:** detection adapter (T3) + filter (T2) + detector (T1) + monitor (T5) + prefs (T4) + flow wiring (T6) + Settings toggle/delay (T7) + ADR/inventory (T8). All spec sections covered.

**Placeholder scan:** complete code for logic/prefs/VM; UI + wiring are build-verified with grep-first notes for real call-sites (`startPillPolling`, the Meetings card, the VM init, mock conformers). The telemetry line in T6 Step 2 is explicitly flagged as a placeholder to replace/remove in T6 Step 4 — not left in.

**Type consistency:** `MeetingAutoStopDetector.sample(isCallActive:now:) -> .none/.autoStop`; `MeetingCallActivity.isCall(capturingBundleIDs:)`; `MicInputProbe.capturingInputBundleIDs() -> [String?]`; `MeetingCallActivityMonitor(delaySeconds:pollInterval:capturingBundleIDs:onAutoStop:)`; prefs `meetingAutoStopEnabled: Bool` + `meetingAutoStopDelaySeconds: Int` + keys `meetingAutoStopEnabledKey`/`meetingAutoStopDelaySecondsKey`; VM `meetingAutoStopEnabled`/`meetingAutoStopDelaySeconds`. Consistent across tasks.
