import AppKit
import SwiftUI

/// Observable state driving `ParakeetRosetteContent`, updated imperatively by
/// `MerkabaPillIconView` (an `NSHostingView`'s rootView is normally replaced
/// wholesale on update; routing through `@Observable` instead means only the
/// properties that actually changed trigger a re-render — important for
/// `setLiveGlow`, which is driven from a ~30 fps audio-level channel).
@Observable
final class ParakeetRosetteState {
    var isAnimating: Bool = false
    var audioLevel: Float = 0
    /// True while the stop-recording "flies off" transition should be
    /// playing. `ParakeetRosetteContent` observes this and self-drives the
    /// animation; flipping it back to `false` (recording re-entry before the
    /// transition finished) snaps back to normal with no animation, so a
    /// back-to-back recording never gets stuck mid-flight.
    var isLeaving: Bool = false
}

/// Parakeet rendering for the recording pill's "rosette" state (recording /
/// paused) and its stop-recording transition. Reuses `ParakeetHeadPillIcon`'s
/// existing bob/chirp motion — already render-server-only (`.offset`/
/// `.rotationEffect`/`.scaleEffect` + `.animation`, no `TimelineView`), the
/// same ~0-app-CPU goal the original CALayer flower port had — so hosting it
/// via `NSHostingView` doesn't reintroduce the per-frame cost that port was
/// written to avoid.
///
/// Stop transition ("flies off"): a brief pre-flight head dip, then the mark
/// banks, shrinks, drifts up and away, and fades. Reduce Motion gets a quiet
/// fade instead, matching the rest of this view's reduce-motion handling.
struct ParakeetRosetteContent: View {
    var state: ParakeetRosetteState
    var reduceMotion: Bool

    @State private var dipping = false
    @State private var flying = false

    var body: some View {
        ParakeetHeadPillIcon(isAnimating: state.isAnimating, audioLevel: state.audioLevel)
            .rotationEffect(.degrees(dipping ? 10 : 0))
            .scaleEffect(flying ? 0.5 : 1)
            .offset(x: flying ? 16 : 0, y: flying ? -18 : 0)
            .rotationEffect(.degrees(flying ? -20 : 0))
            .opacity(flying ? 0 : 1)
            .onChange(of: state.isLeaving) { _, leaving in
                guard leaving else {
                    // Re-entry: a new recording started before the previous
                    // transition finished. Snap back instantly — animating
                    // back in from "flying away" would read as a glitch, not
                    // an arrival.
                    dipping = false
                    flying = false
                    return
                }
                guard !reduceMotion else {
                    withAnimation(.easeOut(duration: 0.3)) { flying = true }
                    return
                }
                withAnimation(.easeIn(duration: 0.14)) { dipping = true }
                withAnimation(.easeIn(duration: 0.5).delay(0.12)) { flying = true }
            }
    }
}

enum MerkabaPillIcon {
    /// Total duration of the "flies off" stop transition (dip + bank/shrink/
    /// fade). `MerkabaPillIconView.playCompletion` schedules its `onFinished`
    /// callback after this, matching how the old flower collapse timed its own
    /// completion. Reduce Motion uses its own shorter fade duration instead.
    static let leavingAnimationDuration: TimeInterval = 0.62
    static let leavingReducedMotionDuration: TimeInterval = 0.3
}

final class MerkabaPillIconView: NSView {
    /// Which lifecycle mark is currently shown. The parakeet (recording /
    /// paused / leaving), the Metatron's-Cube bloom (the "meeting saved"
    /// celebration + saving/loading state), and the draw-on checkmark
    /// (completed) live as layer groups (or, for the parakeet, a hosted
    /// SwiftUI view) in one view so transitions read as the *same* mark
    /// transforming in place. The counter-rotating merkaba spinner is
    /// retained for reference but no longer driven by the live flow.
    private enum Face {
        case rosette
        case spinner
        case metatron
        case checkmark
    }

