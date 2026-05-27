# PDX Signing Identity + Launch Permission Health Check — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix PDX Edition upgrade UX by giving each build a stable code-signing identity (so TCC carries permissions across installs) and adding a launch-time check that alerts when permissions were revoked.

**Architecture:** Part 1 — a one-time `create_pdx_cert.sh` script creates a self-signed cert in the login keychain; all future PDX builds sign with `--sign "MacParakeet PDX"` instead of `--sign -`. Part 2 — a pure `LaunchPermissionChecker` struct computes a permission bitmask, compares it to the last-stored value in UserDefaults, and returns the list of newly-missing permissions; `OnboardingCoordinator` calls it on every post-onboarding launch and shows an `NSAlert` for each missing permission with a direct link to System Settings.

**Tech Stack:** Swift 6.0, AppKit (NSAlert, NSApp, NSWorkspace), macOS Security framework (openssl + `security import`), UserDefaults, XCTest.

---

## File Map

| Action | Path | Responsibility |
|--------|------|----------------|
| Modify | `Sources/MacParakeetCore/Services/PermissionService.swift` | Add `openAccessibilitySettings()` to protocol + impl |
| Modify | `Tests/MacParakeetTests/ViewModels/ViewModelMocks.swift` | Add `openAccessibilitySettings()` to `MockPermissionService` |
| Create | `Sources/MacParakeetCore/Services/LaunchPermissionChecker.swift` | Pure bitmask logic — no UI, no AppKit |
| Create | `Tests/MacParakeetTests/Services/LaunchPermissionCheckerTests.swift` | Unit tests for all fingerprint scenarios |
| Modify | `Sources/MacParakeet/App/OnboardingCoordinator.swift` | Add `else` branch in `maybeShow` + `NSAlert` presentation |
| Create | `scripts/dev/create_pdx_cert.sh` | One-time self-signed cert setup for build machine |
| Modify | `docs/pdx-edition.md` | Update signing steps to use `"MacParakeet PDX"` |
| Modify | `CLAUDE.md` | Same update in "Cut a new release" section |

---

## Task 1: Add `openAccessibilitySettings()` to `PermissionService`

**Files:**
- Modify: `Sources/MacParakeetCore/Services/PermissionService.swift`
- Modify: `Tests/MacParakeetTests/ViewModels/ViewModelMocks.swift`

- [ ] **Step 1: Add the method to the protocol**

In `Sources/MacParakeetCore/Services/PermissionService.swift`, add one line to `PermissionServiceProtocol` after `openScreenRecordingSettings()`:

```swift
public protocol PermissionServiceProtocol: Sendable {
    func checkMicrophonePermission() async -> PermissionStatus
    func requestMicrophonePermission() async -> Bool
    func checkScreenRecordingPermission() -> Bool
    func requestScreenRecordingPermission() -> Bool
    func openMicrophoneSettings()
    func openScreenRecordingSettings()
    func openAccessibilitySettings()           // ← add this
    func checkAccessibilityPermission() -> Bool
    func requestAccessibilityPermission(prompt: Bool) -> Bool
}
```

- [ ] **Step 2: Add the implementation**

In the same file, add after `openScreenRecordingSettings()`:

```swift
public func openAccessibilitySettings() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
    NSWorkspace.shared.open(url)
}
```

- [ ] **Step 3: Add stub to `MockPermissionService`**

In `Tests/MacParakeetTests/ViewModels/ViewModelMocks.swift`, find `MockPermissionService` (around line 832) and add after `openScreenRecordingSettings() {}`:

```swift
func openAccessibilitySettings() {}
```

- [ ] **Step 4: Build to verify no compile errors**

```bash
swift build --target MacParakeet 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build of target: 'MacParakeet' complete!`

- [ ] **Step 5: Commit**

```bash
git add Sources/MacParakeetCore/Services/PermissionService.swift \
        Tests/MacParakeetTests/ViewModels/ViewModelMocks.swift
git commit -m "feat(permissions): add openAccessibilitySettings() to PermissionService"
```

