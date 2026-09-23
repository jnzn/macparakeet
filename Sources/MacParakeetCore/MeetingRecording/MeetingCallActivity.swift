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