    // MARK: Parakeet (recording / paused / leaving)
    private let parakeetState = ParakeetRosetteState()
    private lazy var parakeetHostView: NSHostingView<ParakeetRosetteContent> = {
        let view = NSHostingView(
            rootView: ParakeetRosetteContent(state: parakeetState, reduceMotion: false)
        )
        view.translatesAutoresizingMaskIntoConstraints = true
        return view
    }()

    // MARK: Spinner (transcribing) — two counter-rotating triangles + nexus
    private let spinnerLayer = CALayer()
    private let spinnerRingLayer = CAShapeLayer()
    private let spinnerTriCWLayer = CAShapeLayer()
    private let spinnerTriCCWLayer = CAShapeLayer()
    private let spinnerCenterLayer = CAShapeLayer()

    // MARK: Metatron's Cube (saving / "meeting saved" celebration)
    // Fruit-of-Life nodes + connecting lines that draw on and warm green → gold,
    // wrapped in a gold radial-glow halo. Doubles as the honest saving/loading
    // state: the figure holds (slow rotation) until the recording is durably
    // queued, then dissolves into the checkmark.
    private let metatronGlowLayer = CAGradientLayer()
    private let metatronLayer = CALayer()  // rotating container
    private let metatronRingsLayer = CAShapeLayer()  // 13 fruit-of-life rings (intro)
    private let metatronLinesLayer = CAShapeLayer()  // connecting lines (strokeEnd draw-on)
    private let metatronNodesLayer = CAShapeLayer()  // 13 node dots

    // MARK: Checkmark (completed) — ring draws, then check strokes in
    private let checkLayer = CALayer()
    private let checkRingTrackLayer = CAShapeLayer()
    private let checkRingLayer = CAShapeLayer()
    private let checkMarkLayer = CAShapeLayer()

    var testHook_isLeaving: Bool {
        parakeetState.isLeaving
    }

    var testHook_isAnimating: Bool {
        parakeetState.isAnimating
    }

    private var didBuildLayers = false
    private var currentShowStem = true
    private var currentAnimating = false
    private var currentAudioLevel: Float = -1
    private var currentFace: Face = .rosette
    private var completionDelayTask: Task<Void, Never>?
    private var currentReduceMotion = false