---

## Task 2: `LaunchPermissionChecker` — pure logic + tests

**Files:**
- Create: `Sources/MacParakeetCore/Services/LaunchPermissionChecker.swift`
- Create: `Tests/MacParakeetTests/Services/LaunchPermissionCheckerTests.swift`

- [ ] **Step 1: Write the failing tests first**

Create `Tests/MacParakeetTests/Services/LaunchPermissionCheckerTests.swift`:

```swift
import XCTest
@testable import MacParakeetCore

final class LaunchPermissionCheckerTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "LaunchPermissionCheckerTests.\(UUID())")!
    }

    override func tearDown() {
        defaults.removeSuite(named: defaults.suiteName ?? "")
        super.tearDown()
    }

    // MARK: - No stored fingerprint (first post-onboarding launch)

    func testNoFingerprint_allGranted_noAlert() {
        let missing = LaunchPermissionChecker.check(
            micGranted: true,
            accessibilityGranted: true,
            screenRecordingGranted: true,
            meetingRecordingEnabled: true,
            defaults: defaults
        )
        XCTAssertEqual(missing, [])
    }

    func testNoFingerprint_micMissing_alertsFired() {
        let missing = LaunchPermissionChecker.check(
            micGranted: false,
            accessibilityGranted: true,
            screenRecordingGranted: true,
            meetingRecordingEnabled: true,
            defaults: defaults
        )
        XCTAssertEqual(missing, [.microphone])
    }

    func testNoFingerprint_allMissing_alertsAll() {
        let missing = LaunchPermissionChecker.check(
            micGranted: false,
            accessibilityGranted: false,
            screenRecordingGranted: false,
            meetingRecordingEnabled: true,
            defaults: defaults
        )
        XCTAssertEqual(missing, [.microphone, .accessibility, .screenRecording])
    }

    func testNoFingerprint_screenRecordingMissing_meetingDisabled_noAlert() {
        let missing = LaunchPermissionChecker.check(
            micGranted: true,
            accessibilityGranted: true,
            screenRecordingGranted: false,
            meetingRecordingEnabled: false,
            defaults: defaults
        )
        XCTAssertEqual(missing, [])
    }

    // MARK: - Stored fingerprint — revocation detection

    func testRevocation_micRevoked_alertsFired() {
        // Stored: mic + ax granted
        LaunchPermissionChecker.saveFingerprint(
            micGranted: true,
            accessibilityGranted: true,
            screenRecordingGranted: false,
            meetingRecordingEnabled: false,
            defaults: defaults
        )
        // Current: mic gone
        let missing = LaunchPermissionChecker.check(
            micGranted: false,
            accessibilityGranted: true,
            screenRecordingGranted: false,
            meetingRecordingEnabled: false,
            defaults: defaults
        )
        XCTAssertEqual(missing, [.microphone])
    }

    func testNoRevocation_samePermissions_noAlert() {
        LaunchPermissionChecker.saveFingerprint(
            micGranted: true,
            accessibilityGranted: true,
            screenRecordingGranted: false,
            meetingRecordingEnabled: false,
            defaults: defaults
        )
        let missing = LaunchPermissionChecker.check(
            micGranted: true,
            accessibilityGranted: true,
            screenRecordingGranted: false,
            meetingRecordingEnabled: false,
            defaults: defaults
        )
        XCTAssertEqual(missing, [])
    }

    func testPermissionGained_noAlert() {
        // Stored: only mic
        LaunchPermissionChecker.saveFingerprint(
            micGranted: true,
            accessibilityGranted: false,
            screenRecordingGranted: false,
            meetingRecordingEnabled: false,
            defaults: defaults
        )
        // Current: mic + ax (gained accessibility)
        let missing = LaunchPermissionChecker.check(
            micGranted: true,
            accessibilityGranted: true,
            screenRecordingGranted: false,
            meetingRecordingEnabled: false,
            defaults: defaults
        )
        XCTAssertEqual(missing, [])
    }

    func testAllRevoked_alertsAll() {
        LaunchPermissionChecker.saveFingerprint(
            micGranted: true,
            accessibilityGranted: true,
            screenRecordingGranted: true,
            meetingRecordingEnabled: true,
            defaults: defaults
        )
        let missing = LaunchPermissionChecker.check(
            micGranted: false,
            accessibilityGranted: false,
            screenRecordingGranted: false,
            meetingRecordingEnabled: true,
            defaults: defaults
        )
        XCTAssertEqual(missing, [.microphone, .accessibility, .screenRecording])
    }

    // MARK: - saveFingerprint persists correctly

    func testSaveFingerprint_persistsToDefaults() {
        LaunchPermissionChecker.saveFingerprint(
            micGranted: true,
            accessibilityGranted: false,
            screenRecordingGranted: true,
            meetingRecordingEnabled: true,
            defaults: defaults
        )
        let stored = defaults.integer(forKey: LaunchPermissionChecker.fingerprintKey)
        // bit 0 (mic) + bit 2 (screen) = 0b101 = 5
        XCTAssertEqual(stored, 5)
    }
}
```

