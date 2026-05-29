import AppKit
import MacParakeetViewModels
import SwiftUI

private final class VoiceMemoClickablePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class VoiceMemoPillController {
    private var panel: NSPanel?
    private let pillViewModel: VoiceMemoPillViewModel
    var onStop: (() -> Void)?

    init(viewModel: VoiceMemoPillViewModel) {
        self.pillViewModel = viewModel
    }

    func show() {
        if let panel {
            panel.orderFront(nil)
            return
        }

        let view = VoiceMemoPillView(viewModel: pillViewModel)
        let hosting = NSHostingView(rootView: view)

        let panelWidth: CGFloat = 180
        let panelHeight: CGFloat = 80
        hosting.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        hosting.autoresizingMask = [.width, .height]

        let panel = VoiceMemoClickablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.contentView = hosting

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            // Offset above meeting pill position so they don't overlap if both were visible.
            let x = frame.maxX - panelWidth
            let y = frame.midY - panelHeight / 2 + 100
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFront(nil)
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}
