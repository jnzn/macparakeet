import SwiftUI

/// MacParakeet's recording mark: a little budgie that bobs gently while idle and
/// tilts its head up — "chirps" — when there's voice. Replaces the Oatmeal-era
/// `MerkabaPillIcon` (sacred-geometry flower) on the meeting pill and countdown.
///
/// Drawn as two *static* `Canvas` layers (body+tail+wing, and head+beak+cheek+eye)
/// that are rendered once and then animated purely through layer transforms
/// (`offset`, `rotationEffect`, `scaleEffect`). Core Animation interpolates those
/// on the render server, so the motion costs ~0 app CPU and never forces a
/// per-frame redraw — the same goal as the meeting-recording CPU work, applied
/// here from the start instead of retrofitted.
struct ParakeetPillIcon: View {
    /// Drives the idle bob. False (e.g. paused) renders a still bird.
    var isAnimating: Bool = false
    /// 0…1 voice loudness; tilts/scales the head when above zero.
    var audioLevel: Float = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bobUp = false

    /// Head pivot (neck) in the 48×48 design space, as a unit point.
    private static let headPivot = UnitPoint(x: 29.0 / 48.0, y: 15.0 / 48.0)

    private var active: Bool { isAnimating && !reduceMotion }
    private var level: Double {
        guard !reduceMotion else { return 0 }
        return Double(min(max(audioLevel, 0), 1))
    }

    var body: some View {
        ZStack {
            ParakeetBodyShape()
            ParakeetHeadShape()
                .scaleEffect(1 + level * 0.05, anchor: Self.headPivot)
                .rotationEffect(.degrees(-level * 11), anchor: Self.headPivot)
                .animation(.easeOut(duration: 0.12), value: level)
        }
        .offset(y: bobUp ? -1.3 : 0)
        .animation(
            active ? .easeInOut(duration: 1.7).repeatForever(autoreverses: true) : .easeOut(duration: 0.2),
            value: bobUp
        )
        .onAppear { bobUp = active }
        .onChange(of: active) { _, now in bobUp = now }
        .accessibilityHidden(true)
    }
}

// MARK: - Palette (file-scoped so the static layers can share it)

private enum BirdPalette {
    static let body = Color(red: 0.22, green: 0.82, blue: 0.49)
    static let dark = Color(red: 0.11, green: 0.60, blue: 0.33)
    static let head = Color(red: 0.68, green: 0.94, blue: 0.55)
    static let headDark = Color(red: 0.55, green: 0.85, blue: 0.42)
    static let beak = Color(red: 0.96, green: 0.68, blue: 0.22)
    static let eye = Color(red: 0.05, green: 0.16, blue: 0.10)
    static let cheek = Color(red: 0.84, green: 0.30, blue: 0.13)
}

/// Tail, body and folded wing. Coordinates are in a 48×48 design space scaled to
/// the view's frame; nothing here depends on audio, so it renders exactly once.
private struct ParakeetBodyShape: View {
    var body: some View {
        Canvas { ctx, size in
            let s = size.width / 48.0
            func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * s, y: y * s) }

            var tail = Path()
            tail.move(to: p(18, 33)); tail.addLine(to: p(20.5, 36)); tail.addLine(to: p(4, 46)); tail.addLine(to: p(2, 42.5)); tail.closeSubpath()
            ctx.fill(tail, with: .color(BirdPalette.dark))

            var tail2 = Path()
            tail2.move(to: p(19, 34)); tail2.addLine(to: p(20.5, 36)); tail2.addLine(to: p(9, 44)); tail2.addLine(to: p(7.5, 41.5)); tail2.closeSubpath()
            ctx.fill(tail2, with: .color(BirdPalette.body))

            var body = Path()
            body.move(to: p(24, 18))
            body.addCurve(to: p(33, 27), control1: p(29, 18), control2: p(33, 21))
            body.addCurve(to: p(24, 40), control1: p(33, 34), control2: p(30, 40))
            body.addCurve(to: p(15, 27), control1: p(18, 40), control2: p(15, 34))
            body.addCurve(to: p(24, 18), control1: p(15, 21), control2: p(19, 18))
            body.closeSubpath()
            ctx.fill(body, with: .color(BirdPalette.body))

            var wing = Path()
            wing.move(to: p(25, 22))
            wing.addCurve(to: p(31, 29), control1: p(30, 23), control2: p(31, 25))
            wing.addCurve(to: p(24, 36), control1: p(31, 34), control2: p(28, 36))
            wing.addCurve(to: p(25, 22), control1: p(21, 31), control2: p(22, 24))
            ctx.fill(wing, with: .color(BirdPalette.dark.opacity(0.6)))
        }
    }
}

