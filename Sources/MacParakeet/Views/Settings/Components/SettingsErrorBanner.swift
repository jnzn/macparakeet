import SwiftUI

/// Inline error banner used inside cards to surface a recoverable failure
/// (e.g. "Whisper model download failed") with a retry CTA. Sits above or
/// below the affected row; not modal — destructive errors should use the
/// standard `.alert` instead.
struct SettingsErrorBanner: View {
    let message: String
    let retryLabel: String?
    let onRetry: (() -> Void)?

    init(
        message: String,
        retryLabel: String? = "Retry",
        onRetry: (() -> Void)? = nil
    ) {
        self.message = message
        self.retryLabel = retryLabel
        self.onRetry = onRetry
    }

    var body: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DesignSystem.Colors.errorRed)
                .accessibilityHidden(true)

            Text(message)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let retryLabel, let onRetry {
                Button(retryLabel, action: onRetry)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(DesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.errorRed.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .strokeBorder(DesignSystem.Colors.errorRed.opacity(0.25), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error: \(message)")
    }
}

#Preview("Light", traits: .fixedLayout(width: 560, height: 140)) {
    VStack(spacing: DesignSystem.Spacing.sm) {
        SettingsErrorBanner(
            message: "Whisper model download failed. Check your network connection and try again.",
            onRetry: {}
        )

        SettingsErrorBanner(message: "Calendar access was denied.", retryLabel: nil)
    }
    .padding(DesignSystem.Spacing.lg)
    .background(DesignSystem.Colors.cardBackground)
    .preferredColorScheme(.light)
}

#Preview("Dark", traits: .fixedLayout(width: 560, height: 100)) {
    SettingsErrorBanner(
        message: "Whisper model download failed.",
        onRetry: {}
    )
    .padding(DesignSystem.Spacing.lg)
    .background(DesignSystem.Colors.cardBackground)
    .preferredColorScheme(.dark)
}
