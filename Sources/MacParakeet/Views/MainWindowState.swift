import Foundation

@MainActor
@Observable
final class MainWindowState {
    var selectedItem: SidebarItem = .transcribe
    var showingProgressDetail = false

    /// Switch the sidebar to Library so the transcription detail surfaces in
    /// its natural home. The Transcribe tab is the capture surface (YouTube,
    /// file, meeting); once a transcription exists, it lives in Library.
    /// The `from:` parameter is retained for call-site readability.
    func navigateToTranscription(from current: SidebarItem? = nil) {
        _ = current
        selectedItem = .library
    }
}

