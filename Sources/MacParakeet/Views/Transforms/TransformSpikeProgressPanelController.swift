import AppKit
import MacParakeetCore
import SwiftUI

/// Non-activating panel that hosts the Transforms spike progress UI. Spike
/// scope only — see `docs/research/transforms-design-2026-05.md` for the
/// production design (custom loader / pill anchored near the trigger context).
///
/// NSPanel notes:
/// - `canBecomeKey` is `false` so triggering the hotkey doesn't yank focus
///   from the user's frontmost app (which is the whole point — we paste back
///   into their text field).
/// - `.nonactivatingPanel | .borderless` matches the dictation + meeting
///   recording pill chrome elsewhere in the app.
private final class TransformsSpikePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
@Observable
final class TransformSpikeProgressViewModel {
    var label: String = "Still polishing…"
    var phase: Phase = .working
    /// Hidden during the working state's first few seconds — the rose loader
    /// is enough signal that work is in flight, and the user just pressed the
    /// hotkey so they already know what's happening. The controller flips
    /// this on after a patience threshold (`labelRevealDelay`) so longer-than-
    /// usual runs get an empathetic "still working" cue without forcing every
    /// short transform to render text.
    var showLabel: Bool = false

    enum Phase: Equatable {
        case working
        case done(message: String)
        case failed(message: String)
    }
}

@MainActor
final class TransformSpikeProgressPanelController {
    private var panel: NSPanel?
    private var host: NSHostingView<TransformSpikeProgressView>?
    private var viewModel: TransformSpikeProgressViewModel?
    private var autoDismissTask: Task<Void, Never>?
    private var labelRevealTask: Task<Void, Never>?

    /// Pill anchored at the same bottom-center slot the dictation overlay
    /// uses. Visually unifies all "press hotkey → thing happens" surfaces
    /// in one location so the user's eye knows where to look.
    private static let bottomOffset: CGFloat = 12
    /// Low floor so the done state can collapse to a perfect circle:
    /// 22pt icon + 10pt inner padding * 2 + 10pt shadow padding * 2 = 62pt.
    /// Working state starts here (icon-only) and grows once the patience
    /// threshold reveals the "still polishing" label.
    private static let minimumWidth: CGFloat = 62
    private static let maximumWidth: CGFloat = 360
    private static let baselineHeight: CGFloat = 64
    /// How long the working state stays icon-only before revealing a label.
    /// Chosen against observed LLM timings: short transforms (<2s) finish
    /// before this fires and never show text; cold-start or large-text
    /// transforms (>5s) get an empathetic "still working" cue. 10s felt too
    /// late — by then users have already started wondering.
    private static let labelRevealDelay: Duration = .seconds(5)