- [ ] **Step 2: Run tests — they must fail with "module not found"**

```bash
swift test --filter LaunchPermissionCheckerTests 2>&1 | grep -E "error:|FAILED|passed"
```

Expected: compile error — `LaunchPermissionChecker` doesn't exist yet.

- [ ] **Step 3: Create the implementation**

Create `Sources/MacParakeetCore/Services/LaunchPermissionChecker.swift`:

```swift
import Foundation

public enum MissingPermission: Equatable, Sendable, CaseIterable {
    case microphone
    case accessibility
    case screenRecording
}

public struct LaunchPermissionChecker: Sendable {
    public static let fingerprintKey = "pdx.permissionFingerprint"

    /// Returns the list of permissions that are missing and should be alerted.
    /// Empty return means no alert needed.
    /// Fires when: no fingerprint stored yet (first post-onboarding launch) AND
    /// some permissions are missing, OR when the fingerprint shrank (revocation).
    public static func check(
        micGranted: Bool,
        accessibilityGranted: Bool,
        screenRecordingGranted: Bool,
        meetingRecordingEnabled: Bool,
        defaults: UserDefaults = .standard
    ) -> [MissingPermission] {
        let missing = missingPermissions(
            micGranted: micGranted,
            accessibilityGranted: accessibilityGranted,
            screenRecordingGranted: screenRecordingGranted,
            meetingRecordingEnabled: meetingRecordingEnabled
        )
        guard !missing.isEmpty else { return [] }

        let current = fingerprint(
            micGranted: micGranted,
            accessibilityGranted: accessibilityGranted,
            screenRecordingGranted: screenRecordingGranted,
            meetingRecordingEnabled: meetingRecordingEnabled
        )

        if let stored = defaults.object(forKey: fingerprintKey) as? Int {
            // Only alert if the fingerprint shrank (something was revoked)
            guard current < stored else { return [] }
        }
        // No fingerprint stored → first post-onboarding launch, alert for missing

        return missing
    }

    /// Persist the current permission state. Call after the alert is dismissed
    /// (or immediately when no alert is needed) so the next launch has a baseline.
    public static func saveFingerprint(
        micGranted: Bool,
        accessibilityGranted: Bool,
        screenRecordingGranted: Bool,
        meetingRecordingEnabled: Bool,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(
            fingerprint(
                micGranted: micGranted,
                accessibilityGranted: accessibilityGranted,
                screenRecordingGranted: screenRecordingGranted,
                meetingRecordingEnabled: meetingRecordingEnabled
            ),
            forKey: fingerprintKey
        )
    }

    // MARK: - Private

    static func fingerprint(
        micGranted: Bool,
        accessibilityGranted: Bool,
        screenRecordingGranted: Bool,
        meetingRecordingEnabled: Bool
    ) -> Int {
        var bits = 0
        if micGranted { bits |= 1 }
        if accessibilityGranted { bits |= 2 }
        if meetingRecordingEnabled && screenRecordingGranted { bits |= 4 }
        return bits
    }

    static func missingPermissions(
        micGranted: Bool,
        accessibilityGranted: Bool,
        screenRecordingGranted: Bool,
        meetingRecordingEnabled: Bool
    ) -> [MissingPermission] {
        var missing: [MissingPermission] = []
        if !micGranted { missing.append(.microphone) }
        if !accessibilityGranted { missing.append(.accessibility) }
        if meetingRecordingEnabled && !screenRecordingGranted { missing.append(.screenRecording) }
        return missing
    }
}
```

