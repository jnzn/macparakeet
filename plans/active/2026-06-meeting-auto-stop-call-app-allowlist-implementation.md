# Call-App Allowlist for Meeting Auto-Stop — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace ADR-023 Phase 1's any-app mic detection with a user-editable, prefix-matched allowlist of call apps (pre-seeded with Teams, Zoom, FaceTime, Slack, Safari, Chrome), plus a Settings UI to manage it.

**Architecture:** A new `MeetingCallApp` Core model is persisted as JSON in `UserDefaults`. `MeetingCallActivity` gains an allowlist-based `isCall` API; `MeetingCallActivityMonitor` consumes it, gets a pause-bug fix and os_log diagnostics. Settings shows the list under the existing auto-stop toggle with a live "apps using the mic" picker backed by `MicInputProbe`.

**Tech Stack:** Swift 6, SwiftUI, XCTest, CoreAudio (`MicInputProbe`), OSLog. Repo: `~/Developer/macparakeet`, branch `feature/pdx-next`.

**Spec:** `plans/active/2026-06-meeting-auto-stop-call-app-allowlist.md`

**Baseline check before starting:** `swift test` (all green).

---

### Task 1: `MeetingCallApp` model + pre-seeded defaults

**Files:**
- Create: `Sources/MacParakeetCore/MeetingRecording/MeetingCallApp.swift`
- Test: `Tests/MacParakeetTests/MeetingRecording/MeetingCallAppTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import MacParakeetCore

final class MeetingCallAppTests: XCTestCase {
    func testCodableRoundTrip() throws {
        let apps = [
            MeetingCallApp(displayName: "Microsoft Teams",
                           bundleIDPrefixes: ["com.microsoft.teams2", "com.microsoft.teams"]),
            MeetingCallApp(displayName: "Custom", bundleIDPrefixes: ["org.example.app"]),
        ]
        let data = try JSONEncoder().encode(apps)
        let decoded = try JSONDecoder().decode([MeetingCallApp].self, from: data)
        XCTAssertEqual(decoded, apps)
    }

    func testDefaultsIncludeOwnerCallApps() {
        let allPrefixes = MeetingCallApp.defaults.flatMap(\.bundleIDPrefixes)
        // Teams + browsers must work with zero configuration (spec §pre-seeds).
        XCTAssertTrue(allPrefixes.contains("com.microsoft.teams2"))
        XCTAssertTrue(allPrefixes.contains("com.apple.Safari"))
        XCTAssertTrue(allPrefixes.contains("com.apple.WebKit"))
        XCTAssertTrue(allPrefixes.contains("com.google.Chrome"))
        XCTAssertTrue(allPrefixes.contains("us.zoom.xos"))
    }

    func testDefaultsNeverIncludeMacParakeet() {
        let allPrefixes = MeetingCallApp.defaults.flatMap(\.bundleIDPrefixes)
        XCTAssertFalse(allPrefixes.contains { $0.hasPrefix("com.macparakeet") })
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MeetingCallAppTests 2>&1 | tail -20`
Expected: compile error — `cannot find 'MeetingCallApp' in scope`

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// A call app the meeting auto-stop detector watches (ADR-023 Phase 1.5).
/// Matching is prefix-based because browsers attribute mic capture to helper
/// processes (`com.apple.WebKit.GPU`, `com.google.Chrome.helper`, …) rather
/// than the browser's main bundle ID.
public struct MeetingCallApp: Codable, Equatable, Sendable, Identifiable {
    public var displayName: String
    /// Matched with `hasPrefix` against CoreAudio-reported bundle IDs.
    public var bundleIDPrefixes: [String]

    public var id: String { displayName }

    public init(displayName: String, bundleIDPrefixes: [String]) {
        self.displayName = displayName
        self.bundleIDPrefixes = bundleIDPrefixes
    }

    /// Pre-seeded call apps — used when the user has never edited the list.
    /// Safari carries `com.apple.WebKit` because WebKit GPU/WebContent helper
    /// processes are what CoreAudio attributes browser mic capture to.
    public static let defaults: [MeetingCallApp] = [
        MeetingCallApp(displayName: "Microsoft Teams",
                       bundleIDPrefixes: ["com.microsoft.teams2", "com.microsoft.teams"]),
        MeetingCallApp(displayName: "Zoom", bundleIDPrefixes: ["us.zoom.xos"]),
        MeetingCallApp(displayName: "FaceTime", bundleIDPrefixes: ["com.apple.FaceTime"]),
        MeetingCallApp(displayName: "Slack", bundleIDPrefixes: ["com.tinyspeck.slackmacgap"]),
        MeetingCallApp(displayName: "Safari",
                       bundleIDPrefixes: ["com.apple.Safari", "com.apple.WebKit"]),
        MeetingCallApp(displayName: "Google Chrome", bundleIDPrefixes: ["com.google.Chrome"]),
    ]
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MeetingCallAppTests 2>&1 | tail -20`
Expected: `Executed 3 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/MacParakeetCore/MeetingRecording/MeetingCallApp.swift \
        Tests/MacParakeetTests/MeetingRecording/MeetingCallAppTests.swift
git commit -m "feat(pdx): MeetingCallApp model + pre-seeded call-app defaults (ADR-023 Phase 1.5)"
```

---

### Task 2: Allowlist detection API on `MeetingCallActivity`

Additive only — the existing `isCall(capturingBundleIDs:)` stays until Task 5 so the monitor/CLI keep compiling.

**Files:**
- Modify: `Sources/MacParakeetCore/MeetingRecording/MeetingCallActivity.swift`
- Test: `Tests/MacParakeetTests/MeetingRecording/MeetingCallActivityTests.swift` (append new test class)

- [ ] **Step 1: Write the failing tests**

Append to `MeetingCallActivityTests.swift`:

```swift
final class MeetingCallActivityAllowlistTests: XCTestCase {
    private let teamsAndBrowsers = ["com.microsoft.teams2", "com.apple.Safari",
                                    "com.apple.WebKit", "com.google.Chrome"]

