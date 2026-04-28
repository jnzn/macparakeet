import SwiftUI

/// Loading placeholder shaped like a `SettingsCard`, so the layout doesn't
/// reflow when real content lands. Used while a tab is fetching data on first
/// render (e.g. permission polling, model status checks) — preferred over a
/// generic spinner because it preserves the surface's gestalt.
struct SettingsCardSkeleton: View {
    let rowCount: Int

    init(rowCount: Int = 3) {
        self.rowCount = rowCount
    }

    @State private var phase: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                shimmerBlock(width: 30, height: 30, cornerRadius: 8)
                VStack(alignment: .leading, spacing: 6) {
                    shimmerBlock(width: 160, height: 14, cornerRadius: 4)
                    shimmerBlock(width: 220, height: 11, cornerRadius: 4)
                }
                Spacer()
            }

            VStack(spacing: DesignSystem.Spacing.md) {
                ForEach(0..<rowCount, id: \.self) { _ in
                    HStack(spacing: DesignSystem.Spacing.md) {
                        VStack(alignment: .leading, spacing: 4) {
                            shimmerBlock(width: 140, height: 12, cornerRadius: 4)
                            shimmerBlock(width: 240, height: 10, cornerRadius: 4)
                        }
                        Spacer()
                        shimmerBlock(width: 44, height: 22, cornerRadius: 11)
                    }
                }
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .fill(DesignSystem.Colors.cardBackground)
                .cardShadow(DesignSystem.Shadows.cardRest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .strokeBorder(DesignSystem.Colors.border.opacity(0.6), lineWidth: 0.5)
        )
        .accessibilityLabel("Loading settings")
        .onAppear {
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                phase = 1.0
            }
        }
    }

    @ViewBuilder
    private func shimmerBlock(width: CGFloat, height: CGFloat, cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(DesignSystem.Colors.surfaceElevated)
            .frame(width: width, height: height)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.clear,
                                DesignSystem.Colors.accent.opacity(0.08),
                                Color.clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .offset(x: (width * 2) * phase - width)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

#Preview("Light", traits: .fixedLayout(width: 560, height: 240)) {
    SettingsCardSkeleton()
        .padding()
        .background(DesignSystem.Colors.background)
        .preferredColorScheme(.light)
}

#Preview("Dark", traits: .fixedLayout(width: 560, height: 240)) {
    SettingsCardSkeleton()
        .padding()
        .background(DesignSystem.Colors.background)
        .preferredColorScheme(.dark)
}
