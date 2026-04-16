import SwiftUI
import MacParakeetCore

/// Observable state for a single bubble session. Held by the bubble
/// controller; rebuilt on dismiss so stale turns don't leak across sessions.
@MainActor
@Observable
final class AIAssistantBubbleState {
    var history: [AIAssistantTurn] = []
    var currentInput: String = ""
    var isThinking: Bool = false
    var isListening: Bool = false
    /// Live ASR partial rendered under the "Listening…" indicator while the
    /// user is holding the AI hotkey. Populated via the
    /// `.macParakeetStreamingPartial` notification pipeline — only flows when
    /// the user has "Live transcript overlay" enabled in Settings.
    var listeningPartialText: String = ""
    /// Live partial transcript shown under the input field while the user
    /// is using **primary** dictation (not the AI hotkey) with this bubble
    /// focused. Populated by the same streaming-partial subscription, but
    /// rendered separately from `listeningPartialText` so the UI makes it
    /// clear the user is dictating a follow-up rather than a new question.
    /// Cleared when the final transcript arrives via the paste interceptor.
    var dictationLivePreview: String = ""
    var errorMessage: String? = nil
    /// True when the source app (captured at press time) is still reachable
    /// via its PID so a "Replace selection" paste is plausible. False when
    /// the bubble was spawned outside a normal press flow (e.g. error
    /// bubble) — in which case the replace button is hidden.
    var canReplaceSelection: Bool = false
    /// Providers the user enabled in Settings. Empty / single-item array
    /// suppresses the switcher row (nothing to switch to).
    var enabledProviders: [AIAssistantConfig.Provider] = []
    /// Currently active provider for the next submission. Starts at the
    /// user's default and flips whenever they click a different provider
    /// icon in the switcher row; stays sticky from that point on.
    var activeProvider: AIAssistantConfig.Provider = .claude
    /// Speech-bubble tail direction, decided by the bubble controller based
    /// on where the bubble landed relative to the AX selection rect. `.none`
    /// suppresses the tail — used as a fallback when no usable anchor was
    /// found (screen-center positioning).
    var tailDirection: BubbleTailDirection = .none
    /// Position along the bubble edge that the tail should point from,
    /// expressed as a fraction from 0 (leading/top) to 1 (trailing/bottom).
    /// 0.5 = centered. Controller sets this to align the tip with the
    /// selection's center on screen.
    var tailOffsetFraction: CGFloat = 0.5
}

/// Which edge of the bubble the speech-bubble tail protrudes from.
public enum BubbleTailDirection: Sendable, Equatable {
    /// Tail on the bottom edge pointing down (bubble is ABOVE selection).
    case down
    /// Tail on the top edge pointing up (bubble is BELOW selection).
    case up
    /// Tail on the left edge pointing left (bubble is to the RIGHT of selection).
    case left
    /// Tail on the right edge pointing right (bubble is to the LEFT of selection).
    case right
    /// No tail — bubble has no directional anchor.
    case none
}

