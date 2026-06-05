import SwiftUI

/// Sacred-geometry rose-curve loader used for compact "work is in flight"
/// states. It has no intrinsic size; callers keep ownership of the icon box
/// with an outer `.frame(width:height:)`.
struct RhodoneaScribeLoader: View {
    var tint: Color
    var paused: Bool = false
    var period: Double = 3.0
    var accessibilityLabel: String = "Working"

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: paused)) { context in
            Canvas { ctx, size in
                let now = context.date.timeIntervalSinceReferenceDate
                let t = (now.truncatingRemainder(dividingBy: period)) / period
                Self.draw(in: ctx, size: size, t: t, tint: tint)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
    }

    /// Sample count along the static base curve.
    static let baseSamples = 240

    /// The full rose curve sampled once in unit space (centered on the origin,
    /// lobes reaching radius 1). The base curve is identical every frame — only
    /// its on-screen scale changes — so precomputing it avoids re-running ~240
    /// sin/cos evaluations per frame at 60 Hz (audit PDX-016). Per frame we only
    /// scale these points to `size`; the animated trail still samples
    /// `point(phase:size:)` because its phase tracks the animation clock `t`.
    static let baseUnitPoints: [CGPoint] = (0...baseSamples).map { index in
        unitPoint(phase: Double(index) / Double(baseSamples))
    }

    private static func draw(in ctx: GraphicsContext, size: CGSize, t: Double, tint: Color) {
        let centerX = size.width / 2
        let centerY = size.height / 2
        let radius = min(size.width, size.height) * 0.44

        var basePath = Path()
        for (index, unit) in baseUnitPoints.enumerated() {
            let p = CGPoint(x: centerX + radius * unit.x, y: centerY + radius * unit.y)
            if index == 0 {
                basePath.move(to: p)
            } else {
                basePath.addLine(to: p)
            }
        }
        ctx.stroke(
            basePath,
            with: .color(tint.opacity(0.18)),
            style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round)
        )

        let segments = 42
        let trailArc = 0.30
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

        let head = point(phase: t, size: size)
        let dotR: CGFloat = 1.7
        let dotRect = CGRect(x: head.x - dotR, y: head.y - dotR, width: dotR * 2, height: dotR * 2)
        ctx.fill(Path(ellipseIn: dotRect), with: .color(tint))
    }

    /// A point on the rose curve in unit space: centered on the origin with the
    /// lobes reaching radius 1. `point(phase:size:)` maps this onto the canvas.
    static func unitPoint(phase: Double) -> CGPoint {
        let theta = phase * 2 * .pi
        let s = sin(2.5 * theta)
        let r = s * s
        return CGPoint(x: r * cos(theta), y: r * sin(theta))
    }

    /// The on-screen point for `phase`, scaling `unitPoint` into `size`. Used for
    /// the animated trail + head, whose phase tracks the clock and so cannot be
    /// precomputed like the static base curve.
    static func point(phase: Double, size: CGSize) -> CGPoint {
        let radius = min(size.width, size.height) * 0.44
        let unit = unitPoint(phase: phase)
        return CGPoint(x: size.width / 2 + radius * unit.x, y: size.height / 2 + radius * unit.y)
    }
}
