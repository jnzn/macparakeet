import Foundation

public enum AppPreferences {
    public static let menuBarOnlyModeKey = "menuBarOnlyMode"
    public static let telemetryEnabledKey = "telemetryEnabled"
    public static let meetingTitlePrefixKey = "meetingTitlePrefix"

    public static func isMenuBarOnlyModeEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: menuBarOnlyModeKey) as? Bool ?? false
    }

    public static func isTelemetryEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: telemetryEnabledKey) as? Bool ?? true
    }

    public static func meetingTitlePrefix(defaults: UserDefaults = .standard) -> String {
        guard let raw = defaults.string(forKey: meetingTitlePrefixKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty else {
            return "Meeting"
        }
        return raw
    }
}