    /// Open (or reuse) the panel showing the in-progress indicator. Idempotent
    /// — calling `show` while a panel is visible just resets state. The pill
    /// starts as an icon-only circle; if work runs past `labelRevealDelay` the
    /// caller-supplied label is faded in.
    func show(label: String = "Still polishing…") {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        labelRevealTask?.cancel()
        labelRevealTask = nil

        if let viewModel {
            viewModel.label = label
            viewModel.phase = .working
            viewModel.showLabel = false
            scheduleRelayout()
            scheduleLabelReveal()
            return
        }

        let vm = TransformSpikeProgressViewModel()
        vm.label = label
        self.viewModel = vm

        let host = NSHostingView(rootView: TransformSpikeProgressView(viewModel: vm))
        let initialSize = NSSize(width: Self.minimumWidth, height: Self.baselineHeight)
        host.frame = NSRect(origin: .zero, size: initialSize)
        self.host = host

        let panel = TransformsSpikePanel(
            contentRect: host.frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false  // SwiftUI renders its own shadow via cardShadow.
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = host
        panel.alphaValue = 0

        positionPanel(panel, size: initialSize, animated: false)

        panel.orderFrontRegardless()
        self.panel = panel

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        // Run a relayout on the next tick so SwiftUI has a chance to
        // measure the working-state content (icon-only at start).
        scheduleRelayout()
        scheduleLabelReveal()
    }

    /// Swap the loader for a "Done" affordance, auto-dismiss after 1.2s.
    func done(message: String = "Done") {
        guard let viewModel else { return }
        labelRevealTask?.cancel()
        labelRevealTask = nil
        viewModel.phase = .done(message: message)
        scheduleRelayout()
        scheduleAutoDismiss(after: .milliseconds(1200))
    }

    /// Swap the loader for an error affordance, auto-dismiss after 4s.
    func fail(message: String) {
        if viewModel == nil {
            // Spike-grade: surface the error briefly even if show() never ran.
            show(label: "Transforms")
        }
        labelRevealTask?.cancel()
        labelRevealTask = nil
        viewModel?.phase = .failed(message: message)
        scheduleRelayout()
        scheduleAutoDismiss(after: .milliseconds(4000))
    }

    /// Tear the panel down with a brief fade. Cancel-then-restart from the
    /// coordinator goes through `show()`, not `close()`, so this is reserved
    /// for terminal dismissal.
    func close() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        labelRevealTask?.cancel()
        labelRevealTask = nil
        guard let panelRef = panel else { return }
        panel = nil
        host = nil
        viewModel = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panelRef.animator().alphaValue = 0
        }, completionHandler: {
            panelRef.orderOut(nil)
        })
    }

    /// Yield once so SwiftUI processes the observed phase change, then
    /// re-measure the hosting view and animate the panel into the right
    /// frame. Resilient to copy length: longer error strings wrap at
    /// `maximumWidth` and the panel grows vertically to fit.
    private func scheduleRelayout() {
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.relayoutPanel()
        }
    }

    private func relayoutPanel() {
        guard let panel, let host else { return }
        host.invalidateIntrinsicContentSize()
        host.layoutSubtreeIfNeeded()
        let measured = host.fittingSize
        let width: CGFloat
        let height: CGFloat
        if measured.width > 0 && measured.height > 0 {
            width = min(max(measured.width, Self.minimumWidth), Self.maximumWidth)
            height = max(measured.height, Self.baselineHeight)
        } else {
            width = Self.minimumWidth
            height = Self.baselineHeight
        }
        positionPanel(panel, size: NSSize(width: width, height: height), animated: true)
    }

    private func positionPanel(_ panel: NSPanel, size: NSSize, animated: Bool) {
        guard let screen = Self.screenForPanel() else {
            panel.setContentSize(size)
            return
        }
        let visible = screen.visibleFrame
        let x = visible.midX - size.width / 2
        let y = visible.minY + Self.bottomOffset
        let frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
        panel.setFrame(frame, display: true, animate: animated)
    }

    /// After the patience threshold, fade the label in (and trigger a panel
    /// relayout so the capsule grows from circle → oblong). Cancelled by
    /// done/fail/close — so transforms that finish quickly never show text.
    private func scheduleLabelReveal() {
        labelRevealTask?.cancel()
        labelRevealTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.labelRevealDelay)
            guard !Task.isCancelled, let self else { return }
            guard let vm = self.viewModel, case .working = vm.phase else { return }
            withAnimation(.easeInOut(duration: 0.28)) {
                vm.showLabel = true
            }
            self.scheduleRelayout()
        }
    }

    private func scheduleAutoDismiss(after delay: Duration) {
        autoDismissTask?.cancel()
        autoDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }

    private static func screenForPanel() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }
}

// MARK: - View

private struct TransformSpikeProgressView: View {
    var viewModel: TransformSpikeProgressViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Icon-only phases (.done) get equal padding so the Capsule renders
        // as a perfect circle — matches the dictation overlay's success
        // state. Phases with a label get the wider oblong-pill padding.
        let isIconOnly = currentLabel == nil
        let horizontalPadding: CGFloat = isIconOnly ? 10 : 14
        let verticalPadding: CGFloat = isIconOnly ? 10 : 11