- [ ] **Step 4: Run tests — all must pass**

```bash
swift test --filter LaunchPermissionCheckerTests 2>&1 | grep -E "error:|FAILED|passed|Suite"
```

Expected: `Test Suite 'LaunchPermissionCheckerTests' passed`

- [ ] **Step 5: Commit**

```bash
git add Sources/MacParakeetCore/Services/LaunchPermissionChecker.swift \
        Tests/MacParakeetTests/Services/LaunchPermissionCheckerTests.swift
git commit -m "feat(permissions): add LaunchPermissionChecker with bitmask fingerprint tracking"
```

---

## Task 3: Wire into `OnboardingCoordinator` with `NSAlert`

**Files:**
- Modify: `Sources/MacParakeet/App/OnboardingCoordinator.swift`

- [ ] **Step 1: Add `import AppKit` at the top of the file**

The file currently has `import Foundation`, `import MacParakeetCore`, `import MacParakeetViewModels`. Add:

```swift
import AppKit
import Foundation
import MacParakeetCore
import MacParakeetViewModels
```

- [ ] **Step 2: Replace `maybeShow` with the health-check `else` branch**

Current `maybeShow`:
```swift
func maybeShow(environment: AppEnvironment?) {
    guard let environment else { return }
    let completed = UserDefaults.standard.string(forKey: OnboardingViewModel.onboardingCompletedKey) != nil
    if !completed {
        show(
            permissionService: environment.permissionService,
            sttClient: environment.sttScheduler,
            diarizationService: environment.diarizationService,
            entitlementsService: environment.entitlementsService
        )
    }
}
```

Replace with:
```swift
func maybeShow(environment: AppEnvironment?) {
    guard let environment else { return }
    let completed = UserDefaults.standard.string(forKey: OnboardingViewModel.onboardingCompletedKey) != nil
    if !completed {
        show(
            permissionService: environment.permissionService,
            sttClient: environment.sttScheduler,
            diarizationService: environment.diarizationService,
            entitlementsService: environment.entitlementsService
        )
    } else {
        Task { @MainActor [weak self] in
            await self?.checkPermissionsAfterOnboarding(environment: environment)
        }
    }
}
```

- [ ] **Step 3: Add `checkPermissionsAfterOnboarding` and `showPermissionAlert` methods**

Add these two private methods before the closing `}` of the class:

```swift
private func checkPermissionsAfterOnboarding(environment: AppEnvironment) async {
    let micStatus = await environment.permissionService.checkMicrophonePermission()
    let micGranted = micStatus == .granted
    let axGranted = environment.permissionService.checkAccessibilityPermission()
    let screenGranted = environment.permissionService.checkScreenRecordingPermission()

    let missing = LaunchPermissionChecker.check(
        micGranted: micGranted,
        accessibilityGranted: axGranted,
        screenRecordingGranted: screenGranted,
        meetingRecordingEnabled: AppFeatures.meetingRecordingEnabled
    )

    LaunchPermissionChecker.saveFingerprint(
        micGranted: micGranted,
        accessibilityGranted: axGranted,
        screenRecordingGranted: screenGranted,
        meetingRecordingEnabled: AppFeatures.meetingRecordingEnabled
    )

    guard !missing.isEmpty else { return }
    showPermissionAlert(missing: missing, permissionService: environment.permissionService)
}

private func showPermissionAlert(
    missing: [MissingPermission],
    permissionService: PermissionServiceProtocol
) {
    let alert = NSAlert()
    alert.messageText = "MacParakeet needs some permissions"

    var lines: [String] = []
    if missing.contains(.microphone) {
        lines.append("• Microphone — required for dictation and meeting recording.")
    }
    if missing.contains(.accessibility) {
        lines.append("• Accessibility — required to paste dictated text.")
    }
    if missing.contains(.screenRecording) {
        lines.append("• Screen & System Audio Recording — required for meeting recording.")
    }
    alert.informativeText = lines.joined(separator: "\n")

    // Track which button index maps to which action.
    // NSAlert buttons are displayed right-to-left; first button added = rightmost = default.
    var actions: [() -> Void] = []
    for perm in missing {
        switch perm {
        case .microphone:
            alert.addButton(withTitle: "Open Microphone Settings")
            actions.append { permissionService.openMicrophoneSettings() }
        case .accessibility:
            alert.addButton(withTitle: "Open Accessibility Settings")
            actions.append { permissionService.openAccessibilitySettings() }
        case .screenRecording:
            alert.addButton(withTitle: "Open Screen Recording Settings")
            actions.append { permissionService.openScreenRecordingSettings() }
        }
    }
    alert.addButton(withTitle: "Later")

    NSApp.activate(ignoringOtherApps: true)
    let response = alert.runModal()
    let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    if index >= 0, index < actions.count {
        actions[index]()
    }
    // "Later" index equals actions.count — falls through with no action.
}
```

- [ ] **Step 4: Build to verify no compile errors**

```bash
swift build --target MacParakeet 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build of target: 'MacParakeet' complete!`

- [ ] **Step 5: Run full test suite**

```bash
swift test 2>&1 | grep -E "^Test Suite 'All tests'"
```

Expected: `Test Suite 'All tests' passed`

- [ ] **Step 6: Commit**

```bash
git add Sources/MacParakeet/App/OnboardingCoordinator.swift
git commit -m "feat(permissions): show NSAlert for revoked permissions on post-onboarding launch"
```

---

## Task 4: Self-signed cert script + docs update

**Files:**
- Create: `scripts/dev/create_pdx_cert.sh`
- Modify: `docs/pdx-edition.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Create `scripts/dev/create_pdx_cert.sh`**

```bash
#!/usr/bin/env bash
# Run ONCE per build machine to create a stable self-signed code-signing identity.
# After running this, sign PDX builds with --sign "MacParakeet PDX" instead of --sign -.
# The same cert → same TCC identity → permissions survive drag-replace updates.
set -euo pipefail

CERT_NAME="MacParakeet PDX"
KEYCHAIN=~/Library/Keychains/login.keychain-db
TMPDIR_LOCAL=$(mktemp -d)
trap 'rm -rf "$TMPDIR_LOCAL"' EXIT

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "\"$CERT_NAME\""; then
  echo "✓ '$CERT_NAME' already exists in login keychain. Nothing to do."
  exit 0
fi

echo "Creating self-signed certificate '$CERT_NAME'…"

KEY="$TMPDIR_LOCAL/key.pem"
CERT="$TMPDIR_LOCAL/cert.pem"
P12="$TMPDIR_LOCAL/cert.p12"

# Generate 2048-bit RSA key
openssl genrsa -out "$KEY" 2048 2>/dev/null

# Self-signed cert valid for 10 years
openssl req -new -x509 \
  -key "$KEY" \
  -out "$CERT" \
  -days 3650 \
  -subj "/CN=$CERT_NAME" \
  2>/dev/null

