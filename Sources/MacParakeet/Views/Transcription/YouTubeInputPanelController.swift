import AppKit
import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

/// Manages a lightweight floating panel for YouTube URL input (Spotlight-style).
/// Unlike DictationOverlayController which uses `.nonactivatingPanel`,
/// this panel needs keyboard focus for the text field, so it uses
/// `canBecomeKey = true` with `canBecomeMain = false`.
@MainActor
final class YouTubeInputPanelController {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<YouTubeInputPanelView>?
    private var clickMonitor: Any?

    private unowned let transcriptionViewModel: TranscriptionViewModel

    init(transcriptionViewModel: TranscriptionViewModel) {
        self.transcriptionViewModel = transcriptionViewModel
    }

    func show() {
        guard panel == nil else {
            panel?.makeKeyAndOrderFront(nil)
            return
        }

        let view = YouTubeInputPanelView(
            viewModel: transcriptionViewModel,
            onTranscribe: { [weak self] in
                guard let self else { return }
                self.transcriptionViewModel.transcribeURL()
                self.hide()
            },
            onDismiss: { [weak self] in
                self?.hide()
            }
        )

        let hosting = NSHostingView(rootView: view)
        let panelWidth: CGFloat = 500
        let panelHeight: CGFloat = 220
        hosting.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)

        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // SwiftUI handles shadow
        panel.level = .floating
        panel.contentView = hosting

        // Center horizontally, upper third vertically (Spotlight-style)
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - panelWidth / 2
            let y = screenFrame.origin.y + screenFrame.height * 0.65 - panelHeight / 2
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        // Auto-paste: if clipboard has a valid YouTube URL, pre-fill
        if let clip = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           YouTubeURLValidator.isYouTubeURL(clip) {
            transcriptionViewModel.urlInput = clip
        }

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.panel = panel
        self.hostingView = hosting

        installClickOutsideMonitor()
    }

    func hide() {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
        transcriptionViewModel.urlInput = ""
    }

    // MARK: - Private

    private func installClickOutsideMonitor() {
        // Remove stale monitor if any
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }

        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            if event.window !== panel {
                self.hide()
            }
            return event
        }
    }
}

// MARK: - Panel Subclass

/// NSPanel that accepts keyboard focus (for text field) but won't become main window.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
