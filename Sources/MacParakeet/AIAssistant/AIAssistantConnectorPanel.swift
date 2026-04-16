import AppKit
import SwiftUI

/// Transparent NSPanel that renders a "bracket" connector between the AI
/// Assistant bubble and the user's selected text. Spawns as a sibling of
/// the main bubble panel so the bubble's own content frame stays a clean
/// fixed size. Sits at `.floating` level so it layers below the bubble
/// (same level; last-shown is on top — we order it before makeKeyAndOrderFront
/// on the bubble).
///
/// Shape: an L-bracket with a stubby perpendicular on the selection side
/// and a short line fading into the bubble edge. Drawn in the bubble's
/// foreground-contrast color so it reads as part of the bubble.
@MainActor
final class AIAssistantConnectorPanel {
    private var panel: NSPanel?

    /// Show a bracket panel connecting the bubble rect (source) to the
    /// selection rect (target). All rects are Cocoa screen coords (origin
    /// = bottom-left of primary display). `tail` tells us which edge of
    /// the bubble the pointer grows from — selects the right-angle
    /// geometry.
    ///
    /// No-op when `tail == .none` or when the anchor is inside / overlaps
    /// the bubble (no room to render a connector).
    func show(
        bubbleRect: CGRect,
        anchorRect: CGRect,
        tail: BubbleTailDirection,
        color: Color
    ) {
        guard tail != .none else {
            hide()
            return
        }

        guard let canvasRect = Self.canvasRect(
            bubbleRect: bubbleRect,
            anchorRect: anchorRect,
            tail: tail
        ) else {
            hide()
            return
        }

        let view = AIAssistantConnectorView(
            canvasSize: canvasRect.size,
            bubbleFrameInCanvas: Self.relativeRect(bubbleRect, in: canvasRect),
            anchorFrameInCanvas: Self.relativeRect(anchorRect, in: canvasRect),
            tail: tail,
            color: color
        )
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: canvasRect.size)
        hosting.autoresizingMask = [.width, .height]

        if let existing = panel {
            existing.contentView = hosting
            existing.setFrame(canvasRect, display: true)
            existing.orderFront(nil)
            return
        }

        let newPanel = NSPanel(
            contentRect: canvasRect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = false
        newPanel.level = .floating
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.ignoresMouseEvents = true
        newPanel.isReleasedWhenClosed = false
        newPanel.contentView = hosting
        newPanel.orderFront(nil)
        panel = newPanel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: - Geometry helpers

    /// Bounding rect (in Cocoa screen coords) that covers both the bubble
    /// edge and the anchor edge with a small pad. The connector view draws
    /// inside this rect in local coordinates.
    static func canvasRect(
        bubbleRect: CGRect,
        anchorRect: CGRect,
        tail: BubbleTailDirection
    ) -> CGRect? {
        let pad: CGFloat = 6
        switch tail {
        case .down:
            // Bubble is above anchor. Canvas spans from the bubble's
            // bottom edge down to the anchor's top edge.
            let top = bubbleRect.minY
            let bottom = anchorRect.maxY
            guard top > bottom else { return nil }
            let height = top - bottom
            let x = min(bubbleRect.minX, anchorRect.minX) - pad
            let width = max(bubbleRect.maxX, anchorRect.maxX) - x + pad
            return CGRect(x: x, y: bottom, width: width, height: height)
        case .up:
            // Bubble is below anchor. Canvas spans from anchor bottom
            // down to bubble top. (Cocoa Y grows upward, so anchor's
            // bottom is lower in screen.)
            let top = anchorRect.minY
            let bottom = bubbleRect.maxY
            guard top > bottom else { return nil }
            let height = top - bottom
            let x = min(bubbleRect.minX, anchorRect.minX) - pad
            let width = max(bubbleRect.maxX, anchorRect.maxX) - x + pad
            return CGRect(x: x, y: bottom, width: width, height: height)
        case .left:
            // Bubble is to the right of anchor.
            let left = anchorRect.maxX
            let right = bubbleRect.minX
            guard right > left else { return nil }
            let width = right - left
            let y = min(bubbleRect.minY, anchorRect.minY) - pad
            let height = max(bubbleRect.maxY, anchorRect.maxY) - y + pad
            return CGRect(x: left, y: y, width: width, height: height)
        case .right:
            // Bubble is to the left of anchor.
            let left = bubbleRect.maxX
            let right = anchorRect.minX
            guard right > left else { return nil }
            let width = right - left
            let y = min(bubbleRect.minY, anchorRect.minY) - pad
            let height = max(bubbleRect.maxY, anchorRect.maxY) - y + pad
            return CGRect(x: left, y: y, width: width, height: height)
        case .none:
            return nil
        }
    }

    /// Convert a rect in Cocoa screen coords to SwiftUI-local coords within
    /// `canvas` (top-left origin, Y grows downward).
    static func relativeRect(_ rect: CGRect, in canvas: CGRect) -> CGRect {
        let x = rect.origin.x - canvas.origin.x
        let cocoaY = rect.origin.y - canvas.origin.y
        // SwiftUI Y grows downward from the top of the canvas.
        let swiftY = canvas.height - cocoaY - rect.height
        return CGRect(x: x, y: swiftY, width: rect.width, height: rect.height)
    }
}

// MARK: - Connector view

/// SwiftUI view that draws the bracket connecting `bubbleFrameInCanvas` to
/// `anchorFrameInCanvas`. Uses a thick stroke + subtle blur so the line
/// reads as part of the bubble's glass material rather than a raw stroke.
struct AIAssistantConnectorView: View {
    let canvasSize: CGSize
    let bubbleFrameInCanvas: CGRect
    let anchorFrameInCanvas: CGRect
    let tail: BubbleTailDirection
    let color: Color

