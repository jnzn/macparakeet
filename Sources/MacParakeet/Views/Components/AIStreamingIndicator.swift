import SwiftUI

/// A premium streaming indicator that shows animated dots with a warm shimmer.
/// Used during LLM summary generation and chat response streaming.
struct AIStreamingIndicator: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(DesignSystem.Colors.accent)
                    .frame(width: 5, height: 5)
                    .opacity(dotOpacity(for: index))
                    .scaleEffect(dotScale(for: index))
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }

    private func dotOpacity(for index: Int) -> Double {
        let offset = Double(index) * 0.25
        let value = sin((phase + offset) * .pi * 2)
        return 0.3 + 0.7 * max(0, value)
    }

    private func dotScale(for index: Int) -> Double {
        let offset = Double(index) * 0.25
        let value = sin((phase + offset) * .pi * 2)
        return 0.7 + 0.3 * max(0, value)
    }
}

/// A shimmer overlay for skeleton loading states.
/// Draws a subtle gradient that sweeps across the content.
struct ShimmerEffect: ViewModifier {
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: max(0, phase - 0.3)),
                        .init(color: DesignSystem.Colors.accent.opacity(0.08), location: phase),
                        .init(color: .clear, location: min(1, phase + 0.3)),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .clipped()
            )
            .onAppear {
                withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: false)) {
                    phase = 2
                }
            }
    }
}

extension View {
    func shimmer() -> some View {
        modifier(ShimmerEffect())
    }
}

/// Skeleton placeholder lines for the summary loading state.
/// Shows 3-4 animated bars that simulate incoming text.
struct SummarySkeletonView: View {
    @State private var isAnimating = false

    private let lineWidths: [CGFloat] = [1.0, 0.85, 0.92, 0.6]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header area with AI indicator
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DesignSystem.Colors.accent)
                    .opacity(isAnimating ? 0.4 : 1.0)

                Text("Generating summary")
                    .font(DesignSystem.Typography.bodySmall.weight(.medium))
                    .foregroundStyle(.secondary)

                AIStreamingIndicator()
            }

            // Skeleton lines
            ForEach(Array(lineWidths.enumerated()), id: \.offset) { index, width in
                skeletonLine(widthFraction: width, delay: Double(index) * 0.1)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
        }
    }

    private func skeletonLine(widthFraction: CGFloat, delay: Double) -> some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: 4)
                .fill(DesignSystem.Colors.accent.opacity(isAnimating ? 0.06 : 0.12))
                .frame(width: proxy.size.width * widthFraction, height: 12)
        }
        .frame(height: 12)
        .shimmer()
    }
}

/// Placeholder view for empty chat assistant messages during streaming.
struct ChatStreamingPlaceholder: View {
    var body: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "sparkles")
                .font(.system(size: 11))
                .foregroundStyle(DesignSystem.Colors.accent.opacity(0.6))
            AIStreamingIndicator()
        }
    }
}
