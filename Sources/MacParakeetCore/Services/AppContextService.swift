#if canImport(AppKit)
import AppKit
#endif
import Foundation

/// Read-only snapshot of the current macOS frontmost app context. Consumed by
/// `DictationService` at start-of-dictation to resolve which `AppProfile`
/// applies.
public enum AppContextService {
    /// Bundle identifier of the frontmost foreground app, or nil if unavailable.
    /// The MacParakeet menu-bar app does not activate on the dictation hotkey,
    /// and its floating overlays are non-activating NSPanels, so the frontmost
    /// app at this moment is the app the user is actually dictating into.
    public static func frontmostBundleID() -> String? {
        #if canImport(AppKit)
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        #else
        return nil
        #endif
    }
}