    func testAllowlistedAppCountsAsCall() {
        XCTAssertTrue(MeetingCallActivity.isCall(
            capturingBundleIDs: ["com.microsoft.teams2"],
            allowedPrefixes: teamsAndBrowsers))
    }

    func testPrefixMatchCoversHelperProcesses() {
        // Safari mic capture shows up as a WebKit helper; Chrome as a helper.
        XCTAssertTrue(MeetingCallActivity.isCall(
            capturingBundleIDs: ["com.apple.WebKit.GPU"],
            allowedPrefixes: teamsAndBrowsers))
        XCTAssertTrue(MeetingCallActivity.isCall(
            capturingBundleIDs: ["com.google.Chrome.helper"],
            allowedPrefixes: teamsAndBrowsers))
    }

    func testNonAllowlistedAppIsNotACall() {
        // Random mic users (voice memo app, system daemon) never arm auto-stop.
        XCTAssertFalse(MeetingCallActivity.isCall(
            capturingBundleIDs: ["com.apple.VoiceMemos", "com.apple.avconferenced"],
            allowedPrefixes: teamsAndBrowsers))
    }

    func testMacParakeetIsNotACallEvenIfSomehowListed() {
        // Self-capture can never arm the detector via the picker (the picker
        // hides MacParakeet), but even raw capture of our own bundle ID with a
        // normal allowlist must not count.
        XCTAssertFalse(MeetingCallActivity.isCall(
            capturingBundleIDs: ["com.macparakeet.pdx"],
            allowedPrefixes: teamsAndBrowsers))
    }

    func testEmptyAllowlistNeverDetectsACall() {
        XCTAssertFalse(MeetingCallActivity.isCall(
            capturingBundleIDs: ["com.microsoft.teams2"],
            allowedPrefixes: []))
    }

    func testNilAndEmptyBundleIDsAreIgnored() {
        XCTAssertFalse(MeetingCallActivity.isCall(
            capturingBundleIDs: [nil, ""],
            allowedPrefixes: teamsAndBrowsers))
    }