/// Cartoon speech-bubble outline: rounded rectangle body with a curved
/// tapering tail extending from one edge. Unlike the previous separate
/// triangle + bracket, this is a single continuous path so the fill /
/// stroke / shadow treat the bubble and tail as one shape — the cartoon
/// look the user asked for.
///
/// The bubble's BODY occupies an inset of `rect` leaving `tailLength`
/// worth of room on the tail-facing side for the tail to extend into.
/// For `.down` tails the body is the top portion; the tail grows into
/// the bottom `tailLength` strip.
struct SpeechBubbleShape: Shape {
    let direction: BubbleTailDirection
    /// 0…1 fraction along the tail edge where the tail base is centered.
    let tailOffsetFraction: CGFloat
    /// How far the tail extends past the body edge.
    let tailLength: CGFloat
    /// Width of the tail base where it attaches to the body.
    let tailBase: CGFloat
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let body = bodyRect(in: rect)
        guard direction != .none, tailLength > 0 else {
            var p = Path()
            p.addRoundedRect(in: body, cornerSize: CGSize(width: cornerRadius, height: cornerRadius))
            return p
        }
        // Single continuous outline: trace the rounded rect edge, but
        // when the tail's base chord crosses the tail-facing edge,
        // detour out to the tail tip and back. Renders as one shape
        // with no internal seam — fixing the stray line that showed
        // up when the body + tail were filled as separate paths.
        return continuousOutline(body: body, in: rect)
    }

    private func continuousOutline(body: CGRect, in rect: CGRect) -> Path {
        var p = Path()
        let r = cornerRadius
        let halfBase = tailBase / 2
        let inset = r + 2
        // Parametrize the tail so the code below can treat all four
        // directions uniformly: start/end points along the body edge,
        // tip point out from the body.
        struct TailAnchors {
            let baseLeft: CGPoint   // where we leave the body edge
            let tip: CGPoint
            let baseRight: CGPoint  // where we rejoin the body edge
            let controlLeft: CGPoint
            let controlRight: CGPoint
        }
        let t: TailAnchors = {
            switch direction {
            case .down:
                let anchorX = max(body.minX + inset + halfBase,
                                  min(body.minX + tailOffsetFraction * body.width,
                                      body.maxX - inset - halfBase))
                let baseY = body.maxY
                let tipX = anchorX - halfBase * 0.2
                let tipY = rect.maxY
                return TailAnchors(
                    baseLeft: CGPoint(x: anchorX - halfBase, y: baseY),
                    tip: CGPoint(x: tipX, y: tipY),
                    baseRight: CGPoint(x: anchorX + halfBase, y: baseY),
                    controlLeft: CGPoint(x: anchorX - halfBase * 0.6, y: baseY + tailLength * 0.55),
                    controlRight: CGPoint(x: anchorX + halfBase * 0.6, y: baseY + tailLength * 0.25)
                )
            case .up:
                let anchorX = max(body.minX + inset + halfBase,
                                  min(body.minX + tailOffsetFraction * body.width,
                                      body.maxX - inset - halfBase))
                let baseY = body.minY
                let tipX = anchorX - halfBase * 0.2
                let tipY = rect.minY
                return TailAnchors(
                    baseLeft: CGPoint(x: anchorX + halfBase, y: baseY),
                    tip: CGPoint(x: tipX, y: tipY),
                    baseRight: CGPoint(x: anchorX - halfBase, y: baseY),
                    controlLeft: CGPoint(x: anchorX + halfBase * 0.6, y: baseY - tailLength * 0.55),
                    controlRight: CGPoint(x: anchorX - halfBase * 0.6, y: baseY - tailLength * 0.25)
                )
            case .right:
                let anchorY = max(body.minY + inset + halfBase,
                                  min(body.minY + tailOffsetFraction * body.height,
                                      body.maxY - inset - halfBase))
                let baseX = body.maxX
                let tipX = rect.maxX
                let tipY = anchorY - halfBase * 0.2
                return TailAnchors(
                    baseLeft: CGPoint(x: baseX, y: anchorY - halfBase),
                    tip: CGPoint(x: tipX, y: tipY),
                    baseRight: CGPoint(x: baseX, y: anchorY + halfBase),
                    controlLeft: CGPoint(x: baseX + tailLength * 0.55, y: anchorY - halfBase * 0.6),
                    controlRight: CGPoint(x: baseX + tailLength * 0.25, y: anchorY + halfBase * 0.6)
                )
            case .left:
                let anchorY = max(body.minY + inset + halfBase,
                                  min(body.minY + tailOffsetFraction * body.height,
                                      body.maxY - inset - halfBase))
                let baseX = body.minX
                let tipX = rect.minX
                let tipY = anchorY - halfBase * 0.2
                return TailAnchors(
                    baseLeft: CGPoint(x: baseX, y: anchorY + halfBase),
                    tip: CGPoint(x: tipX, y: tipY),
                    baseRight: CGPoint(x: baseX, y: anchorY - halfBase),
                    controlLeft: CGPoint(x: baseX - tailLength * 0.55, y: anchorY + halfBase * 0.6),
                    controlRight: CGPoint(x: baseX - tailLength * 0.25, y: anchorY - halfBase * 0.6)
                )
            case .none:
                fatalError("tail direction guarded earlier")
            }
        }()

        // Trace the body edges with rounded corners, injecting the tail
        // detour when we cross the tail-facing edge.
        switch direction {
        case .down:
            // top-left corner → top edge → top-right corner
            p.move(to: CGPoint(x: body.minX, y: body.minY + r))
            p.addArc(center: CGPoint(x: body.minX + r, y: body.minY + r),
                     radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
            p.addLine(to: CGPoint(x: body.maxX - r, y: body.minY))
            p.addArc(center: CGPoint(x: body.maxX - r, y: body.minY + r),
                     radius: r, startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
            // right edge → bottom-right corner
            p.addLine(to: CGPoint(x: body.maxX, y: body.maxY - r))
            p.addArc(center: CGPoint(x: body.maxX - r, y: body.maxY - r),
                     radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            // bottom edge → detour out to tail tip and back → bottom-left corner
            p.addLine(to: t.baseRight)
            p.addQuadCurve(to: t.tip, control: t.controlRight)
            p.addQuadCurve(to: t.baseLeft, control: t.controlLeft)
            p.addLine(to: CGPoint(x: body.minX + r, y: body.maxY))
            p.addArc(center: CGPoint(x: body.minX + r, y: body.maxY - r),
                     radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            p.closeSubpath()
        case .up:
            // bottom-left → bottom → bottom-right
            p.move(to: CGPoint(x: body.minX, y: body.maxY - r))
            p.addArc(center: CGPoint(x: body.minX + r, y: body.maxY - r),
                     radius: r, startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
            p.addLine(to: CGPoint(x: body.maxX - r, y: body.maxY))
            p.addArc(center: CGPoint(x: body.maxX - r, y: body.maxY - r),
                     radius: r, startAngle: .degrees(90), endAngle: .degrees(0), clockwise: true)
            // right edge up → top-right corner
            p.addLine(to: CGPoint(x: body.maxX, y: body.minY + r))
            p.addArc(center: CGPoint(x: body.maxX - r, y: body.minY + r),
                     radius: r, startAngle: .degrees(0), endAngle: .degrees(270), clockwise: true)
            // top edge → tail detour → top-left corner
            p.addLine(to: t.baseLeft)
            p.addQuadCurve(to: t.tip, control: t.controlLeft)
            p.addQuadCurve(to: t.baseRight, control: t.controlRight)
            p.addLine(to: CGPoint(x: body.minX + r, y: body.minY))
            p.addArc(center: CGPoint(x: body.minX + r, y: body.minY + r),
                     radius: r, startAngle: .degrees(270), endAngle: .degrees(180), clockwise: true)
            p.closeSubpath()
        case .right:
            // top-left → top → top-right
            p.move(to: CGPoint(x: body.minX, y: body.minY + r))
            p.addArc(center: CGPoint(x: body.minX + r, y: body.minY + r),
                     radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
            p.addLine(to: CGPoint(x: body.maxX - r, y: body.minY))
            p.addArc(center: CGPoint(x: body.maxX - r, y: body.minY + r),
                     radius: r, startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
            // right edge with tail detour
            p.addLine(to: t.baseLeft)
            p.addQuadCurve(to: t.tip, control: t.controlLeft)
            p.addQuadCurve(to: t.baseRight, control: t.controlRight)
            p.addLine(to: CGPoint(x: body.maxX, y: body.maxY - r))
            p.addArc(center: CGPoint(x: body.maxX - r, y: body.maxY - r),
                     radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            p.addLine(to: CGPoint(x: body.minX + r, y: body.maxY))
            p.addArc(center: CGPoint(x: body.minX + r, y: body.maxY - r),
                     radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            p.closeSubpath()
        case .left:
            // top-left (go clockwise backward)
            p.move(to: CGPoint(x: body.minX + r, y: body.minY))
            p.addLine(to: CGPoint(x: body.maxX - r, y: body.minY))
            p.addArc(center: CGPoint(x: body.maxX - r, y: body.minY + r),
                     radius: r, startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
            p.addLine(to: CGPoint(x: body.maxX, y: body.maxY - r))
            p.addArc(center: CGPoint(x: body.maxX - r, y: body.maxY - r),
                     radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            p.addLine(to: CGPoint(x: body.minX + r, y: body.maxY))
            p.addArc(center: CGPoint(x: body.minX + r, y: body.maxY - r),
                     radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            // left edge with tail detour (going up)
            p.addLine(to: t.baseLeft)
            p.addQuadCurve(to: t.tip, control: t.controlLeft)
            p.addQuadCurve(to: t.baseRight, control: t.controlRight)
            p.addLine(to: CGPoint(x: body.minX, y: body.minY + r))
            p.addArc(center: CGPoint(x: body.minX + r, y: body.minY + r),
                     radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
            p.closeSubpath()
        case .none:
            break
        }
        return p
    }

    /// Inset the full rect to leave room for the tail on one side.
    private func bodyRect(in rect: CGRect) -> CGRect {
        switch direction {
        case .down:
            return CGRect(x: rect.minX, y: rect.minY,
                          width: rect.width, height: rect.height - tailLength)
        case .up:
            return CGRect(x: rect.minX, y: rect.minY + tailLength,
                          width: rect.width, height: rect.height - tailLength)
        case .right:
            return CGRect(x: rect.minX, y: rect.minY,
                          width: rect.width - tailLength, height: rect.height)
        case .left:
            return CGRect(x: rect.minX + tailLength, y: rect.minY,
                          width: rect.width - tailLength, height: rect.height)
        case .none:
            return rect
        }
    }

    private func tailSubPath(body: CGRect, in rect: CGRect) -> Path {
        var p = Path()
        let halfBase = tailBase / 2
        // Inset the tail attach points away from rounded corners so the
        // tail doesn't bite into the curve.
        let inset: CGFloat = cornerRadius + 2

        switch direction {
        case .down:
            let anchorX = max(body.minX + inset + halfBase,
                              min(body.minX + tailOffsetFraction * body.width,
                                  body.maxX - inset - halfBase))
            let baseY = body.maxY
            let tipX = anchorX - halfBase * 0.2   // slight curl toward one side
            let tipY = rect.maxY
            p.move(to: CGPoint(x: anchorX - halfBase, y: baseY))
            // Left edge of tail — gentle curve out to the tip
            p.addQuadCurve(
                to: CGPoint(x: tipX, y: tipY),
                control: CGPoint(x: anchorX - halfBase * 0.6, y: baseY + tailLength * 0.55)
            )
            // Right edge — curve back in to the base
            p.addQuadCurve(
                to: CGPoint(x: anchorX + halfBase, y: baseY),
                control: CGPoint(x: anchorX + halfBase * 0.6, y: baseY + tailLength * 0.25)
            )
            p.closeSubpath()
        case .up:
            let anchorX = max(body.minX + inset + halfBase,
                              min(body.minX + tailOffsetFraction * body.width,
                                  body.maxX - inset - halfBase))
            let baseY = body.minY
            let tipX = anchorX - halfBase * 0.2
            let tipY = rect.minY
            p.move(to: CGPoint(x: anchorX + halfBase, y: baseY))
            p.addQuadCurve(
                to: CGPoint(x: tipX, y: tipY),
                control: CGPoint(x: anchorX + halfBase * 0.6, y: baseY - tailLength * 0.55)
            )
            p.addQuadCurve(
                to: CGPoint(x: anchorX - halfBase, y: baseY),
                control: CGPoint(x: anchorX - halfBase * 0.6, y: baseY - tailLength * 0.25)
            )
            p.closeSubpath()
        case .right:
            let anchorY = max(body.minY + inset + halfBase,
                              min(body.minY + tailOffsetFraction * body.height,
                                  body.maxY - inset - halfBase))
            let baseX = body.maxX
            let tipX = rect.maxX
            let tipY = anchorY - halfBase * 0.2
            p.move(to: CGPoint(x: baseX, y: anchorY - halfBase))
            p.addQuadCurve(
                to: CGPoint(x: tipX, y: tipY),
                control: CGPoint(x: baseX + tailLength * 0.55, y: anchorY - halfBase * 0.6)
            )
            p.addQuadCurve(
                to: CGPoint(x: baseX, y: anchorY + halfBase),
                control: CGPoint(x: baseX + tailLength * 0.25, y: anchorY + halfBase * 0.6)
            )
            p.closeSubpath()
        case .left:
            let anchorY = max(body.minY + inset + halfBase,
                              min(body.minY + tailOffsetFraction * body.height,
                                  body.maxY - inset - halfBase))
            let baseX = body.minX
            let tipX = rect.minX
            let tipY = anchorY - halfBase * 0.2
            p.move(to: CGPoint(x: baseX, y: anchorY + halfBase))
            p.addQuadCurve(
                to: CGPoint(x: tipX, y: tipY),
                control: CGPoint(x: baseX - tailLength * 0.55, y: anchorY + halfBase * 0.6)
            )
            p.addQuadCurve(
                to: CGPoint(x: baseX, y: anchorY - halfBase),
                control: CGPoint(x: baseX - tailLength * 0.25, y: anchorY - halfBase * 0.6)
            )
            p.closeSubpath()
        case .none:
            break
        }
        return p
    }
}

struct AIAssistantBubbleView: View {
    @Bindable var state: AIAssistantBubbleState
    /// User-picked translucent background. Loaded from
    /// `AIAssistantConfigStore` at bubble open time — changes from Settings
    /// take effect on the next bubble open, not live.
    let backgroundColor: Color
    let onSubmit: (String) -> Void
    let onDismiss: () -> Void
    /// Fired when the user clicks a turn's "Replace selection" button.
    /// Passes the turn index so the controller knows which response to
    /// write into the source app.
    let onReplaceSelection: (Int) -> Void
    /// Fired when the user taps a provider icon in the switcher row.
    /// Controller flips `state.activeProvider` and all subsequent
    /// submissions use the new CLI.
    let onSelectProvider: (AIAssistantConfig.Provider) -> Void

    /// Drives the open animation. Starts at 0 (hidden/small) and animates
    /// to 1 (shown/full-size) on first appearance.
    @State private var appearProgress: CGFloat = 0

    /// Tint opacity threshold above which the user's picked color dominates
    /// the visible background enough that we should derive foreground from
    /// it. Below the threshold, the liquid-glass material is what the user
    /// mostly sees, so we fall back to the system `.primary` foreground
    /// which auto-flips with light/dark appearance.
    private static let tintDominatesThreshold: Double = 0.4

    /// Approximate opacity of the tint layer based on the picked color.
    /// SwiftUI `Color` doesn't expose its components directly, so we bridge
    /// through NSColor to read back the opacity we set when constructing
    /// from `CodableColor`.
    private var tintOpacity: Double {
        Double(NSColor(backgroundColor).usingColorSpace(.sRGB)?.alphaComponent ?? 0)
    }

    /// True when the user's tint is opaque enough to override the system
    /// material's appearance-driven contrast.
    private var tintDominates: Bool {
        tintOpacity >= Self.tintDominatesThreshold
    }

    /// Foreground for the LLM response. When the tint is faint or absent
    /// (default case), use the system `.primary` color — the material will
    /// handle light/dark adaptation for us. When the user's tint dominates
    /// the look, compute a WCAG-style contrasting foreground so dark tints
    /// get light text and vice versa.
    private var foreground: Color {
        tintDominates
            ? BubbleContrast.contrastingForeground(for: backgroundColor)
            : .primary
    }

    /// Muted variant of `foreground` for the user's question line and other
    /// secondary chrome. Uses system `.secondary` when the material adapts,
    /// else a dimmed copy of the contrast-computed foreground.
    private var foregroundMuted: Color {
        tintDominates ? foreground.opacity(0.65) : .secondary
    }

    /// Sentinel ID for the auto-scroll anchor at the bottom of the
    /// conversation. `ScrollViewReader.scrollTo(bottomAnchorID, anchor: .bottom)`
    /// keeps the latest turn in view whenever content grows.
    private let bottomAnchorID = "ai-assistant-bubble-bottom"

    /// Content area size (the readable portion of the bubble).
    private static let bodyWidth: CGFloat = 420
    private static let bodyHeight: CGFloat = 280
    /// How far the tail extends past the body edge. Sized to match the
    /// classic cartoon speech-bubble look — long enough to read as a
    /// tail, short enough to stay on-screen near the anchor.
    static let tailLength: CGFloat = 34
    private static let tailBase: CGFloat = 28
    private static let bubbleCornerRadius: CGFloat = 18

    /// Total outer frame width. Only grows past bodyWidth when the tail
    /// protrudes horizontally.
    private var outerWidth: CGFloat {
        switch state.tailDirection {
        case .left, .right: return Self.bodyWidth + Self.tailLength
        default: return Self.bodyWidth
        }
    }

    private var outerHeight: CGFloat {
        switch state.tailDirection {
        case .up, .down: return Self.bodyHeight + Self.tailLength
        default: return Self.bodyHeight
        }
    }

    /// Pad the body content away from whichever edge the tail grows
    /// into, so the ScrollView / TextField aren't drawn over the tail.
    private var bodyContentInsets: EdgeInsets {
        switch state.tailDirection {
        case .down: return EdgeInsets(top: 0, leading: 0, bottom: Self.tailLength, trailing: 0)
        case .up:   return EdgeInsets(top: Self.tailLength, leading: 0, bottom: 0, trailing: 0)
        case .right: return EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: Self.tailLength)
        case .left:  return EdgeInsets(top: 0, leading: Self.tailLength, bottom: 0, trailing: 0)
        case .none:  return EdgeInsets()
        }
    }

    /// Speech bubble shape (body + tail) used for every fill + stroke
    /// layer so the whole thing renders as one continuous cartoon shape.
    private var bubbleShape: SpeechBubbleShape {
        SpeechBubbleShape(
            direction: state.tailDirection,
            tailOffsetFraction: state.tailOffsetFraction,
            tailLength: state.tailDirection == .none ? 0 : Self.tailLength,
            tailBase: Self.tailBase,
            cornerRadius: Self.bubbleCornerRadius
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(state.history.enumerated()), id: \.offset) { idx, turn in
                            VStack(alignment: .leading, spacing: 8) {
                                // User question — italic, muted, compact.
                                Text(turn.question)
                                    .font(.callout.italic())
                                    .foregroundStyle(foregroundMuted)
                                    .textSelection(.enabled)
                                // LLM response — Apple's "New York" serif at
                                // reading size. System-bundled on macOS; gives
                                // the bubble a warm editorial feel without
                                // shipping proprietary fonts (Claude's
                                // Copernicus is not distributable).
                                //
                                // Renders inline markdown via AttributedString.
                                // Covers **bold**, *italic*, `code`, links, and
                                // ~~strikethrough~~. Headings, lists, block
                                // code, tables fall back to literal characters —
                                // upgrade to MarkdownUI package in a later pass
                                // if richer rendering becomes important.
                                Text(Self.renderMarkdown(turn.response))
                                    .font(.system(size: 15, design: .serif))
                                    .foregroundStyle(foreground)
                                    .lineSpacing(3)
                                    .textSelection(.enabled)

                                if state.canReplaceSelection {
                                    Button {
                                        onReplaceSelection(idx)
                                    } label: {
                                        Label("Replace selection", systemImage: "arrow.left.and.right.text.vertical")
                                            .font(.caption)
                                            .foregroundStyle(foregroundMuted)
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Paste this response over your original selection in the source app.")
                                }
                            }
                            if idx < state.history.count - 1 {
                                Divider().padding(.vertical, 4)
                            }
                        }
                        if state.isListening {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    Image(systemName: "mic.fill")
                                        .foregroundStyle(.red)
                                    Text("Listening — release hotkey to send")
                                        .font(.callout)
                                        .foregroundStyle(foregroundMuted)
                                }
                                if !state.listeningPartialText.isEmpty {
                                    Text(state.listeningPartialText)
                                        .font(.body)
                                        .foregroundStyle(foreground.opacity(0.85))
                                        .italic()
                                }
                            }
                        }
                        if state.isThinking {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Thinking…")
                                    .font(.callout)
                                    .foregroundStyle(foregroundMuted)
                            }
                        }
                        if let err = state.errorMessage {
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                        if state.history.isEmpty && !state.isThinking && !state.isListening && state.errorMessage == nil {
                            Text("Hold the hotkey and speak, or type a question.")
                                .font(.callout)
                                .foregroundStyle(foregroundMuted)
                        }
                        // Invisible anchor that the ScrollViewReader scrolls
                        // to whenever a new turn lands or partial text grows.
                        Color.clear.frame(height: 1).id(bottomAnchorID)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                }
                // Auto-scroll triggers: new turn, thinking/listening flip,
                // or live partial text growth during listening.
                .onChange(of: state.history.count) { _, _ in
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: state.isThinking) { _, _ in
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: state.isListening) { _, _ in
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: state.listeningPartialText) { _, _ in
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: state.errorMessage) { _, _ in
                    scrollToBottom(proxy: proxy)
                }
            }

            if !state.dictationLivePreview.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "mic.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                    Text(state.dictationLivePreview)
                        .font(.callout.italic())
                        .foregroundStyle(foreground.opacity(0.8))
                        .lineLimit(2)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 2)
            }

            HStack(spacing: 6) {
                TextField("Ask a question…", text: $state.currentInput, axis: .horizontal)
                    .textFieldStyle(.roundedBorder)
                    .disabled(state.isThinking)
                    .onSubmit { submit() }
                    // Belt-and-suspenders: `.onSubmit` on a TextField inside
                    // a non-activating NSPanel can drop the return key in
                    // some SwiftUI versions. `.onKeyPress(.return)` is the
                    // lower-level hook and fires even when the field-level
                    // submit handler doesn't.
                    .onKeyPress(.return) {
                        submit()
                        return .handled
                    }
                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(foreground)
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
            }
            .padding(.horizontal, 12)

            if state.enabledProviders.count > 1 {
                providerSwitcher
                    .padding(.horizontal, 12)
                    .padding(.top, 2)
            }
        }
        .padding(.bottom, 10)
        .padding(bodyContentInsets)
        .frame(width: outerWidth, height: outerHeight)
        // Liquid-glass speech bubble: single continuous SpeechBubbleShape
        // covers body + curved tail so fill / stroke / shadow treat them
        // as one cartoon bubble. Layers:
        //   1. `.ultraThinMaterial` — translucent glass base.
        //   2. Top-to-center highlight gradient — light-on-glass cue.
        //   3. User tint overlay — stained-glass filter.
        .background(
            bubbleShape.fill(.ultraThinMaterial)
        )
        .background(
            bubbleShape.fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.12),
                        Color.white.opacity(0.02),
                        Color.clear,
                    ],
                    startPoint: .top,
                    endPoint: .center
                )
            )
        )
        .background(
            bubbleShape.fill(backgroundColor)
        )
        .overlay(
            // Single soft stroke — previous double-stroke (light
            // gradient + dark outer) read as a visible hairline
            // across the bubble body because the two strokes
            // anti-aliased into a distinct band.
            bubbleShape.stroke(Color.primary.opacity(0.12), lineWidth: 0.6)
        )
        .shadow(color: Color.black.opacity(0.25), radius: 24, x: 0, y: 12)
        // Open animation: scales up from 92% and fades in. Anchor on the
        // tail-facing edge so the bubble "grows" out of the selection
        // instead of expanding from its own center. Spring feel without
        // a full spring curve — keeps the motion crisp.
        .scaleEffect(0.92 + 0.08 * appearProgress, anchor: scaleAnchor)
        .opacity(Double(appearProgress))
        .onAppear {
            appearProgress = 0
            withAnimation(.easeOut(duration: 0.22)) {
                appearProgress = 1
            }
        }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.18)) {
            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
        }
    }

    /// Row of small provider icons. Tapping one switches the active
    /// provider for future turns. The current provider is highlighted
    /// with a filled chip in its brand color; inactive providers show
    /// as dimmed monochrome icons. Appears only when 2+ providers are
    /// enabled in Settings.
    @ViewBuilder
    private var providerSwitcher: some View {
        HStack(spacing: 8) {
            ForEach(state.enabledProviders, id: \.self) { provider in
                let isActive = provider == state.activeProvider
                let components = provider.brandColorComponents
                let brand = Color(
                    red: components.red,
                    green: components.green,
                    blue: components.blue
                )
                Button {
                    onSelectProvider(provider)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: provider.iconSystemName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(isActive ? Color.white : brand)
                        if isActive {
                            Text(provider.displayName)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(isActive ? brand : brand.opacity(0.0))
                    )
                    .overlay(
                        Capsule().stroke(brand.opacity(isActive ? 0 : 0.5), lineWidth: 0.8)
                    )
                }
                .buttonStyle(.plain)
                .help("Switch to \(provider.displayName) for the next turn.")
            }
            Spacer()
        }
    }

    /// Where the scale animation emanates from. Pick the edge opposite the
    /// tail so the bubble visually "grows out of" the selection anchor
    /// rather than expanding from its own center. Falls back to center
    /// when there's no anchor (e.g. unattached error bubbles).
    private var scaleAnchor: UnitPoint {
        switch state.tailDirection {
        case .down: return UnitPoint(x: state.tailOffsetFraction, y: 1)
        case .up: return UnitPoint(x: state.tailOffsetFraction, y: 0)
        case .left: return UnitPoint(x: 0, y: state.tailOffsetFraction)
        case .right: return UnitPoint(x: 1, y: state.tailOffsetFraction)
        case .none: return .center
        }
    }

    private var canSubmit: Bool {
        !state.currentInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !state.isThinking
    }

    private func submit() {
        guard canSubmit else { return }
        let q = state.currentInput
        state.currentInput = ""
        onSubmit(q)
    }

    /// Parse Claude/Codex output as markdown so `**bold**`, `*italic*`,
    /// `` `code` ``, and links render as formatted text. `.full` interprets
    /// paragraph breaks and inline elements; `inlineOnlyPreservingWhitespace`
    /// would strip newlines, which is wrong for multi-paragraph responses.
    /// Falls back to plain text on parse failure.
    private static func renderMarkdown(_ raw: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full
        )
        if let parsed = try? AttributedString(markdown: raw, options: options) {
            return parsed
        }
        return AttributedString(raw)
    }
}
