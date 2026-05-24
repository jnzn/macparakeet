# PDX Signing Identity + Launch Permission Health Check — Design

> **Status: APPROVED**

## Goal

Two related fixes for the PDX Edition upgrade UX problem: users lose all macOS TCC permissions when installing a new build, and there's no in-app mechanism to detect or recover from revoked permissions.

---

## Part 1 — Consistent Signing Identity

### Problem

Ad-hoc signing (`codesign --sign -`) produces a different designated requirement hash for every build. macOS TCC ties permission grants to that hash, so each new PDX zip is a new unknown app — all previous grants are silently dropped.

### Solution

Create a self-signed certificate named `"MacParakeet PDX"` once in the login keychain. Sign every build with it. TCC identifies the app by the certificate's stable subject, not the binary hash, so grants survive drag-replace updates.

### Files

- **New:** `scripts/dev/create_pdx_cert.sh` — one-time keygen script
- **Modified:** `docs/pdx-edition.sh` — signing steps use `--sign "MacParakeet PDX"`
- **Modified:** `CLAUDE.md` — same update in the "Cut a new release" section

### `create_pdx_cert.sh` logic

The script checks whether the `"MacParakeet PDX"` certificate already exists in the login keychain (idempotent). If not, it generates a self-signed RSA certificate using `openssl` and imports it with `security import`, marking it trusted for code signing. Exact openssl flags are in the implementation plan.

> **Note:** The cert lives only on the build machine. Recipients of the zip don't need it. TCC on each recipient's Mac associates the app with the cert subject, and carries that association forward on updates signed with the same cert.

---

## Part 2 — Launch-Time Permission Health Check

### Problem

After onboarding completes, the app never re-checks permissions. A build upgrade (even with the new signing fix, the first upgrade from ad-hoc to stable cert still revokes grants) leaves users with broken features and no explanation.

### Solution

On every post-onboarding launch, compare the current permission state to the last-known state (stored as a bitmask in UserDefaults). If permissions were revoked, show a single NSAlert that lists what's missing and offers one "Open Settings" button per permission. After dismissal, update the stored state.

### Fingerprint

Key: `pdx.permissionFingerprint` (Int, UserDefaults.standard)

| Bit | Permission | Check |
|-----|------------|-------|
| 0 | Microphone | `PermissionService.checkMicrophonePermission() == .granted` |
| 1 | Accessibility | `PermissionService.checkAccessibilityPermission()` |
| 2 | Screen Recording | `PermissionService.checkScreenRecordingPermission()` (only if `AppFeatures.meetingRecordingEnabled`) |

Alert fires when: `currentFingerprint < storedFingerprint` OR no stored fingerprint exists yet (first post-onboarding launch).

After dismissal: write `currentFingerprint` to UserDefaults regardless of what the user chose.

### `LaunchPermissionChecker` (MacParakeetCore)

```swift
// Sources/MacParakeetCore/Services/LaunchPermissionChecker.swift
public enum MissingPermission: Equatable, Sendable {
    case microphone
    case accessibility
    case screenRecording
}

public struct LaunchPermissionChecker: Sendable {
    public static let fingerprintKey = "pdx.permissionFingerprint"

    public static func check(
        micGranted: Bool,
        accessibilityGranted: Bool,
        screenRecordingGranted: Bool,
        meetingRecordingEnabled: Bool,
        defaults: UserDefaults = .standard
    ) -> [MissingPermission] // returns missing permissions if alert should fire

    public static func saveFingerprint(
        micGranted: Bool,
        accessibilityGranted: Bool,
        screenRecordingGranted: Bool,
        meetingRecordingEnabled: Bool,
        defaults: UserDefaults = .standard
    )
}
```

`check` returns non-empty only when the current fingerprint is less than the stored one (a bit went 0) or no fingerprint is stored. It does NOT write — the caller writes after the alert is dismissed.

### Alert (MacParakeet app layer)

Presented from `OnboardingCoordinator` via a new helper. Single `NSAlert`:

- **MessageText:** "MacParakeet needs some permissions"
- **InformativeText:** One sentence per missing permission explaining what breaks without it
- Buttons (up to 3, one per missing permission): "Open Microphone Settings" / "Open Accessibility Settings" / "Open Screen Recording Settings"
- Fourth button "Later" — NSAlert always adds a cancel-style button last

Clicking a settings button calls the corresponding `permissionService.open*Settings()` method. All buttons dismiss the alert. No chaining — one alert, one dismiss.

> NSAlert supports up to 3 buttons before layout degrades. With 3 possible missing permissions, this is exact.

### Integration

`OnboardingCoordinator.maybeShow(environment:)` gains an `else` branch:

```swift
func maybeShow(environment: AppEnvironment?) {
    guard let environment else { return }
    let completed = UserDefaults.standard.string(forKey: OnboardingViewModel.onboardingCompletedKey) != nil
    if !completed {
        show(...)
    } else {
        checkPermissionsAfterOnboarding(environment: environment)
    }
}
```

`checkPermissionsAfterOnboarding` calls `LaunchPermissionChecker.check(...)`, shows the alert if needed, then calls `LaunchPermissionChecker.saveFingerprint(...)` after dismissal.

### Files

- **New:** `Sources/MacParakeetCore/Services/LaunchPermissionChecker.swift`
- **New:** `Tests/MacParakeetTests/Services/LaunchPermissionCheckerTests.swift`
- **Modified:** `Sources/MacParakeet/App/OnboardingCoordinator.swift`

---

## What This Does NOT Do

- Does not re-request permissions inline (macOS requires user to go to System Settings for mic/accessibility/screen recording on macOS 14+)
- Does not nag every launch — only fires when something was revoked
- Does not cover notification permissions (those are granted once via `UNUserNotificationCenter` and don't need this path)
- Does not change the onboarding flow itself

---

## Testing

`LaunchPermissionChecker` is a pure function — XCTest covers:
- All bits granted → no alert
- One bit revoked → alert with one missing permission
- All bits revoked → alert with all three
- No stored fingerprint (fresh install post-onboarding) → alert fires for any missing bit
- Fingerprint gained a bit (user re-granted after revocation) → no alert
