import Foundation

public enum AppPreferences {
    public static let menuBarOnlyModeKey = "menuBarOnlyMode"
    public static let telemetryEnabledKey = "telemetryEnabled"
    public static func isMenuBarOnlyModeEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: menuBarOnlyModeKey) as? Bool ?? false
    }

    /// PDX Edition default: telemetry is permanently off — the upstream
    /// telemetry endpoint isn't ours, and the Settings toggle was removed.
    public static func isTelemetryEnabled(defaults: UserDefaults = .standard) -> Bool {
        false
    }
}
