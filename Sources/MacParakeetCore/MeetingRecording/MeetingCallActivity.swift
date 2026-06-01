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
