import SwiftUI

struct DualAudioLevelView: View {
    let micLevel: Float
    let systemLevel: Float

    private let barCount = 5
    private static let barWidth: CGFloat = 3
    private static let barHeight: CGFloat = 12
    private static let barSpacing: CGFloat = 1.5
    private static let barCornerRadius: CGFloat = 1
    private static let minimumBarScale: CGFloat = 0.15
    private static let thresholdSpread: CGFloat = 0.5
    private static let scaleMultiplier: CGFloat = 1.5
    private static let colorThreshold: CGFloat = 0.7

    var body: some View {
        HStack(spacing: 10) {
            meter(systemName: "mic.fill", level: micLevel)
            meter(systemName: "speaker.wave.2.fill", level: systemLevel)
        }
    }

    private func meter(systemName: String, level: Float) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemName)
                .font(DesignSystem.Typography.micro)
                .foregroundStyle(.white.opacity(0.45))

            HStack(spacing: Self.barSpacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: Self.barCornerRadius)
                        .fill(barColor(for: index, level: level))
                        .frame(width: Self.barWidth, height: Self.barHeight)
                        .scaleEffect(y: barScale(for: index, level: level), anchor: .bottom)
                        .animation(.easeInOut(duration: 0.1), value: level)
                }
            }
        }
    }

    private func barScale(for index: Int, level: Float) -> CGFloat {
        let threshold = CGFloat(index) / CGFloat(barCount)
        let clampedLevel = CGFloat(max(0, min(1, level)))
        return max(Self.minimumBarScale, min(1.0, (clampedLevel - threshold * Self.thresholdSpread) * Self.scaleMultiplier))
    }

    private func barColor(for index: Int, level: Float) -> Color {
        let threshold = CGFloat(index) / CGFloat(barCount)
        let active = CGFloat(level) > threshold * Self.colorThreshold
        return active ? DesignSystem.Colors.accent : Color.white.opacity(0.18)
    }
}
