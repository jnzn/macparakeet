import AppKit

/// Hover-revealed drag grabber for the AI Assistant bubble.
///
/// The bubble is a non-activating, borderless `NSPanel` where SwiftUI
/// `.onHover` / `.cursor(...)` do **not** fire (CLAUDE.md known pitfall), so the
/// grabber's hover-reveal, cursor swap, and drag are all done in AppKit via an
/// `NSTrackingArea`. The view is pinned bottom-center in the bubble's bottom
/// padding strip (below the input field, so it never intercepts typing), hidden
/// until the pointer enters its region, then faded in. Dragging it moves the
/// whole panel via `NSWindow.performDrag`.
final class AIAssistantBubbleDragHandle: NSView {
    private var trackingArea: NSTrackingArea?
    private var isDragging = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        alphaValue = 0  // hidden until hovered
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .cursorUpdate, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { setRevealed(true) }

    override func mouseExited(with event: NSEvent) {
        if !isDragging { setRevealed(false) }
    }

    override func cursorUpdate(with event: NSEvent) {
        (isDragging ? NSCursor.closedHand : NSCursor.openHand).set()
    }

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        NSCursor.closedHand.set()
        // performDrag runs its own event loop until mouseUp, moving the window
        // with the pointer. The handle moves too, so the cursor stays over it.
        window?.performDrag(with: event)
        isDragging = false
        NSCursor.openHand.set()
    }

    private func setRevealed(_ revealed: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = revealed ? 1 : 0
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // Two short, rounded parallel lines (the "grabber"), centered.
        let lineWidth: CGFloat = 24
        let lineHeight: CGFloat = 2.5
        let gap: CGFloat = 4
        let cx = bounds.midX
        let cy = bounds.midY
        NSColor.white.withAlphaComponent(0.6).setFill()
        for offset in [-(lineHeight + gap) / 2, (lineHeight + gap) / 2] {
            let rect = NSRect(
                x: cx - lineWidth / 2,
                y: cy + offset - lineHeight / 2,
                width: lineWidth,
                height: lineHeight
            )
            NSBezierPath(roundedRect: rect, xRadius: lineHeight / 2, yRadius: lineHeight / 2).fill()
        }
    }
}
