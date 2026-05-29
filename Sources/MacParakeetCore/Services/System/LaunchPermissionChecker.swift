import Foundation

public enum MissingPermission: Equatable, Sendable {
    case microphone
    case accessibility
    case screenRecording
}

public struct LaunchPermissionChecker: Sendable {
    public static let fingerprintKey = "pdx.permissionFingerprint"

    /// Returns missing permissions that should trigger an alert.
    /// Fires when no fingerprint is stored yet (first post-onboarding launch) and
    /// permissions are missing, OR when the fingerprint shrank (revocation detected).
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
            guard current < stored else { return [] }
        }

        return missing
    }

    /// Persist the current permission state. Call after alert is dismissed.
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

    // MARK: - Internal (internal not private so tests can verify bitmask values)

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
