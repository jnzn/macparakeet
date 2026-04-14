import SwiftUI

/// 14-bar scrolling waveform. Each bar holds a past sample of the audio level,
/// so the shape genuinely scrolls with speech instead of pulsing uniformly as
/// a single scalar does. New samples enter on the right; older samples decay
/// as they shift left.
struct WaveformView: View {
    let audioLevel: Float
    var barCount: Int = 14
    @State private var history: [Float] = Array(repeating: 0, count: 14)

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white.opacity(0.8))
                    .frame(width: 2, height: barHeight(forIndex: index))
                    .animation(.easeOut(duration: 0.08), value: history[safe: index] ?? 0)
            }
        }
        .frame(height: 20)
        .onChange(of: audioLevel) { _, newLevel in
            shiftHistory(newLevel: newLevel)
        }
        .onAppear {
            if history.count != barCount {
                history = Array(repeating: 0, count: barCount)
            }
        }
    }

    private func shiftHistory(newLevel: Float) {
        var next = history
        if next.count != barCount {
            next = Array(repeating: 0, count: barCount)
        }
        // Shift left: drop oldest, append newest on the right
        next.removeFirst()
        next.append(newLevel)
        history = next
    }

    private func barHeight(forIndex index: Int) -> CGFloat {
        let sample = (history[safe: index] ?? 0)
        // Amplify — raw mic levels are typically 0.0-0.3 for speech.
        let boosted = min(sample * 3.5, 1.0)
        let baseHeight: Float = 3.0
        let maxAdditional: Float = 17.0
        let height = baseHeight + maxAdditional * boosted
        return CGFloat(max(baseHeight, min(height, 20)))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

#Preview {
    VStack(spacing: 20) {
        WaveformView(audioLevel: 0.0)
        WaveformView(audioLevel: 0.3)
        WaveformView(audioLevel: 0.6)
        WaveformView(audioLevel: 1.0)
    }
    .padding()
    .background(Color.black)
}