    var body: some View {
        ZStack {
            // Main bracket stroke
            BracketShape(
                bubbleFrame: bubbleFrameInCanvas,
                anchorFrame: anchorFrameInCanvas,
                tail: tail
            )
            .stroke(color.opacity(0.65), style: StrokeStyle(
                lineWidth: 2.5,
                lineCap: .round,
                lineJoin: .round
            ))
            // Soft halo so the line reads against any background
            BracketShape(
                bubbleFrame: bubbleFrameInCanvas,
                anchorFrame: anchorFrameInCanvas,
                tail: tail
            )
            .stroke(color.opacity(0.15), style: StrokeStyle(
                lineWidth: 8,
                lineCap: .round,
                lineJoin: .round
            ))
            .blur(radius: 3)
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .allowsHitTesting(false)
    }
}

/// Bracket path: starts at the bubble edge, runs a short distance
/// perpendicular to that edge, then bends and runs toward the selection's
/// near edge. Gives the "big bracket" look without a hard tail triangle.
struct BracketShape: Shape {
    let bubbleFrame: CGRect
    let anchorFrame: CGRect
    let tail: BubbleTailDirection

    func path(in _: CGRect) -> Path {
        var p = Path()
        switch tail {
        case .down:
            // Bubble above; anchor below.
            let bubbleEdgeY = bubbleFrame.maxY
            let anchorEdgeY = anchorFrame.minY
            let startX = bubbleFrame.midX
            let endX = anchorFrame.midX
            let mid = (bubbleEdgeY + anchorEdgeY) / 2
            p.move(to: CGPoint(x: startX, y: bubbleEdgeY))
            p.addLine(to: CGPoint(x: startX, y: mid))
            p.addLine(to: CGPoint(x: endX, y: mid))
            p.addLine(to: CGPoint(x: endX, y: anchorEdgeY))
        case .up:
            // Bubble below; anchor above.
            let bubbleEdgeY = bubbleFrame.minY
            let anchorEdgeY = anchorFrame.maxY
            let startX = bubbleFrame.midX
            let endX = anchorFrame.midX
            let mid = (bubbleEdgeY + anchorEdgeY) / 2
            p.move(to: CGPoint(x: startX, y: bubbleEdgeY))
            p.addLine(to: CGPoint(x: startX, y: mid))
            p.addLine(to: CGPoint(x: endX, y: mid))
            p.addLine(to: CGPoint(x: endX, y: anchorEdgeY))
        case .left:
            // Bubble to the right; anchor to the left.
            let bubbleEdgeX = bubbleFrame.minX
            let anchorEdgeX = anchorFrame.maxX
            let startY = bubbleFrame.midY
            let endY = anchorFrame.midY
            let mid = (bubbleEdgeX + anchorEdgeX) / 2
            p.move(to: CGPoint(x: bubbleEdgeX, y: startY))
            p.addLine(to: CGPoint(x: mid, y: startY))
            p.addLine(to: CGPoint(x: mid, y: endY))
            p.addLine(to: CGPoint(x: anchorEdgeX, y: endY))
        case .right:
            // Bubble to the left; anchor to the right.
            let bubbleEdgeX = bubbleFrame.maxX
            let anchorEdgeX = anchorFrame.minX
            let startY = bubbleFrame.midY
            let endY = anchorFrame.midY
            let mid = (bubbleEdgeX + anchorEdgeX) / 2
            p.move(to: CGPoint(x: bubbleEdgeX, y: startY))
            p.addLine(to: CGPoint(x: mid, y: startY))
            p.addLine(to: CGPoint(x: mid, y: endY))
            p.addLine(to: CGPoint(x: anchorEdgeX, y: endY))
        case .none:
            break
        }
        return p
    }
}
