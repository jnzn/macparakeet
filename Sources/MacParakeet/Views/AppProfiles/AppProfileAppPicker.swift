import AppKit
import UniformTypeIdentifiers

/// Opens an NSOpenPanel rooted at /Applications and returns the chosen app's
/// CFBundleIdentifier, or nil if cancelled / unreadable.
enum AppProfileAppPicker {
    static func pickBundleID() -> String? {
        let panel = NSOpenPanel()
        panel.title = "Choose an App"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }
}
