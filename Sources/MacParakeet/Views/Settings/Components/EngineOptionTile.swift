import MacParakeetCore
import MacParakeetViewModels
import SwiftUI

/// Large selectable tile representing one speech recognition engine.
///
/// Replaces the previous segmented picker because engine choice is the single
/// most consequential decision on this page — the segmented control under-sold
/// it. A tile carries an icon, name, tagline, three strength bullets, an
/// availability footer, and (when missing) an inline Download CTA so first-run
/// setup happens in place.
///
/// Selection visuals: accent border + background tint + checkmark when active.
/// Hover: subtle border lift on unselected tiles. The full description sits
/// under `.help()` for cursor hover so the surface stays calm at rest.
struct EngineOptionTile: View {
    let icon: String
    let name: String
    let tagline: String
    let strengths: [String]
    let helpText: String
    let modelStatus: SettingsViewModel.LocalModelStatus
    let isSelected: Bool
    let isBusy: Bool
    let downloadActionLabel: String?
    let onSelect: () -> Void
    let onDownload: (() -> Void)?

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                header
                Text(tagline)
                    .font(DesignSystem.Typography.bodySmall.weight(.medium))
                    .foregroundStyle(DesignSystem.Colors.accent)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(strengths, id: \.self) { strength in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle()
                                .fill(DesignSystem.Colors.accent.opacity(0.55))
                                .frame(width: 4, height: 4)
                                .offset(y: -2)
                            Text(strength)
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 4)

                Spacer(minLength: 0)
                statusFooter
            }
            .frame(maxWidth: .infinity, minHeight: 196, alignment: .topLeading)
            .padding(DesignSystem.Spacing.md)
            .background(background)
            .overlay(border)
            .contentShape(RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius))
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .help(helpText)
        .onHover { hovering in
            withAnimation(DesignSystem.Animation.hoverTransition) {
                isHovered = hovering
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name) engine. \(tagline).")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint(helpText)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(isSelected ? DesignSystem.Colors.accent : DesignSystem.Colors.textSecondary)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isSelected
                              ? DesignSystem.Colors.accent.opacity(0.16)
                              : DesignSystem.Colors.surfaceElevated)
                )

            Text(name)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            Spacer(minLength: DesignSystem.Spacing.xs)

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.accent)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private var statusFooter: some View {
        let info = StatusInfo.from(modelStatus)
        HStack(alignment: .center, spacing: DesignSystem.Spacing.xs) {
            Circle()
                .fill(info.color)
                .frame(width: 6, height: 6)
            Text(info.label)
                .font(DesignSystem.Typography.micro.weight(.medium))
                .foregroundStyle(info.color)
            Text(info.detail)
                .font(DesignSystem.Typography.micro)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: DesignSystem.Spacing.xs)
            if modelStatus == .notDownloaded,
               let label = downloadActionLabel,
               let onDownload {
                Button(label, action: onDownload)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(DesignSystem.Colors.accent)
            }
        }
        .padding(.top, DesignSystem.Spacing.xs)
        .padding(.horizontal, 2)
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
            .fill(isSelected
                  ? DesignSystem.Colors.accent.opacity(0.08)
                  : DesignSystem.Colors.surfaceElevated.opacity(isHovered ? 0.7 : 0.4))
    }

    private var border: some View {
        let strokeColor: Color = if isSelected {
            DesignSystem.Colors.accent.opacity(0.55)
        } else if isHovered {
            DesignSystem.Colors.accent.opacity(0.25)
        } else {
            DesignSystem.Colors.border.opacity(0.7)
        }
        let lineWidth: CGFloat = isSelected ? 1.5 : 0.5
        return RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
            .strokeBorder(strokeColor, lineWidth: lineWidth)
    }

    private struct StatusInfo {
        let color: Color
        let label: String
        let detail: String

        static func from(_ status: SettingsViewModel.LocalModelStatus) -> StatusInfo {
            switch status {
            case .ready:
                return StatusInfo(
                    color: DesignSystem.Colors.successGreen,
                    label: "Ready",
                    detail: "Loaded in memory"
                )
            case .notLoaded:
                return StatusInfo(
                    color: DesignSystem.Colors.successGreen,
                    label: "Downloaded",
                    detail: "Loads on first use"
                )
            case .notDownloaded:
                return StatusInfo(
                    color: DesignSystem.Colors.warningAmber,
                    label: "Not downloaded",
                    detail: "Needed before first use"
                )
            case .repairing:
                return StatusInfo(
                    color: DesignSystem.Colors.warningAmber,
                    label: "Working",
                    detail: "Downloading model…"
                )
            case .checking:
                return StatusInfo(
                    color: DesignSystem.Colors.textSecondary,
                    label: "Checking",
                    detail: "Inspecting model state"
                )
            case .failed:
                return StatusInfo(
                    color: DesignSystem.Colors.errorRed,
                    label: "Failed",
                    detail: "Open Local Models to retry"
                )
            case .unknown:
                return StatusInfo(
                    color: DesignSystem.Colors.textSecondary,
                    label: "Unknown",
                    detail: "Status not yet checked"
                )
            }
        }
    }
}

#Preview("Engine tiles", traits: .fixedLayout(width: 760, height: 280)) {
    HStack(spacing: DesignSystem.Spacing.md) {
        EngineOptionTile(
            icon: "bolt.fill",
            name: "Parakeet",
            tagline: "Fastest · 25 European languages",
            strengths: [
                "155× realtime on Apple Silicon",
                "~2.5% word error rate",
                "Optimized for Neural Engine"
            ],
            helpText: "Best for English and other European languages. Runs on the Neural Engine for the lowest latency.",
            modelStatus: .ready,
            isSelected: true,
            isBusy: false,
            downloadActionLabel: nil,
            onSelect: {},
            onDownload: nil
        )

        EngineOptionTile(
            icon: "globe",
            name: "Whisper",
            tagline: "Multilingual · 99 languages",
            strengths: [
                "Covers Korean, Japanese, Chinese, Thai",
                "Auto language detection",
                "Whisper Large v3 Turbo (632 MB)"
            ],
            helpText: "Best for languages outside Parakeet's coverage. Adds Korean, Japanese, Chinese, Thai, Hindi, Arabic, Vietnamese, and 80+ more.",
            modelStatus: .notDownloaded,
            isSelected: false,
            isBusy: false,
            downloadActionLabel: "Download",
            onSelect: {},
            onDownload: {}
        )
    }
    .padding(DesignSystem.Spacing.lg)
    .background(DesignSystem.Colors.background)
    .preferredColorScheme(.dark)
}