        return HStack(spacing: 11) {
            indicator
                .frame(width: 22, height: 22)
                .id(indicatorIdentity)
                .transition(
                    .scale(scale: 0.65, anchor: .center)
                        .combined(with: .opacity)
                )

            if let label = currentLabel {
                Text(label)
                    .font(DesignSystem.Typography.meetingPillStatus)
                    .foregroundStyle(DesignSystem.Colors.meetingPillText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 280, alignment: .leading)
                    .id(labelIdentity)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .background(
            Capsule()
                .fill(DesignSystem.Colors.meetingPillBackground)
        )
        .overlay(
            Capsule()
                .strokeBorder(DesignSystem.Colors.meetingPillStroke, lineWidth: 0.5)
        )
        .cardShadow(DesignSystem.Shadows.meetingPill)
        .padding(10)  // give the SwiftUI shadow room inside the NSPanel frame
        .animation(.easeInOut(duration: 0.24), value: phaseIdentity)
    }

    @ViewBuilder
    private var indicator: some View {
        switch viewModel.phase {
        case .working:
            RhodoneaScribeLoader(tint: DesignSystem.Colors.accent, paused: reduceMotion)
        case .done:
            CheckmarkView(tint: DesignSystem.Colors.successGreen)
        case .failed:
            FailingTriangleView(tint: DesignSystem.Colors.warningAmber)
        }
    }

    /// Working starts icon-only and the label only fades in after the
    /// patience threshold (`showLabel`). Done is always icon-only — premium
    /// "the thing happened" cue. Failed always surfaces its message so the
    /// user gets the recovery hint.
    private var currentLabel: String? {
        switch viewModel.phase {
        case .working: return viewModel.showLabel ? viewModel.label : nil
        case .done: return nil
        case .failed(let message): return message
        }
    }

    private var indicatorIdentity: String {
        switch viewModel.phase {
        case .working: return "working"
        case .done: return "done"
        case .failed: return "failed"
        }
    }

    private var labelIdentity: String {
        currentLabel ?? ""
    }

    private var phaseIdentity: Int {
        switch viewModel.phase {
        case .working: return 0
        case .done: return 1
        case .failed: return 2
        }
    }
}

// MARK: - Rhodonea Scribe Loader

/// Sacred-geometry rose curve (rhodonea), squared form for smooth motion:
/// `r(θ) = sin²(5θ/2)`. Five petals radiate from the center with five-fold
/// pentagonal symmetry — the same symmetry family as the golden ratio and the
/// pentagram. Picked over a stock `ProgressView()` and over the prior generic
/// lissajous per `docs/research/transforms-design-2026-05.md` — Transforms is
/// a writing/refinement surface and earns its own motion vocabulary, distinct
/// from the dictation overlay's Merkaba (4-fold) and the meeting pill's
/// rosette (6-fold). Three modes, three symmetries.
///
/// Implementation: a faint base curve is always drawn so the full sacred
/// figure is legible, then a brighter "scribe head" traces it with a fading
/// trail. The squared form keeps `r ≥ 0` everywhere — no jumps through the
/// origin — so the head sweeps smoothly out to each petal tip and back.
/// 60Hz TimelineView drives a Canvas that walks the curve over a 3-second
/// period.
private struct RhodoneaScribeLoader: View {
    var tint: Color
    var paused: Bool = false
    var period: Double = 3.0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: paused)) { context in
            Canvas { ctx, size in
                let now = context.date.timeIntervalSinceReferenceDate
                let t = (now.truncatingRemainder(dividingBy: period)) / period
                Self.draw(in: ctx, size: size, t: t, tint: tint)
            }
        }
    }

    private static func draw(in ctx: GraphicsContext, size: CGSize, t: Double, tint: Color) {
        // Step 1 — Faint full curve so the sacred figure is always readable.
        var basePath = Path()
        let baseSamples = 240
        for i in 0...baseSamples {
            let phase = Double(i) / Double(baseSamples)
            let p = point(phase: phase, size: size)
            if i == 0 { basePath.move(to: p) } else { basePath.addLine(to: p) }
        }
        ctx.stroke(
            basePath,
            with: .color(tint.opacity(0.18)),
            style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round)
        )

        // Step 2 — Bright scribe trail behind the head, fading toward the tail.
        let segments = 42
        let trailArc = 0.30  // fraction of full period rendered as bright trail
        let baseLineWidth: CGFloat = 1.7

        for i in 0..<segments {
            let frac = Double(i) / Double(segments - 1)
            let nextFrac = Double(i + 1) / Double(segments - 1)
            let phaseA = t - frac * trailArc
            let phaseB = t - nextFrac * trailArc

            let pA = point(phase: phaseA, size: size)
            let pB = point(phase: phaseB, size: size)

            var seg = Path()
            seg.move(to: pA)
            seg.addLine(to: pB)

            let alpha = pow(1.0 - frac, 1.6)
            let width = baseLineWidth * (1.0 - frac * 0.35)

            ctx.stroke(
                seg,
                with: .color(tint.opacity(alpha)),
                style: StrokeStyle(lineWidth: width, lineCap: .round)
            )
        }

        // Step 3 — Bright head dot for a clear "now" point.
        let head = point(phase: t, size: size)
        let dotR: CGFloat = 1.7
        let dotRect = CGRect(x: head.x - dotR, y: head.y - dotR, width: dotR * 2, height: dotR * 2)
        ctx.fill(Path(ellipseIn: dotRect), with: .color(tint))
    }

    /// Squared rhodonea `r(θ) = sin²(5θ/2)` — 5 petals in θ ∈ [0, 2π], with
    /// `r ≥ 0` everywhere so the head returns smoothly to the origin between
    /// petals instead of jumping through it (which standard `cos(kθ)` roses do
    /// when `r` flips negative).
    private static func point(phase: Double, size: CGSize) -> CGPoint {
        let theta = phase * 2 * .pi
        let cx = size.width / 2
        let cy = size.height / 2
        let radius = min(size.width, size.height) * 0.44
        let s = sin(2.5 * theta)
        let r = radius * s * s
        let x = cx + r * cos(theta)
        let y = cy + r * sin(theta)
        return CGPoint(x: x, y: y)
    }
}