    private let successGreen = NSColor(red: 0.20, green: 0.66, blue: 0.33, alpha: 1)
    /// Metatron palette: living green during the build, ripening to sacred gold
    /// at full bloom (the "halo" peak), before resolving to the green checkmark.
    private let metatronGreen = NSColor(red: 0.42, green: 0.86, blue: 0.48, alpha: 1)
    private let metatronGold = NSColor(red: 1.0, green: 0.82, blue: 0.38, alpha: 1)

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: currentShowStem ? 30 : 35, height: currentShowStem ? 74 : 35)
    }

    override func layout() {
        super.layout()
        buildLayersIfNeeded()
        layoutLayers()
    }

    func configure(showStem: Bool) {
        guard currentShowStem != showStem else { return }
        currentShowStem = showStem
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    // MARK: - Recording / paused

    func update(isAnimating: Bool, audioLevel: Float) {
        buildLayersIfNeeded()
        setFace(.rosette)
        // Recording re-entry: cancel any in-flight "flying off" transition so
        // a back-to-back recording shows the parakeet cleanly instead of
        // stranding it mid-exit.
        parakeetState.isLeaving = false
        parakeetState.isAnimating = isAnimating
        parakeetState.audioLevel = min(1, max(0, audioLevel))
        currentAnimating = isAnimating
    }

    /// Live audio-responsive chirp, driven from a fast (~30 fps) pill-local
    /// channel rather than the 1 s state poll, so the mark tracks speech in
    /// near-real-time like the original SwiftUI pill. Routed through
    /// `@Observable` so only the audio level re-renders, not the whole view.
    func setLiveGlow(level: Float) {
        buildLayersIfNeeded()
        guard currentFace == .rosette else { return }
        parakeetState.audioLevel = min(1, max(0, level))
    }

    // MARK: - Lifecycle faces

    /// Recording stopped: the parakeet dips its head, then banks, shrinks,
    /// drifts up and away, and fades — handing off to the processing spinner.
    /// `onFinished` fires when the transition is done.
    func playCompletion(reduceMotion: Bool, onFinished: @escaping @MainActor () -> Void) {
        buildLayersIfNeeded()
        setFace(.rosette)
        currentAnimating = false
        currentReduceMotion = reduceMotion
        parakeetHostView.rootView = ParakeetRosetteContent(state: parakeetState, reduceMotion: reduceMotion)
        parakeetState.isAnimating = false
        parakeetState.isLeaving = true

        let duration = reduceMotion
            ? MerkabaPillIcon.leavingReducedMotionDuration
            : MerkabaPillIcon.leavingAnimationDuration
        scheduleCompletion(after: duration, onFinished)
    }

    /// Fire the collapse-finished callback after `delay`, on the main actor.
    /// (A `Task` instead of `DispatchQueue.asyncAfter(execute:)` so the
    /// `@MainActor` callback isn't forced through a `@Sendable` parameter —
    /// Swift 6 language-mode clean.)
    private func scheduleCompletion(after delay: Double, _ onFinished: @escaping @MainActor () -> Void) {
        completionDelayTask?.cancel()
        completionDelayTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.completionDelayTask = nil
            onFinished()
        }
    }

    /// Processing state: two counter-rotating triangles (the merkaba) with a
    /// pulsing nexus. CA port of `SpinnerRingView`.
    func showSpinner(animated: Bool) {
        buildLayersIfNeeded()
        setFace(.spinner)
        stopAnimations()

        guard animated else { return }  // static merkaba (Star of David) for reduce-motion

        if spinnerTriCWLayer.animation(forKey: "spin") == nil {
            spinnerTriCWLayer.add(spinAnimation(to: CGFloat.pi * 2, duration: 3), forKey: "spin")
            spinnerTriCCWLayer.add(spinAnimation(to: -CGFloat.pi * 2, duration: 3), forKey: "spin")
            spinnerCenterLayer.add(pulseAnimation(from: 0.3, to: 0.9, duration: 1.4), forKey: "pulse")
        }
    }

    /// Saving / "meeting saved" celebration: the Metatron's Cube blooms — nodes
    /// fade in, the cube's lines draw on while the palette warms green → gold and
    /// a gold halo swells, then the figure holds with a slow rotation. CA-driven,
    /// so the loading hold costs ~0 app CPU. The hold loops until the recording is
    /// durably queued, when `showCheckmark` dissolves it into the check.
    func showMetatron(animated: Bool) {
        buildLayersIfNeeded()
        stopAnimations()
        setFace(.metatron)

        // Clean pre-bloom baseline so the bloom replays deterministically.
        for sub in [metatronRingsLayer, metatronLinesLayer, metatronNodesLayer] { sub.removeAllAnimations() }
        metatronLayer.removeAllAnimations()
        metatronGlowLayer.removeAllAnimations()
        metatronLayer.opacity = 1
        metatronLayer.transform = CATransform3DIdentity
        metatronNodesLayer.fillColor = metatronGreen.cgColor
        metatronLinesLayer.strokeColor = metatronGreen.cgColor

        guard animated else {
            // Reduce Motion: present the fully-bloomed gold figure statically.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            metatronRingsLayer.opacity = 0
            metatronNodesLayer.opacity = 1
            metatronNodesLayer.fillColor = metatronGold.cgColor
            metatronLinesLayer.strokeEnd = 1
            metatronLinesLayer.strokeColor = metatronGold.cgColor
            metatronGlowLayer.opacity = 1
            CATransaction.commit()
            return
        }

        let now = CACurrentMediaTime()

        // Phase A (0–0.45s): nodes + intro rings fade in. Green.
        metatronNodesLayer.add(
            rampAnimation(keyPath: "opacity", from: 0, to: 1, duration: 0.45, timing: .easeOut), forKey: "nodesIn")
        metatronNodesLayer.opacity = 1
        let ringsIn = CAKeyframeAnimation(keyPath: "opacity")
        ringsIn.values = [0, 0.45, 0]  // bloom in, then fade as the cube builds
        ringsIn.keyTimes = [0, 0.28, 0.9]
        ringsIn.duration = 1.2
        ringsIn.fillMode = .forwards
        ringsIn.isRemovedOnCompletion = false
        ringsIn.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        metatronRingsLayer.add(ringsIn, forKey: "ringsIn")
        metatronRingsLayer.opacity = 0

        // Phase B (0.35–1.15s): lines draw on; palette warms green → gold; halo swells.
        let draw = rampAnimation(keyPath: "strokeEnd", from: 0, to: 1, duration: 0.8, timing: .easeInEaseOut)
        draw.beginTime = now + 0.35
        draw.fillMode = .both
        metatronLinesLayer.add(draw, forKey: "linesDraw")
        metatronLinesLayer.strokeEnd = 1

        metatronLinesLayer.add(
            colorRamp(keyPath: "strokeColor", from: metatronGreen, to: metatronGold, duration: 0.8, begin: now + 0.45),
            forKey: "linesWarm")
        metatronLinesLayer.strokeColor = metatronGold.cgColor
        metatronNodesLayer.add(
            colorRamp(keyPath: "fillColor", from: metatronGreen, to: metatronGold, duration: 0.8, begin: now + 0.45),
            forKey: "nodesWarm")
        metatronNodesLayer.fillColor = metatronGold.cgColor

        let glowIn = rampAnimation(keyPath: "opacity", from: 0, to: 1, duration: 0.8, timing: .easeOut)
        glowIn.beginTime = now + 0.45
        glowIn.fillMode = .both
        metatronGlowLayer.add(glowIn, forKey: "glowIn")
        metatronGlowLayer.opacity = 1

        // Phase C (from ~1.2s): slow rotation hold — the living "saving" state
        // until the recording is durably queued and the check takes over.
        let spin = spinAnimation(to: CGFloat.pi * 2, duration: 26)
        metatronLayer.add(spin, forKey: "metatronSpin")
    }

    private func colorRamp(keyPath: String, from: NSColor, to: NSColor, duration: CFTimeInterval, begin: CFTimeInterval)
        -> CABasicAnimation
    {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from.cgColor
        animation.toValue = to.cgColor
        animation.duration = duration
        animation.beginTime = begin
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        animation.timingFunction = CAMediaTimingFunction(name: .easeIn)
        return animation
    }

    /// Completed state: a success ring draws on, then the checkmark strokes in.
    /// CA port of `MeetingCompletionCheckmarkView` (Apple-Pay style). When the
    /// Metatron bloom is on screen it first dissolves the cube (fade + glow out)
    /// so the check reads as the geometry *resolving* into "saved".
    func showCheckmark(animated: Bool) {
        buildLayersIfNeeded()

        guard animated else {
            stopAnimations()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            setFace(.checkmark)
            checkRingLayer.strokeEnd = 1
            checkMarkLayer.strokeEnd = 1
            CATransaction.commit()
            return
        }

        if currentFace == .metatron {
            let from = CGFloat(metatronLayer.presentation()?.opacity ?? 1)
            metatronLayer.add(
                rampAnimation(keyPath: "opacity", from: from, to: 0, duration: 0.35, timing: .easeInEaseOut),
                forKey: "metatronDissolve")
            metatronLayer.opacity = 0
            let glowFrom = CGFloat(metatronGlowLayer.presentation()?.opacity ?? 1)
            metatronGlowLayer.add(
                rampAnimation(keyPath: "opacity", from: glowFrom, to: 0, duration: 0.35, timing: .easeOut),
                forKey: "metatronGlowOut")
            metatronGlowLayer.opacity = 0
            // Defer the check until the dissolve completes — but only if the
            // mark is still the Metatron. A back-to-back recording starting
            // during this 0.34 s window flips the face back to the rosette, and
            // we must not stamp a checkmark over the new recording.
            scheduleCompletion(after: 0.34) { [weak self] in
                guard let self, self.currentFace == .metatron else { return }
                self.drawCheckmark()
            }
        } else {
            drawCheckmark()
        }
    }

    private func drawCheckmark() {
        stopAnimations()
        setFace(.checkmark)

        let ring = rampAnimation(keyPath: "strokeEnd", from: 0, to: 1, duration: 0.35, timing: .easeOut)
        checkRingLayer.add(ring, forKey: "ringDraw")

        let check = rampAnimation(keyPath: "strokeEnd", from: 0, to: 1, duration: 0.25, timing: .easeOut)
        check.beginTime = CACurrentMediaTime() + 0.25
        check.fillMode = .both
        checkMarkLayer.add(check, forKey: "checkDraw")
    }

    private func setFace(_ face: Face) {
        guard currentFace != face else { return }
        if currentFace == .metatron, face != .metatron {
            completionDelayTask?.cancel()
            completionDelayTask = nil
        }
        currentFace = face
        if face != .checkmark {
            checkRingLayer.strokeEnd = 0
            checkMarkLayer.strokeEnd = 0
        }
        applyVisibility()
    }

    /// Single source of truth for layer/view visibility, driven by the
    /// current face. Re-applied on every layout.
    private func applyVisibility() {
        parakeetHostView.isHidden = (currentFace != .rosette)
        spinnerLayer.isHidden = (currentFace != .spinner)
        let metatron = (currentFace == .metatron)
        metatronLayer.isHidden = !metatron
        metatronGlowLayer.isHidden = !metatron
        checkLayer.isHidden = (currentFace != .checkmark)
    }

    // MARK: - Layer construction

    private func buildLayersIfNeeded() {
        guard !didBuildLayers, let rootLayer = layer else { return }
        didBuildLayers = true

        rootLayer.masksToBounds = false
        addSubview(parakeetHostView)

        buildSpinnerLayers(in: rootLayer)
        buildMetatronLayers(in: rootLayer)
        buildCheckmarkLayers(in: rootLayer)
    }

    private func buildMetatronLayers(in root: CALayer) {
        // Gold radial halo behind the figure — bleeds out into the dark circle.
        // Sits in root (not the rotating container) so it stays a steady glow.
        metatronGlowLayer.isHidden = true
        metatronGlowLayer.type = .radial
        metatronGlowLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        metatronGlowLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
        metatronGlowLayer.colors = [
            metatronGold.withAlphaComponent(0.34).cgColor,
            metatronGold.withAlphaComponent(0.0).cgColor,
        ]
        metatronGlowLayer.locations = [0, 1]
        metatronGlowLayer.opacity = 0
        root.addSublayer(metatronGlowLayer)

        metatronLayer.isHidden = true
        metatronRingsLayer.fillColor = NSColor.clear.cgColor
        metatronRingsLayer.strokeColor = metatronGreen.withAlphaComponent(0.45).cgColor
        metatronRingsLayer.lineWidth = 0.5
        metatronRingsLayer.opacity = 0
        metatronLinesLayer.fillColor = NSColor.clear.cgColor
        metatronLinesLayer.strokeColor = metatronGreen.cgColor
        metatronLinesLayer.lineWidth = 0.8
        metatronLinesLayer.lineCap = .round
        metatronLinesLayer.lineJoin = .round
        metatronLinesLayer.strokeEnd = 0
        metatronNodesLayer.fillColor = metatronGreen.cgColor
        metatronNodesLayer.strokeColor = nil
        metatronNodesLayer.opacity = 0
        metatronLayer.addSublayer(metatronRingsLayer)
        metatronLayer.addSublayer(metatronLinesLayer)
        metatronLayer.addSublayer(metatronNodesLayer)
        root.addSublayer(metatronLayer)
    }

    private func buildSpinnerLayers(in root: CALayer) {
        spinnerLayer.isHidden = true
        for tri in [spinnerTriCWLayer, spinnerTriCCWLayer] {
            tri.fillColor = NSColor.clear.cgColor
            tri.strokeColor = NSColor.white.withAlphaComponent(0.45).cgColor
            tri.lineWidth = 0.8
            tri.lineJoin = .round
        }
        spinnerTriCCWLayer.strokeColor = NSColor.white.withAlphaComponent(0.3).cgColor
        spinnerRingLayer.fillColor = NSColor.clear.cgColor
        spinnerRingLayer.strokeColor = NSColor.white.withAlphaComponent(0.06).cgColor
        spinnerRingLayer.lineWidth = 0.5
        spinnerCenterLayer.fillColor = NSColor.white.withAlphaComponent(0.7).cgColor
        spinnerLayer.addSublayer(spinnerRingLayer)
        spinnerLayer.addSublayer(spinnerTriCWLayer)
        spinnerLayer.addSublayer(spinnerTriCCWLayer)
        spinnerLayer.addSublayer(spinnerCenterLayer)
        root.addSublayer(spinnerLayer)
    }

    private func buildCheckmarkLayers(in root: CALayer) {
        checkLayer.isHidden = true
        checkRingTrackLayer.fillColor = NSColor.clear.cgColor
        checkRingTrackLayer.strokeColor = successGreen.withAlphaComponent(0.2).cgColor
        checkRingTrackLayer.lineWidth = 1.5
        checkRingLayer.fillColor = NSColor.clear.cgColor
        checkRingLayer.strokeColor = successGreen.cgColor
        checkRingLayer.lineWidth = 1.5
        checkRingLayer.lineCap = .round
        checkRingLayer.strokeEnd = 0
        checkMarkLayer.fillColor = NSColor.clear.cgColor
        checkMarkLayer.strokeColor = successGreen.cgColor
        checkMarkLayer.lineWidth = 1.5
        checkMarkLayer.lineCap = .round
        checkMarkLayer.lineJoin = .round
        checkMarkLayer.strokeEnd = 0
        checkLayer.addSublayer(checkRingTrackLayer)
        checkLayer.addSublayer(checkRingLayer)
        checkLayer.addSublayer(checkMarkLayer)
        root.addSublayer(checkLayer)
    }

    // MARK: - Layout

    private func layoutLayers() {
        let markSize = activeMarkSize
        let headY: CGFloat = currentShowStem ? 6 : 0

        // The parakeet occupies exactly where the old flower head sat; when
        // `showStem` is true the extra space below (formerly stem + leaves)
        // is simply left empty — matching the already-shipped in-app pill
        // (`MeetingRecordingPillView`), which shows the head alone with no
        // stem concept at all.
        parakeetHostView.frame = CGRect(x: 0, y: headY, width: markSize, height: markSize)

        layoutSpinnerAndCheck(headY: headY, size: markSize)
        applyVisibility()
    }

    private var activeMarkSize: CGFloat {
        guard !currentShowStem else { return 30 }
        let proposed = min(bounds.width, bounds.height)
        return proposed > 0 ? proposed : 35
    }

    private func layoutSpinnerAndCheck(headY: CGFloat, size: CGFloat) {
        // Both containers sit exactly where the flower head is, so the
        // transcribing/completed marks read as the rosette transforming in
        // place. Sublayer coordinates below are relative to the head container
        // bounds, not the y-offset head rect.
        let headRect = CGRect(x: 0, y: headY, width: size, height: size)
        spinnerLayer.frame = headRect
        checkLayer.frame = headRect

        let local = CGRect(x: 0, y: 0, width: size, height: size)
        let center = CGPoint(x: size / 2, y: size / 2)
        let scale = size / 30
        let radius: CGFloat = 11 * scale

        spinnerRingLayer.frame = local
        spinnerRingLayer.lineWidth = 0.5 * scale
        spinnerRingLayer.path = CGPath(
            ellipseIn: CGRect(
                x: center.x - 13 * scale,
                y: center.y - 13 * scale,
                width: 26 * scale,
                height: 26 * scale
            ),
            transform: nil
        )
        // bounds + centered position so transform.rotation.z spins about the
        // centroid (an unsized layer would orbit its origin instead).
        // The second triangle's path is offset 60° so the pair forms a Star of
        // David at rest (the reduce-motion / settled face); when animated they
        // counter-rotate from there into the spinning merkaba.
        spinnerTriCWLayer.lineWidth = 0.8 * scale
        spinnerTriCWLayer.bounds = local
        spinnerTriCWLayer.position = center
        spinnerTriCWLayer.path = trianglePath(center: center, radius: radius, rotation: 0)
        spinnerTriCCWLayer.lineWidth = 0.8 * scale
        spinnerTriCCWLayer.bounds = local
        spinnerTriCCWLayer.position = center
        spinnerTriCCWLayer.path = trianglePath(center: center, radius: radius, rotation: .pi / 3)
        spinnerCenterLayer.frame = CGRect(
            x: center.x - 1.5 * scale,
            y: center.y - 1.5 * scale,
            width: 3 * scale,
            height: 3 * scale
        )
        spinnerCenterLayer.path = CGPath(
            ellipseIn: CGRect(x: 0, y: 0, width: 3 * scale, height: 3 * scale), transform: nil)

        // Checkmark ring + tick, inset to match the old 26pt frame with padding.
        for layer in [checkRingTrackLayer, checkRingLayer, checkMarkLayer] { layer.frame = local }
        checkRingTrackLayer.lineWidth = 1.5 * scale
        checkRingLayer.lineWidth = 1.5 * scale
        checkMarkLayer.lineWidth = 1.5 * scale
        checkRingTrackLayer.path = CGPath(
            ellipseIn: CGRect(x: 2 * scale, y: 2 * scale, width: 26 * scale, height: 26 * scale),
            transform: nil
        )
        // Sweep the ring from the top like the SwiftUI rotationEffect(-90°).
        let ringPath = CGMutablePath()
        ringPath.addArc(
            center: center, radius: 13 * scale, startAngle: -.pi / 2, endAngle: -.pi / 2 + .pi * 2, clockwise: false)
        checkRingLayer.path = ringPath
        checkMarkLayer.path = checkmarkPath(in: local.size)

        // Metatron's Cube fills the head; the container rotates about its centre
        // (frame == head rect → centred position, default anchor). The glow halo
        // sits in root and bleeds slightly past the figure into the dark circle.
        metatronLayer.frame = headRect
        let geo = metatronGeometry(size: size)
        for shape in [metatronRingsLayer, metatronLinesLayer, metatronNodesLayer] { shape.frame = local }
        metatronRingsLayer.path = geo.rings
        metatronRingsLayer.lineWidth = max(0.4, 0.5 * scale)
        metatronLinesLayer.path = geo.lines
        metatronLinesLayer.lineWidth = max(0.7, 0.85 * scale)
        metatronNodesLayer.path = geo.nodes
        let glowSize = size * 1.35  // halo bleeds past the figure but stays inside the circle
        metatronGlowLayer.frame = CGRect(
            x: headRect.midX - glowSize / 2,
            y: headRect.midY - glowSize / 2,
            width: glowSize,
            height: glowSize
        )
    }

    /// Fruit-of-Life node geometry → Metatron's Cube, centred in a `size` square.
    /// Returns three combined paths: the 13 intro rings, the connecting lines
    /// (ordered centre-out so `strokeEnd` reads as construction), and the node
    /// dots. Lines drawn: the three long diagonals, the outer hexagram (Star of
    /// David), the outer hexagon, and the inner hexagon — the iconic core, with
    /// the busiest inner-hexagram lines omitted for small-size legibility.
    private func metatronGeometry(size: CGFloat) -> (rings: CGPath, lines: CGPath, nodes: CGPath) {
        let c = CGPoint(x: size / 2, y: size / 2)
        let r = size / 2
        let d = r * 0.40  // inner-ring distance (outer = 0.80r)
        let nodeRingR = d * 0.5  // touching fruit-of-life circles
        let dotR = r * 0.05
        func pt(_ dist: CGFloat, _ i: Int) -> CGPoint {
            let a = CGFloat(i) * .pi / 3 - .pi / 2  // pointy-top hexagon
            return CGPoint(x: c.x + dist * cos(a), y: c.y + dist * sin(a))
        }
        let inner = (0..<6).map { pt(d, $0) }
        let outer = (0..<6).map { pt(2 * d, $0) }
        let all = [c] + inner + outer

        let rings = CGMutablePath()
        for p in all {
            rings.addEllipse(
                in: CGRect(x: p.x - nodeRingR, y: p.y - nodeRingR, width: 2 * nodeRingR, height: 2 * nodeRingR))
        }

        let nodes = CGMutablePath()
        for p in all { nodes.addEllipse(in: CGRect(x: p.x - dotR, y: p.y - dotR, width: 2 * dotR, height: 2 * dotR)) }

        let lines = CGMutablePath()
        func seg(_ a: CGPoint, _ b: CGPoint) { lines.move(to: a); lines.addLine(to: b) }
        for i in 0..<3 { seg(outer[i], outer[i + 3]) }  // long diagonals
        for i in 0..<6 { seg(outer[i], outer[(i + 2) % 6]) }  // outer hexagram
        for i in 0..<6 { seg(outer[i], outer[(i + 1) % 6]) }  // outer hexagon
        for i in 0..<6 { seg(inner[i], inner[(i + 1) % 6]) }  // inner hexagon
        return (rings, lines, nodes)
    }

    // MARK: - Paths

    private func trianglePath(center: CGPoint, radius: CGFloat, rotation: CGFloat) -> CGPath {
        let path = CGMutablePath()
        for i in 0..<3 {
            let angle = (CGFloat(i) * 120 - 90) * .pi / 180 + rotation
            let point = CGPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    private func checkmarkPath(in size: CGSize) -> CGPath {
        // Mirror of CheckmarkShape, proportional to the old 30pt frame's padding.
        let inset: CGFloat = size.width * (7 / 30)
        let w = size.width - inset * 2
        let h = size.height - inset * 2
        let path = CGMutablePath()
        path.move(to: CGPoint(x: inset + w * 0.22, y: inset + h * 0.52))
        path.addLine(to: CGPoint(x: inset + w * 0.42, y: inset + h * 0.72))
        path.addLine(to: CGPoint(x: inset + w * 0.78, y: inset + h * 0.28))
        return path
    }

    // MARK: - Animation builders

    private func stopAnimations() {
        spinnerTriCWLayer.removeAnimation(forKey: "spin")
        spinnerTriCCWLayer.removeAnimation(forKey: "spin")
        spinnerCenterLayer.removeAnimation(forKey: "pulse")
        completionDelayTask?.cancel()
        completionDelayTask = nil
        metatronLayer.removeAllAnimations()
        metatronRingsLayer.removeAllAnimations()
        metatronLinesLayer.removeAllAnimations()
        metatronNodesLayer.removeAllAnimations()
        metatronGlowLayer.removeAllAnimations()
    }

    private func spinAnimation(to value: CGFloat, duration: CFTimeInterval) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = 0
        animation.toValue = value
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        return animation
    }

    private func pulseAnimation(from: Float, to: Float, duration: CFTimeInterval) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return animation
    }

    private func rampAnimation(
        keyPath: String, from: CGFloat, to: CGFloat, duration: CFTimeInterval, timing: CAMediaTimingFunctionName
    ) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        animation.timingFunction = CAMediaTimingFunction(name: timing)
        return animation
    }
}