# Bundle into PKCS#12 (empty passphrase)
openssl pkcs12 -export \
  -inkey "$KEY" \
  -in "$CERT" \
  -out "$P12" \
  -passout pass: \
  2>/dev/null

# Import into login keychain, granting codesign access without prompting
security import "$P12" \
  -k "$KEYCHAIN" \
  -P "" \
  -T /usr/bin/codesign \
  -A

# Mark the cert trusted for code signing (prompts for password once)
security add-trusted-cert \
  -d \
  -r trustAsRoot \
  -k "$KEYCHAIN" \
  "$CERT"

echo "✓ Certificate '$CERT_NAME' created and trusted. Sign future PDX builds with:"
echo "  codesign --force --sign \"$CERT_NAME\" \"\$APP\""
```

Make it executable:
```bash
chmod +x scripts/dev/create_pdx_cert.sh
```

- [ ] **Step 2: Update the signing steps in `docs/pdx-edition.md`**

Find the ad-hoc signing block:
```bash
xattr -cr "$APP"
find "$APP/Contents/Resources" -maxdepth 1 -type f -perm -111 -print0 \
  | while IFS= read -r -d '' h; do codesign --force --sign - "$h"; done
xattr -cr "$APP"
codesign --force --sign - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
```

Replace every `--sign -` with `--sign "MacParakeet PDX"` and add a one-time-setup note above the block:

```bash
# One-time setup (run once per build machine, prompts for password):
# scripts/dev/create_pdx_cert.sh

SRC="dist/MacParakeet (PDX Edition).app"
WORK="/tmp/mp-pdx-sign"
mkdir -p "$WORK" && cp -R "$SRC" "$WORK/"
APP="$WORK/MacParakeet (PDX Edition).app"
xattr -cr "$APP"
find "$APP/Contents/Resources" -maxdepth 1 -type f -perm -111 -print0 \
  | while IFS= read -r -d '' h; do codesign --force --sign "MacParakeet PDX" "$h"; done
xattr -cr "$APP"
codesign --force --sign "MacParakeet PDX" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
```

- [ ] **Step 3: Update the same signing steps in `CLAUDE.md`**

Find the "Cut a new release" section's ad-hoc sign block (search for `codesign --force --sign -`) and apply the same replacements as Step 2. Also add the one-time setup comment above the sign block.

- [ ] **Step 4: Verify the cert script parses cleanly (no syntax errors)**

```bash
bash -n scripts/dev/create_pdx_cert.sh && echo "Syntax OK"
```

Expected: `Syntax OK`

- [ ] **Step 5: Commit**

```bash
git add scripts/dev/create_pdx_cert.sh docs/pdx-edition.md CLAUDE.md
git commit -m "feat(dist): stable self-signed cert for PDX TCC identity across builds"
```

---

## Self-Review

**Spec coverage:**
- ✅ Part 1 (signing): `create_pdx_cert.sh` + docs update in Task 4
- ✅ Part 2 (fingerprint + `LaunchPermissionChecker`): Task 2
- ✅ `openAccessibilitySettings()` added to protocol/impl/mock: Task 1
- ✅ `OnboardingCoordinator` wired with `else` branch + `NSAlert`: Task 3
- ✅ Only alerts when fingerprint shrinks or no fingerprint stored: `check()` logic in Task 2
- ✅ `saveFingerprint` called after alert dismissed: `checkPermissionsAfterOnboarding` in Task 3
- ✅ Screen recording gated by `AppFeatures.meetingRecordingEnabled`: both Task 2 and Task 3

**Placeholder scan:** No TBDs. All code blocks are complete and self-contained.

**Type consistency:**
- `MissingPermission` enum defined in Task 2, used in Task 3 — matches.
- `LaunchPermissionChecker.check(...)` and `.saveFingerprint(...)` signatures defined in Task 2 and called in Task 3 — param names match exactly.
- `openAccessibilitySettings()` added in Task 1, called in Task 3 — matches.