// MARK: - Checkmark (Done state)

/// Apple-style success checkmark — same atom the dictation overlay uses for
/// completion (`DictationOverlayView.AnimatedCheckmarkView`). Ring strokes
/// around first, then the check strokes in. Re-implemented inline rather than
/// promoted to a shared component during the spike; a follow-up should
/// extract this into `Views/Components/` so dictation, meeting, and transforms
/// share one brand atom for "the thing happened."
private struct CheckmarkView: View {
    var tint: Color
    @State private var ringTrim: CGFloat = 0
    @State private var checkTrim: CGFloat = 0

    private let lineWidth: CGFloat = 1.5

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.20), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: ringTrim)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))

            CheckmarkShape()
                .trim(from: 0, to: checkTrim)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                .padding(6)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.35)) {
                ringTrim = 1
            }
            withAnimation(.easeOut(duration: 0.25).delay(0.25)) {
                checkTrim = 1
            }
        }
    }

    private struct CheckmarkShape: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            let w = rect.width
            let h = rect.height
            path.move(to: CGPoint(x: w * 0.22, y: h * 0.52))
            path.addLine(to: CGPoint(x: w * 0.42, y: h * 0.72))
            path.addLine(to: CGPoint(x: w * 0.78, y: h * 0.28))
            return path
        }
    }
}

// MARK: - Failing Triangle (Fail state)

/// Triangle outline strokes in, then a centered bang fades up. Keeps the
/// affordance warm (amber, not red) — failures are recoverable, the user just
/// needs to retry or fix configuration.
private struct FailingTriangleView: View {
    var tint: Color
    @State private var triangleTrim: CGFloat = 0
    @State private var bangOpacity: Double = 0

    var body: some View {
        ZStack {
            TriangleShape()
                .trim(from: 0, to: triangleTrim)
                .stroke(tint, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))

            Text("!")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
                .opacity(bangOpacity)
                .offset(y: 1)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.32)) {
                triangleTrim = 1
            }
            withAnimation(.easeOut(duration: 0.20).delay(0.22)) {
                bangOpacity = 1
            }
        }
    }

    private struct TriangleShape: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            let inset: CGFloat = 1
            path.move(to: CGPoint(x: rect.midX, y: rect.minY + inset))
            path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY - inset))
            path.addLine(to: CGPoint(x: rect.minX + inset, y: rect.maxY - inset))
            path.closeSubpath()
            return path
        }
    }
}