/// Beak, head, cheek and eye. Static; the chirp tilt/scale is applied by the
/// parent as a transform so this layer is never redrawn.
private struct ParakeetHeadShape: View {
    var body: some View {
        Canvas { ctx, size in
            let s = size.width / 48.0
            func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * s, y: y * s) }
            func ellipse(_ cx: Double, _ cy: Double, _ r: Double) -> Path {
                Path(ellipseIn: CGRect(x: (cx - r) * s, y: (cy - r) * s, width: r * 2 * s, height: r * 2 * s))
            }

            var beak = Path()
            beak.move(to: p(34.5, 12))
            beak.addCurve(to: p(40, 14.5), control1: p(38, 11.5), control2: p(40, 12.5))
            beak.addCurve(to: p(35, 16.5), control1: p(40, 17), control2: p(37, 17.5))
            beak.addCurve(to: p(34.5, 12), control1: p(36, 15), control2: p(35.5, 13.5))
            ctx.fill(beak, with: .color(BirdPalette.beak))

            ctx.fill(ellipse(29, 14, 7), with: .color(BirdPalette.head))
            ctx.fill(ellipse(28, 17, 1.5), with: .color(BirdPalette.cheek.opacity(0.9)))
            ctx.fill(ellipse(31, 12.5, 1.5), with: .color(BirdPalette.eye))
        }
    }
}

/// Head-only budgie for the floating recording pill, where the full bird is too
/// small to read. Same pill footprint, but the head fills the slot. Bobs while
/// idle and tilts up ("chirps") with voice. Static `Canvas` + transform-only
/// animation, exactly like ``ParakeetPillIcon``.
struct ParakeetHeadPillIcon: View {
    var isAnimating: Bool = false
    var audioLevel: Float = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bobUp = false

    /// Neck pivot (lower-center) in the 48×48 design space, as a unit point.
    private static let neckPivot = UnitPoint(x: 22.0 / 48.0, y: 30.0 / 48.0)

    private var active: Bool { isAnimating && !reduceMotion }
    private var level: Double {
        guard !reduceMotion else { return 0 }
        return Double(min(max(audioLevel, 0), 1))
    }

    var body: some View {
        ParakeetHeadOnlyShape()
            .scaleEffect(1 + level * 0.05, anchor: Self.neckPivot)
            .rotationEffect(.degrees(-level * 10), anchor: Self.neckPivot)
            .animation(.easeOut(duration: 0.12), value: level)
            .offset(y: bobUp ? -1.4 : 0)
            .animation(
                active ? .easeInOut(duration: 1.6).repeatForever(autoreverses: true) : .easeOut(duration: 0.2),
                value: bobUp
            )
            .onAppear { bobUp = active }
            .onChange(of: active) { _, now in bobUp = now }
            .accessibilityHidden(true)
    }
}

/// Centered budgie head — head, crown shade, cheek patch, hooked beak, eye.
/// Static; the parent applies the bob/chirp transforms.
private struct ParakeetHeadOnlyShape: View {
    var body: some View {
        Canvas { ctx, size in
            let s = size.width / 48.0
            func ellipse(_ cx: Double, _ cy: Double, _ r: Double) -> Path {
                Path(ellipseIn: CGRect(x: (cx - r) * s, y: (cy - r) * s, width: r * 2 * s, height: r * 2 * s))
            }
            func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * s, y: y * s) }

            ctx.fill(ellipse(21, 24, 16.5), with: .color(BirdPalette.head))
            ctx.fill(ellipse(21, 13, 11), with: .color(BirdPalette.headDark.opacity(0.35)))
            ctx.fill(ellipse(14, 31, 4.6), with: .color(BirdPalette.cheek.opacity(0.92)))

            var beak = Path()
            beak.move(to: p(33, 19))
            beak.addCurve(to: p(45, 25), control1: p(40, 18.5), control2: p(45, 21))
            beak.addCurve(to: p(35, 30.5), control1: p(45, 29.5), control2: p(40, 31.5))
            beak.addCurve(to: p(33, 19), control1: p(35, 27), control2: p(33.5, 22))
            ctx.fill(beak, with: .color(BirdPalette.beak))

            ctx.fill(ellipse(26.5, 19.5, 3.0), with: .color(BirdPalette.eye))
            ctx.fill(ellipse(27.6, 18.4, 1.0), with: .color(.white.opacity(0.85)))
        }
    }
}