    func testMatchingBundleIDsReturnsOnlyAllowlistedMatches() {
        let matches = MeetingCallActivity.matchingBundleIDs(
            capturingBundleIDs: ["com.microsoft.teams2", "com.apple.VoiceMemos", nil],
            allowedPrefixes: teamsAndBrowsers)
        XCTAssertEqual(matches, ["com.microsoft.teams2"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MeetingCallActivityAllowlistTests 2>&1 | tail -20`
Expected: compile error — `incorrect argument labels` / no member `matchingBundleIDs`

- [ ] **Step 3: Add the allowlist API**

Append inside `public enum MeetingCallActivity` in `MeetingCallActivity.swift`:

```swift
    // MARK: - Allowlist detection (ADR-023 Phase 1.5)

    /// A call is active iff any capturing process's bundle ID starts with any
    /// allowlisted prefix. Empty allowlist → never a call (auto-stop stays
    /// disarmed; the Settings UI warns about this state).
    public static func isCall(capturingBundleIDs: [String?], allowedPrefixes: [String]) -> Bool {
        !matchingBundleIDs(capturingBundleIDs: capturingBundleIDs,
                           allowedPrefixes: allowedPrefixes).isEmpty
    }

    /// The capturing bundle IDs that match the allowlist — used by the monitor
    /// to log which app is keeping the detector armed.
    public static func matchingBundleIDs(
        capturingBundleIDs: [String?],
        allowedPrefixes: [String]
    ) -> [String] {
        capturingBundleIDs.compactMap { bundleID in
            guard let bundleID, !bundleID.isEmpty else { return nil }
            return allowedPrefixes.contains(where: { bundleID.hasPrefix($0) }) ? bundleID : nil
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MeetingCallActivityAllowlistTests 2>&1 | tail -20`
Expected: `Executed 7 tests, with 0 failures`

Also run the old tests still on the legacy API: `swift test --filter MeetingCallActivityTests 2>&1 | tail -10`
Expected: 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacParakeetCore/MeetingRecording/MeetingCallActivity.swift \
        Tests/MacParakeetTests/MeetingRecording/MeetingCallActivityTests.swift
git commit -m "feat(pdx): allowlist-based call detection API on MeetingCallActivity"
```

---

### Task 3: `meetingAutoStopCallApps` preference

**Files:**
- Modify: `Sources/MacParakeetCore/AppRuntimePreferences.swift` (protocol ~line 32, keys ~line 144, impl ~line 239)
- Test: `Tests/MacParakeetTests/MeetingRecording/MeetingCallAppTests.swift` (append)

- [ ] **Step 1: Write the failing tests**

Append to `MeetingCallAppTests.swift`:

```swift
final class MeetingAutoStopCallAppsPreferenceTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "macparakeet.test.config.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testReturnsPreSeededDefaultsWhenNeverEdited() {
        let prefs = UserDefaultsAppRuntimePreferences(defaults: defaults)
        XCTAssertEqual(prefs.meetingAutoStopCallApps, MeetingCallApp.defaults)
    }

    func testReturnsStoredListWhenEdited() throws {
        let custom = [MeetingCallApp(displayName: "Teams",
                                     bundleIDPrefixes: ["com.microsoft.teams2"])]
        defaults.set(try JSONEncoder().encode(custom),
                     forKey: UserDefaultsAppRuntimePreferences.meetingAutoStopCallAppsKey)
        let prefs = UserDefaultsAppRuntimePreferences(defaults: defaults)
        XCTAssertEqual(prefs.meetingAutoStopCallApps, custom)
    }

    func testEmptyStoredListStaysEmpty() throws {
        // Removing every app is a deliberate user choice — do not re-seed.
        defaults.set(try JSONEncoder().encode([MeetingCallApp]()),
                     forKey: UserDefaultsAppRuntimePreferences.meetingAutoStopCallAppsKey)
        let prefs = UserDefaultsAppRuntimePreferences(defaults: defaults)
        XCTAssertEqual(prefs.meetingAutoStopCallApps, [])
    }

    func testCorruptDataFallsBackToDefaults() {
        defaults.set(Data("not json".utf8),
                     forKey: UserDefaultsAppRuntimePreferences.meetingAutoStopCallAppsKey)
        let prefs = UserDefaultsAppRuntimePreferences(defaults: defaults)
        XCTAssertEqual(prefs.meetingAutoStopCallApps, MeetingCallApp.defaults)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MeetingAutoStopCallAppsPreferenceTests 2>&1 | tail -20`
Expected: compile error — no member `meetingAutoStopCallApps` / `meetingAutoStopCallAppsKey`

- [ ] **Step 3: Implement the preference**

In `AppRuntimePreferences.swift`:

(a) Add to `AppRuntimePreferencesProtocol` (after `var meetingAutoStopDelaySeconds: Int { get }`):

```swift
    /// Call apps the auto-stop detector watches (ADR-023 Phase 1.5).
    /// Pre-seeded defaults when the user has never edited the list.
    var meetingAutoStopCallApps: [MeetingCallApp] { get }
```

(b) Add key constant (after `meetingAutoStopDelaySecondsKey`):

```swift
    public static let meetingAutoStopCallAppsKey = "meetingAutoStopCallApps"
```

(c) Add implementation (after the `meetingAutoStopDelaySeconds` computed property):

```swift
    public var meetingAutoStopCallApps: [MeetingCallApp] {
        guard let data = defaults.data(forKey: Self.meetingAutoStopCallAppsKey),
              let apps = try? JSONDecoder().decode([MeetingCallApp].self, from: data) else {
            return MeetingCallApp.defaults
        }
        return apps
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MeetingAutoStopCallAppsPreferenceTests 2>&1 | tail -20`
Expected: `Executed 4 tests, with 0 failures`

Then build everything (the protocol gained a member — any other conformers must fail loudly now, not later):
`swift build 2>&1 | tail -5`
Expected: `Build complete!` — if another type conforms to `AppRuntimePreferencesProtocol` (e.g. a test mock), add the same property returning `MeetingCallApp.defaults`.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacParakeetCore/AppRuntimePreferences.swift \
        Tests/MacParakeetTests/MeetingRecording/MeetingCallAppTests.swift
git commit -m "feat(pdx): meetingAutoStopCallApps preference (JSON in UserDefaults, pre-seeded)"
```

---

### Task 4: Monitor allowlist + pause fix + logging; coordinator wiring

**Files:**
- Modify: `Sources/MacParakeet/App/MeetingCallActivityMonitor.swift` (whole file rewritten below)
- Modify: `Sources/MacParakeet/App/MeetingRecordingFlowCoordinator.swift:753-767` (`startCallActivityMonitorIfEnabled`)
- Test: Create `Tests/MacParakeetTests/MeetingRecording/MeetingCallActivityMonitorTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import MacParakeetCore
@testable import MacParakeet

/// Mutable state boxes — Swift 6 forbids capturing mutable locals in
/// escaping @MainActor closures; these classes are captured immutably.
@MainActor
private final class StubProbe {
    var capturing: [String?] = []
}

@MainActor
private final class StopSpy {
    var attempts = 0
    /// Scripted return values for successive onAutoStop calls.
    var results: [Bool] = []
    func record() -> Bool {
        attempts += 1
        return results.isEmpty ? true : results.removeFirst()
    }
}

@MainActor
final class MeetingCallActivityMonitorTests: XCTestCase {
    func testFiresOnceAfterAllowlistedAppReleasesMic() async throws {
        let probe = StubProbe()
        let spy = StopSpy()
        probe.capturing = ["com.microsoft.teams2"]
        let monitor = MeetingCallActivityMonitor(
            delaySeconds: 1,
            allowedPrefixes: ["com.microsoft.teams2"],
            pollInterval: 0.05,
            capturingBundleIDs: { probe.capturing },
            onAutoStop: { spy.record() }
        )
        monitor.start()
        try await Task.sleep(for: .seconds(0.3))    // a few polls — arms
        probe.capturing = []                         // Teams releases the mic
        try await Task.sleep(for: .seconds(1.6))    // > 1s delay + poll slack
        XCTAssertEqual(spy.attempts, 1)
        monitor.stop()
    }

    func testNonAllowlistedAppNeverArms() async throws {
        let probe = StubProbe()
        let spy = StopSpy()
        probe.capturing = ["com.apple.VoiceMemos"]   // not allowlisted
        let monitor = MeetingCallActivityMonitor(
            delaySeconds: 1,
            allowedPrefixes: ["com.microsoft.teams2"],
            pollInterval: 0.05,
            capturingBundleIDs: { probe.capturing },
            onAutoStop: { spy.record() }
        )
        monitor.start()
        try await Task.sleep(for: .seconds(0.3))
        probe.capturing = []                          // releases — must NOT fire
        try await Task.sleep(for: .seconds(1.6))
        XCTAssertEqual(spy.attempts, 0)
        monitor.stop()
    }

    func testDroppedStopResetsDetectorSoItCanFireAgain() async throws {
        // Regression: pause during call-end used to permanently kill auto-stop.
        let probe = StubProbe()
        let spy = StopSpy()
        spy.results = [false, true]   // 1st delivery dropped (paused), 2nd lands
        probe.capturing = ["us.zoom.xos"]
        let monitor = MeetingCallActivityMonitor(
            delaySeconds: 1,
            allowedPrefixes: ["us.zoom.xos"],
            pollInterval: 0.05,
            capturingBundleIDs: { probe.capturing },
            onAutoStop: { spy.record() }
        )
        monitor.start()
        try await Task.sleep(for: .seconds(0.3))    // arm
        probe.capturing = []                         // release → fire #1 (dropped)
        try await Task.sleep(for: .seconds(1.6))
        XCTAssertEqual(spy.attempts, 1)
        probe.capturing = ["us.zoom.xos"]            // call returns → re-arm
        try await Task.sleep(for: .seconds(0.3))
        probe.capturing = []                         // release → fire #2 (delivered)
        try await Task.sleep(for: .seconds(1.6))
        XCTAssertEqual(spy.attempts, 2)
        monitor.stop()
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MeetingCallActivityMonitorTests 2>&1 | tail -20`
Expected: compile error — `extra argument 'allowedPrefixes'` / closure type mismatch (`Bool` vs `Void`)

- [ ] **Step 3: Rewrite the monitor**

Replace the entire contents of `MeetingCallActivityMonitor.swift`:

```swift
import Foundation
import MacParakeetCore
import OSLog

/// Polls mic-capturing processes while a meeting recording is active and, when the
/// recorded call ends (every allowlisted call app has released the mic for the
/// configured delay), invokes `onAutoStop`. Only created/started when the meeting
/// auto-stop toggle is on. ADR-023 Phase 1.5: detection is allowlist-based —
/// only the user's configured call apps arm or release the detector.
@MainActor
final class MeetingCallActivityMonitor {
    private var task: Task<Void, Never>?
    private var detector: MeetingAutoStopDetector
    private let delaySeconds: Int
    private let pollInterval: TimeInterval
    private let allowedPrefixes: [String]
    private let capturingBundleIDs: @MainActor () -> [String?]
    /// Returns `true` when the stop was actually delivered. `false` (e.g. the
    /// recording is paused) resets the detector so auto-stop can re-arm later
    /// instead of dying for the rest of the recording.
    private let onAutoStop: @MainActor () -> Bool
    private let logger = Logger(subsystem: "com.macparakeet", category: "MeetingAutoStop")

    init(
        delaySeconds: Int,
        allowedPrefixes: [String],
        pollInterval: TimeInterval = 1.5,
        capturingBundleIDs: @escaping @MainActor () -> [String?] = { MicInputProbe.capturingInputBundleIDs() },
        onAutoStop: @escaping @MainActor () -> Bool
    ) {
        self.detector = MeetingAutoStopDetector(delaySeconds: TimeInterval(delaySeconds))
        self.delaySeconds = delaySeconds
        self.pollInterval = pollInterval
        self.allowedPrefixes = allowedPrefixes
        self.capturingBundleIDs = capturingBundleIDs
        self.onAutoStop = onAutoStop
    }

    func start() {
        task?.cancel()
        logger.info("Monitor started — delay=\(self.delaySeconds)s allowlist=[\(self.allowedPrefixes.joined(separator: ", "), privacy: .public)]")
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            var wasActive = false
            while !Task.isCancelled {
                let matching = MeetingCallActivity.matchingBundleIDs(
                    capturingBundleIDs: self.capturingBundleIDs(),
                    allowedPrefixes: self.allowedPrefixes
                )
                let active = !matching.isEmpty
                if active != wasActive {
                    if active {
                        self.logger.info("Call detected — \(matching.joined(separator: ", "), privacy: .public)")
                    } else {
                        self.logger.info("All call apps released the mic — auto-stop in \(self.delaySeconds)s unless one returns")
                    }
                    wasActive = active
                }
                if self.detector.sample(isCallActive: active, now: Date()) == .autoStop {
                    if self.onAutoStop() {
                        self.logger.info("Auto-stop delivered")
                        break   // fire once; coordinator tears the monitor down
                    }
                    // Dropped (recording paused / already stopping). Reset so a
                    // future call can re-arm instead of leaving auto-stop dead.
                    self.logger.info("Auto-stop dropped (recording not active) — detector reset")
                    self.detector = MeetingAutoStopDetector(delaySeconds: TimeInterval(self.delaySeconds))
                    wasActive = false
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

- [ ] **Step 4: Update the coordinator wiring**

In `MeetingRecordingFlowCoordinator.swift`, replace `startCallActivityMonitorIfEnabled()` (currently lines 753-767):

```swift
    private func startCallActivityMonitorIfEnabled() {
        let prefs = UserDefaultsAppRuntimePreferences(defaults: .standard)
        guard prefs.meetingAutoStopEnabled else { return }
        callActivityMonitor?.stop()
        let monitor = MeetingCallActivityMonitor(
            delaySeconds: prefs.meetingAutoStopDelaySeconds,
            allowedPrefixes: prefs.meetingAutoStopCallApps.flatMap(\.bundleIDPrefixes),
            onAutoStop: { [weak self] in
                guard let self else { return false }
                guard self.stateMachine.state == .recording else { return false }
                self.sendEvent(.stopRequested)
                return true
            }
        )
        callActivityMonitor = monitor
        monitor.start()
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter MeetingCallActivityMonitorTests 2>&1 | tail -20`
Expected: `Executed 3 tests, with 0 failures`

Then: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 6: Commit**

```bash
git add Sources/MacParakeet/App/MeetingCallActivityMonitor.swift \
        Sources/MacParakeet/App/MeetingRecordingFlowCoordinator.swift \
        Tests/MacParakeetTests/MeetingRecording/MeetingCallActivityMonitorTests.swift
git commit -m "feat(pdx): allowlist-driven auto-stop monitor — pause-reset fix + os_log diagnostics"
```

---

### Task 5: Remove legacy any-app detection; update CLI labeling

**Files:**
- Modify: `Sources/MacParakeetCore/MeetingRecording/MeetingCallActivity.swift`
- Modify: `Sources/CLI/Commands/MicProcessesCommand.swift`
- Modify: `Tests/MacParakeetTests/MeetingRecording/MeetingCallActivityTests.swift` (delete legacy test class)

- [ ] **Step 1: Remove the legacy API and rename the exclusion lists**

In `MeetingCallActivity.swift`:
- Delete the old `isCall(capturingBundleIDs:)` function (no `allowedPrefixes` parameter).
- Rename `excludedBundleIDs` → `pickerHiddenBundleIDs` and `excludedPrefixes` → `pickerHiddenPrefixes`.
- Update the type's doc comment. The full file after this task:

```swift
import Foundation

/// Allowlist-based call detection for meeting auto-stop (ADR-023 Phase 1.5).
/// A call is "active" iff a mic-capturing process matches the user's call-app
/// allowlist (`MeetingCallApp`). The picker-hidden lists below are NOT part of
/// detection — they only hide MacParakeet's own capture and system daemons
/// from the Settings "apps using the mic" picker.
public enum MeetingCallActivity {
    /// Hidden from the Settings mic picker: system daemons that hold the mic
    /// but never represent a user call (`avconferenced` holds it persistently
    /// on some Macs — ADR-023 Phase 0 spike).
    public static let pickerHiddenBundleIDs: Set<String> = ["com.apple.avconferenced"]
    /// Hidden from the Settings mic picker: MacParakeet's own capture
    /// (any edition — pdx / dev / stable bundle IDs share this prefix).
    public static let pickerHiddenPrefixes: [String] = ["com.macparakeet"]

    // MARK: - Allowlist detection (ADR-023 Phase 1.5)

    /// A call is active iff any capturing process's bundle ID starts with any
    /// allowlisted prefix. Empty allowlist → never a call (auto-stop stays
    /// disarmed; the Settings UI warns about this state).
    public static func isCall(capturingBundleIDs: [String?], allowedPrefixes: [String]) -> Bool {
        !matchingBundleIDs(capturingBundleIDs: capturingBundleIDs,
                           allowedPrefixes: allowedPrefixes).isEmpty
    }

    /// The capturing bundle IDs that match the allowlist — used by the monitor
    /// to log which app is keeping the detector armed.
    public static func matchingBundleIDs(
        capturingBundleIDs: [String?],
        allowedPrefixes: [String]
    ) -> [String] {
        capturingBundleIDs.compactMap { bundleID in
            guard let bundleID, !bundleID.isEmpty else { return nil }
            return allowedPrefixes.contains(where: { bundleID.hasPrefix($0) }) ? bundleID : nil
        }
    }
}
```

- [ ] **Step 2: Delete the legacy test class**

In `MeetingCallActivityTests.swift`, delete the entire `final class MeetingCallActivityTests: XCTestCase { ... }` class (it tests the removed denylist API). Keep `MeetingCallActivityAllowlistTests`.

- [ ] **Step 3: Update the CLI command**

In `MicProcessesCommand.swift`, replace `printSnapshot()`:

```swift
    private func printSnapshot() {
        let ids = MicInputProbe.capturingInputBundleIDs()
        let stamp = MicProcessesCommand.timeFormatter.string(from: Date())
        if ids.isEmpty {
            print("[\(stamp)] (no process is capturing mic input)")
            return
        }
        // Label against the pre-seeded call-app defaults. The app's live
        // allowlist lives in the GUI app's defaults domain, which this CLI
        // process can't read — defaults are close enough for a dev probe.
        let defaultPrefixes = MeetingCallApp.defaults.flatMap(\.bundleIDPrefixes)
        print("[\(stamp)] capturing mic input:")
        for id in ids.map({ $0 ?? "(unknown)" }).sorted() {
            let tag: String
            if MeetingCallActivity.pickerHiddenPrefixes.contains(where: { id.hasPrefix($0) }) {
                tag = "  <- MacParakeet (never counts as a call)"
            } else if MeetingCallActivity.pickerHiddenBundleIDs.contains(id) {
                tag = "  <- system daemon (never counts as a call)"
            } else if defaultPrefixes.contains(where: { id.hasPrefix($0) }) {
                tag = "  <- call app (in default allowlist)"
            } else {
                tag = "  <- not allowlisted (won't arm auto-stop unless added in Settings)"
            }
            print("    bundle=\(id)\(tag)")
        }
    }
```

- [ ] **Step 4: Build + run all affected tests**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!` — if anything else still references the old `isCall(capturingBundleIDs:)` or `excluded*` names, the compiler lists it; update those callsites the same way.

Run: `swift test --filter "MeetingCallActivity|MeetingCallApp|MeetingCallActivityMonitor|MeetingAutoStop" 2>&1 | tail -10`
Expected: 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacParakeetCore/MeetingRecording/MeetingCallActivity.swift \
        Sources/CLI/Commands/MicProcessesCommand.swift \
        Tests/MacParakeetTests/MeetingRecording/MeetingCallActivityTests.swift
git commit -m "refactor(pdx): retire any-app call detection; mic-processes labels allowlist status"
```

---

### Task 6: SettingsViewModel — call-app list management + mic picker polling

**Files:**
- Modify: `Sources/MacParakeetViewModels/SettingsViewModel.swift`
- Test: Create `Tests/MacParakeetTests/ViewModels/SettingsViewModelCallAppsTests.swift`

**Check first:** look at how existing `SettingsViewModel` tests construct the view model (`grep -rn "SettingsViewModel(" Tests/`) and reuse that setup pattern. The steps below assume `SettingsViewModel(defaults:)` works with a throwaway suite.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class SettingsViewModelCallAppsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "macparakeet.test.config.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testLoadsPreSeededDefaultsOnFirstRun() {
        let vm = SettingsViewModel(defaults: defaults)
        XCTAssertEqual(vm.meetingCallApps, MeetingCallApp.defaults)
    }

    func testAddCallAppPersists() throws {
        let vm = SettingsViewModel(defaults: defaults)
        vm.addCallApp(bundleID: "com.cisco.webexmeetingsapp", displayName: "Webex")

        // Reload from a fresh prefs reader — the add must have been persisted.
        let prefs = UserDefaultsAppRuntimePreferences(defaults: defaults)
        XCTAssertTrue(prefs.meetingAutoStopCallApps.contains(
            MeetingCallApp(displayName: "Webex",
                           bundleIDPrefixes: ["com.cisco.webexmeetingsapp"])))
    }

    func testAddDuplicateBundleIDIsIgnored() {
        let vm = SettingsViewModel(defaults: defaults)
        let before = vm.meetingCallApps.count
        vm.addCallApp(bundleID: "com.microsoft.teams2", displayName: "Teams Again")
        XCTAssertEqual(vm.meetingCallApps.count, before)
    }

    func testRemoveCallAppPersists() {
        let vm = SettingsViewModel(defaults: defaults)
        let safari = vm.meetingCallApps.first { $0.displayName == "Safari" }!
        vm.removeCallApp(safari)

        let prefs = UserDefaultsAppRuntimePreferences(defaults: defaults)
        XCTAssertFalse(prefs.meetingAutoStopCallApps.contains { $0.displayName == "Safari" })
    }

    func testMicCandidatesHideMacParakeetDaemonsAndAlreadyAddedApps() {
        let vm = SettingsViewModel(
            defaults: defaults,
            capturingBundleIDsProvider: {
                ["com.macparakeet.pdx",          // self — hidden
                 "com.apple.avconferenced",      // daemon — hidden
                 "com.microsoft.teams2",         // already in defaults — hidden
                 "com.cisco.webexmeetingsapp",   // genuinely new — shown
                 nil]
            },
            callAppDisplayNameResolver: { _ in "Webex" }
        )
        vm.refreshMicCandidatesNow()
        XCTAssertEqual(vm.micCaptureCandidates.map(\.bundleID), ["com.cisco.webexmeetingsapp"])
        XCTAssertEqual(vm.micCaptureCandidates.first?.displayName, "Webex")
    }

    func testMicCandidateFallsBackToBundleIDWhenNameUnknown() {
        let vm = SettingsViewModel(
            defaults: defaults,
            capturingBundleIDsProvider: { ["org.example.unknownapp"] },
            callAppDisplayNameResolver: { _ in nil }
        )
        vm.refreshMicCandidatesNow()
        XCTAssertEqual(vm.micCaptureCandidates.first?.displayName, "org.example.unknownapp")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SettingsViewModelCallAppsTests 2>&1 | tail -20`
Expected: compile errors — no `meetingCallApps`, no `capturingBundleIDsProvider:` parameter, etc.

- [ ] **Step 3: Implement in SettingsViewModel**

(a) Add two init parameters (alongside the existing injected providers, around line 530; both must have defaults so existing callsites compile):

```swift
        capturingBundleIDsProvider: @escaping @MainActor () -> [String?] = {
            MicInputProbe.capturingInputBundleIDs()
        },
        callAppDisplayNameResolver: @escaping @MainActor (String) -> String? = { bundleID in
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first?.localizedName
        },
```

Store them in matching private properties:

```swift
    private let capturingBundleIDsProvider: @MainActor () -> [String?]
    private let callAppDisplayNameResolver: @MainActor (String) -> String?
```

…and assign them in the init body (`self.capturingBundleIDsProvider = capturingBundleIDsProvider`, etc.).

(b) Add the published list (next to `meetingAutoStopDelaySeconds`, ~line 158):

```swift
    /// Call apps the auto-stop detector watches (ADR-023 Phase 1.5).
    public var meetingCallApps: [MeetingCallApp] {
        didSet {
            guard let data = try? JSONEncoder().encode(meetingCallApps) else { return }
            defaults.set(data, forKey: UserDefaultsAppRuntimePreferences.meetingAutoStopCallAppsKey)
        }
    }
```

(c) Load it in the init body (next to the `meetingAutoStopDelaySeconds` load, ~line 582):

```swift
        if let data = defaults.data(forKey: UserDefaultsAppRuntimePreferences.meetingAutoStopCallAppsKey),
           let apps = try? JSONDecoder().decode([MeetingCallApp].self, from: data) {
            meetingCallApps = apps
        } else {
            meetingCallApps = MeetingCallApp.defaults
        }
```

(d) Add the mic-picker section (new `// MARK: - Meeting auto-stop call apps` near the other meeting settings code):

```swift
    /// One row in the "apps using the mic right now" picker.
    public struct MicCaptureCandidate: Equatable, Identifiable, Sendable {
        public let bundleID: String
        public let displayName: String
        public var id: String { bundleID }
    }

    public private(set) var micCaptureCandidates: [MicCaptureCandidate] = []
    private var micCandidatePollingTask: Task<Void, Never>?

    public func addCallApp(bundleID: String, displayName: String) {
        // Ignore exact duplicates and anything already covered by a prefix.
        guard !meetingCallApps.contains(where: { app in
            app.bundleIDPrefixes.contains(where: { bundleID.hasPrefix($0) })
        }) else { return }
        meetingCallApps.append(MeetingCallApp(displayName: displayName,
                                              bundleIDPrefixes: [bundleID]))
    }

    public func removeCallApp(_ app: MeetingCallApp) {
        meetingCallApps.removeAll { $0 == app }
    }

    /// Begin polling for mic-capturing apps (used while the "Add app" picker
    /// is open). Stop with `stopMicCandidatePolling()`.
    public func startMicCandidatePolling() {
        stopMicCandidatePolling()
        refreshMicCandidatesNow()
        micCandidatePollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                self?.refreshMicCandidatesNow()
            }
        }
    }

    public func stopMicCandidatePolling() {
        micCandidatePollingTask?.cancel()
        micCandidatePollingTask = nil
        micCaptureCandidates = []
    }

    /// Single synchronous refresh — exposed (not private) so tests can drive
    /// it without timing dependencies.
    public func refreshMicCandidatesNow() {
        let alreadyCovered = meetingCallApps.flatMap(\.bundleIDPrefixes)
        var seen = Set<String>()
        micCaptureCandidates = capturingBundleIDsProvider()
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .filter { id in !MeetingCallActivity.pickerHiddenPrefixes.contains(where: { id.hasPrefix($0) }) }
            .filter { id in !MeetingCallActivity.pickerHiddenBundleIDs.contains(id) }
            .filter { id in !alreadyCovered.contains(where: { id.hasPrefix($0) }) }
            .filter { seen.insert($0).inserted }
            .map { id in
                MicCaptureCandidate(bundleID: id,
                                    displayName: callAppDisplayNameResolver(id) ?? id)
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SettingsViewModelCallAppsTests 2>&1 | tail -20`
Expected: `Executed 6 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/MacParakeetViewModels/SettingsViewModel.swift \
        Tests/MacParakeetTests/ViewModels/SettingsViewModelCallAppsTests.swift
git commit -m "feat(pdx): SettingsViewModel call-app list management + live mic-app picker"
```

---

### Task 7: SettingsView — call apps UI

No unit test (SwiftUI views are not tested per `spec/09-testing.md`; the ViewModel behind every control is covered by Task 6).

**Files:**
- Modify: `Sources/MacParakeet/Views/Settings/SettingsView.swift` (auto-stop block at ~line 897-916; helpers near `rowText` ~line 2290)

- [ ] **Step 1: Add UI state**

Add next to SettingsView's other `@State` properties:

```swift
    @State private var isAddingCallApp = false
```

- [ ] **Step 2: Insert the call-apps section**

Inside the existing `if viewModel.meetingAutoStopEnabled { ... }` block (after the "Auto-stop delay" `HStack`, before its closing brace at ~line 916), add:

```swift
                    Divider()
                    meetingCallAppsSection
```

- [ ] **Step 3: Add the section views**

Add these computed properties near the other meeting-section helpers (match the file's existing organization; use the same spacing tokens used by neighboring sections — `DesignSystem.Spacing.md` etc.):

```swift
    /// ADR-023 Phase 1.5: the call apps auto-stop watches. Only these apps
    /// arm the detector; recording stops when they all release the mic.
    private var meetingCallAppsSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(alignment: .center) {
                rowText(
                    title: "Call apps",
                    detail: "Auto-stop only watches these apps. Recording stops when they all release the microphone."
                )
                Spacer(minLength: DesignSystem.Spacing.md)
                Button(isAddingCallApp ? "Done" : "Add app…") {
                    isAddingCallApp.toggle()
                    if isAddingCallApp {
                        viewModel.startMicCandidatePolling()
                    } else {
                        viewModel.stopMicCandidatePolling()
                    }
                }
                .parakeetAction(.secondary)
            }

            if viewModel.meetingCallApps.isEmpty {
                Text("Auto-stop needs at least one call app to watch — it will never trigger with an empty list.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.orange)
            }

            ForEach(viewModel.meetingCallApps) { app in
                HStack(spacing: DesignSystem.Spacing.md) {
                    Text(app.displayName)
                        .font(DesignSystem.Typography.body)
                    Text(app.bundleIDPrefixes.joined(separator: ", "))
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        viewModel.removeCallApp(app)
                    } label: {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(app.displayName)")
                }
            }

            if isAddingCallApp {
                callAppPicker
            }
        }
        .onDisappear {
            isAddingCallApp = false
            viewModel.stopMicCandidatePolling()
        }
    }

    /// Live "apps using the mic right now" picker (polls MicInputProbe via the
    /// view model while visible).
    private var callAppPicker: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            if viewModel.micCaptureCandidates.isEmpty {
                Text("No apps are using the microphone right now. Join a call, then add it from here.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.micCaptureCandidates) { candidate in
                    HStack(spacing: DesignSystem.Spacing.md) {
                        Text(candidate.displayName)
                            .font(DesignSystem.Typography.body)
                        Text(candidate.bundleID)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Add") {
                            viewModel.addCallApp(bundleID: candidate.bundleID,
                                                 displayName: candidate.displayName)
                        }
                        .parakeetAction(.secondary)
                    }
                }
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.06))
        )
    }
```

- [ ] **Step 4: Build and launch the dev app for a visual check**

Run: `swift build 2>&1 | tail -5` → Expected: `Build complete!`

Then: `scripts/dev/run_app.sh`, open Settings → Meeting Recording card:
- Toggle "Auto-stop recording when the call ends" ON → the Call apps list appears with the 6 pre-seeds.
- Click "Add app…" → picker shows the empty-state line (nothing is using the mic).
- Remove Safari → it disappears; relaunch the app → Safari stays removed (persistence).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacParakeet/Views/Settings/SettingsView.swift
git commit -m "feat(pdx): Settings call-apps list + live mic-app picker for auto-stop"
```

---

### Task 8: Docs, full suite, and real-world verification

**Files:**
- Modify: `spec/adr/023-activity-based-meeting-auto-stop.md`
- Modify: `plans/active/2026-06-meeting-auto-stop-call-app-allowlist.md` (status header)
- Move: both plan docs → `plans/completed/` (after verification passes)

- [ ] **Step 1: Amend ADR-023**

In `spec/adr/023-activity-based-meeting-auto-stop.md`:

(a) Replace the `> Status:` line with:

```markdown
> Status: **ACCEPTED** — Phase 0 (spike) done 2026-06-01; Phase 1 implemented (hard auto-stop, opt-in, default off); Phase 1.5 implemented 2026-06: detection is now allowlist-based (`MeetingCallApp`) — only user-configured call apps (pre-seeded: Teams, Zoom, FaceTime, Slack, Safari, Chrome) arm or release the detector. Phase 2 (VAD corroboration / soft-confirm) remains proposed.
```

(b) Append this section at the end of the file:

```markdown
## Amendment: Phase 1.5 — Call-App Allowlist (2026-06)

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
- Accepted trade-off: with browsers allowlisted, any mic-using tab counts as a
  call. Scoped 2026-06-02: a false trigger requires recording + no real call +
  a tab acquiring then releasing the mic.

See `plans/completed/2026-06-meeting-auto-stop-call-app-allowlist.md` for the
full design.
```

- [ ] **Step 2: Run the full test suite**

Run: `swift test 2>&1 | tail -10`
Expected: all tests pass. Fix any regression before continuing.

- [ ] **Step 3: Real-world verification (requires the owner)**

1. Build + install the PDX app: `VERSION=0.8.8-pdx scripts/dev/build_and_package_pdx.sh`
2. In the app: Settings → enable "Auto-stop recording when the call ends".
3. In a terminal: `./.build/release/macparakeet-cli mic-processes --watch`
4. **Safari check:** open https://webcammictest.com/check-mic.html in Safari, allow the mic, and note the bundle ID that appears in the watch output. It must match a Safari prefix (`com.apple.Safari` or `com.apple.WebKit`). If it reports something else, add that prefix to `MeetingCallApp.defaults` and re-run Task 1's tests.
5. **Chrome check:** same with Chrome — bundle ID must match `com.google.Chrome`.
6. **End-to-end:** start a meeting recording, join a Teams meeting (or a test call), then End Call. Within the configured delay (+ ~1.5s poll), the recording must stop and save. Check the log stream:
   `log stream --predicate 'subsystem == "com.macparakeet" AND category == "MeetingAutoStop"' --style compact`
   Expected lines: `Monitor started`, `Call detected — com.microsoft.teams2`, `All call apps released the mic`, `Auto-stop delivered`.

- [ ] **Step 4: Update plan statuses and archive**

- Change the spec doc header to `> Status: **IMPLEMENTED** — 2026-06-XX`.
- `git mv plans/active/2026-06-meeting-auto-stop-call-app-allowlist.md plans/completed/`
- `git mv plans/active/2026-06-meeting-auto-stop-call-app-allowlist-implementation.md plans/completed/`

- [ ] **Step 5: Final commit**

```bash
git add spec/adr/023-activity-based-meeting-auto-stop.md plans/
git commit -m "docs(pdx): ADR-023 Phase 1.5 amendment — call-app allowlist; archive plans"
```

---

## Self-Review Notes

- **Spec coverage:** model/pre-seeds (Task 1), prefix detection + empty-list rule (Task 2), prefs (Task 3), monitor snapshot + pause fix + logging + coordinator (Task 4), exclusion-list repurposing + CLI labels (Task 5), ViewModel + picker hiding rules (Task 6), Settings UI incl. empty-state warning (Task 7), ADR amendment + browser bundle-ID verification (Task 8). The spec's "Add sheet" is implemented as an inline expanding picker — same behavior (live MicInputProbe polling, click-to-add), less plumbing in the 2,300-line SettingsView.
- **Known check-before-coding items:** (1) other conformers of `AppRuntimePreferencesProtocol` (Task 3 Step 4 catches via build); (2) exact `SettingsViewModel` test construction pattern (Task 6 preamble).
- **Type consistency:** `MeetingCallApp(displayName:bundleIDPrefixes:)`, `isCall(capturingBundleIDs:allowedPrefixes:)`, `matchingBundleIDs(capturingBundleIDs:allowedPrefixes:)`, `pickerHiddenBundleIDs`/`pickerHiddenPrefixes`, `onAutoStop: () -> Bool` used consistently across Tasks 2, 4, 5, 6.
