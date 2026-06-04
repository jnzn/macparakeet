import SwiftUI

/// Voice-memo recording mark: the classic record dot, but its halo now reacts to
/// your voice instead of pulsing on a fixed timer. A steady "sonar" ring emits
/// outward (render-server `repeatForever`, ~0 app CPU), and both the ring's
/// brightness and the dot's glow scale with the live mic level — louder voice,
/// brighter pulse. Stays `recordingRed` so it reads as a distinct mode from the
/// green meeting parakeet. Honors reduce-motion (still dot, glow-only reaction).
struct RecordDotPillIcon: View {
    /// 0…1 mic loudness.
    var audioLevel: Float = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var emit = false

    private var level: Double { Double(min(max(audioLevel, 0), 1)) }
    private let red = DesignSystem.Colors.recordingRed

    var body: some View {
        ZStack {
            // Outward-emitting ring (fixed geometry loop), brightness tracks voice.
            Circle()
                .fill(red)
                .frame(width: 11, height: 11)
                .scaleEffect(emit ? 2.1 : 1.0)
                .opacity(emit ? 0.0 : 0.5)
                .animation(
                    reduceMotion ? .default : .easeOut(duration: 1.2).repeatForever(autoreverses: false),
                    value: emit
                )
                .opacity(0.3 + level * 0.7)
                .animation(.easeOut(duration: 0.15), value: level)

            // Solid dot — glow swells with voice.
            Circle()
                .fill(red)
                .frame(width: 10, height: 10)
                .shadow(color: red.opacity(0.5 + level * 0.4), radius: 3 + level * 5)
                .animation(.easeOut(duration: 0.15), value: level)
        }
        .frame(width: 22, height: 22)
        .onAppear { if !reduceMotion { emit = true } }
        .accessibilityHidden(true)
    }
}
