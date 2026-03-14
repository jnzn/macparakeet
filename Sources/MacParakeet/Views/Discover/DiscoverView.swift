import SwiftUI
import AppKit
import MacParakeetCore
import MacParakeetViewModels

struct DiscoverView: View {
    let viewModel: DiscoverViewModel

    @State private var hoveredItemId: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                ForEach(viewModel.allItems) { item in
                    discoverCard(item)
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .background(DesignSystem.Colors.background)
    }

    private func discoverCard(_ item: DiscoverItem) -> some View {
        let isHovered = hoveredItemId == item.id
        return VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                Image(systemName: iconForType(item))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.accent)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(DesignSystem.Colors.accent.opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(DesignSystem.Typography.sectionTitle)
                    Text(typeLabel(item.type))
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(item.body)
                .font(DesignSystem.Typography.body)
                .foregroundStyle(.primary)

            if let attribution = item.attribution {
                Text("— \(attribution)")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.tertiary)
                    .italic()
            }

            if item.type == .sponsored, let urlString = item.url,
               let url = URL(string: urlString),
               url.scheme == "https" {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Text("Learn More")
                            .font(DesignSystem.Typography.body)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11))
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .fill(DesignSystem.Colors.cardBackground)
                .cardShadow(isHovered ? DesignSystem.Shadows.cardHover : DesignSystem.Shadows.cardRest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .strokeBorder(
                    isHovered ? DesignSystem.Colors.accent.opacity(0.2) : DesignSystem.Colors.border.opacity(0.6),
                    lineWidth: 0.5
                )
        )
        .onHover { hovering in
            withAnimation(DesignSystem.Animation.hoverTransition) {
                hoveredItemId = hovering ? item.id : nil
            }
        }
    }

    private func iconForType(_ item: DiscoverItem) -> String {
        switch item.type {
        case .tip: return "lightbulb.fill"
        case .quote: return "quote.bubble"
        case .affirmation: return "sparkles"
        case .sponsored: return item.icon
        }
    }

    private func typeLabel(_ type: DiscoverContentType) -> String {
        switch type {
        case .tip: return "Tip"
        case .quote: return "Quote"
        case .affirmation: return "Affirmation"
        case .sponsored: return "Sponsored"
        }
    }
}
