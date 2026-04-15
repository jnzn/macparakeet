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
    var errorMessage: String? = nil
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

/// Triangle path for the speech-bubble tail. Oriented according to
/// `direction` so the triangle's tip points away from the bubble body.
struct BubbleTailShape: Shape {
    let direction: BubbleTailDirection

    func path(in rect: CGRect) -> Path {
        var p = Path()
        switch direction {
        case .down:
            // Tip at bottom-center, base across the top edge.
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            p.closeSubpath()
        case .up:
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.closeSubpath()
        case .left:
            p.move(to: CGPoint(x: rect.minX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.closeSubpath()
        case .right:
            p.move(to: CGPoint(x: rect.maxX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
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
            .padding(.bottom, 10)
        }
        .frame(width: 420, height: 280)
        // Liquid-glass background: a ZStack of the system material (which
        // auto-adapts to light / dark) with the user's picked color layered
        // on top as a stained-glass tint. Default tint is transparent, so
        // the material alone dictates the look and the bubble matches the
        // current system appearance out of the box.
        .background(
            ZStack {
                Rectangle().fill(.regularMaterial)
                Rectangle().fill(backgroundColor)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .center) {
            tailOverlay
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
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

    /// Speech-bubble tail overlay. Rendered via a GeometryReader so the
    /// tail position adapts to the bubble's final frame. The tail is
    /// layered so it shares the bubble's material + tint look (same
    /// `.background` stack) and is clipped to a triangular shape.
    @ViewBuilder
    private var tailOverlay: some View {
        if state.tailDirection != .none {
            GeometryReader { geo in
                let tailSize: CGFloat = 14   // along the axis perpendicular to the edge
                let tailBase: CGFloat = 20   // along the axis parallel to the edge
                let cornerInset: CGFloat = 18 // keep the tail away from rounded corners

                let rect: CGRect = {
                    switch state.tailDirection {
                    case .down:
                        let maxX = geo.size.width - cornerInset - tailBase
                        let clamped = max(cornerInset, min(state.tailOffsetFraction * geo.size.width - tailBase / 2, maxX))
                        return CGRect(x: clamped, y: geo.size.height, width: tailBase, height: tailSize)
                    case .up:
                        let maxX = geo.size.width - cornerInset - tailBase
                        let clamped = max(cornerInset, min(state.tailOffsetFraction * geo.size.width - tailBase / 2, maxX))
                        return CGRect(x: clamped, y: -tailSize, width: tailBase, height: tailSize)
                    case .left:
                        let maxY = geo.size.height - cornerInset - tailBase
                        let clamped = max(cornerInset, min(state.tailOffsetFraction * geo.size.height - tailBase / 2, maxY))
                        return CGRect(x: -tailSize, y: clamped, width: tailSize, height: tailBase)
                    case .right:
                        let maxY = geo.size.height - cornerInset - tailBase
                        let clamped = max(cornerInset, min(state.tailOffsetFraction * geo.size.height - tailBase / 2, maxY))
                        return CGRect(x: geo.size.width, y: clamped, width: tailSize, height: tailBase)
                    case .none:
                        return .zero
                    }
                }()

                // Render material + tint using the same recipe as the body,
                // clipped to the triangle. Subtle border continuity skipped
                // here because a 14pt triangle with a 0.5pt stroke reads
                // muddy; the main bubble's outline provides enough framing.
                BubbleTailShape(direction: state.tailDirection)
                    .fill(.regularMaterial)
                    .overlay(
                        BubbleTailShape(direction: state.tailDirection)
                            .fill(backgroundColor)
                    )
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.origin.x - (geo.size.width - rect.width) / 2,
                            y: rect.origin.y - (geo.size.height - rect.height) / 2)
            }
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
