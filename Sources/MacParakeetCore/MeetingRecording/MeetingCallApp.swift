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
