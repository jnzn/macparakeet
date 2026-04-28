import SwiftUI

/// A pill-shaped status indicator: tinted dot + label.
///
/// Strict semantics, never mixed:
/// - `.ok`           — green; nothing actionable, things are working
/// - `.recommended`  — amber; user action would improve the experience
/// - `.required`     — red; user action is required for the feature to work
/// - `.info`         — gray; informational only, never indicates a problem
///
/// Used both inline inside `SettingsCard` rows (e.g. the Permissions dashboard)
/// and as the badge on `SettingsTabBar` pills. The same enum drives both view
/// sites so the visual language stays consistent and the source of truth is the
/// owning ViewModel — never duplicated polling.
struct SettingsStatusChip: View {
    enum Status: Equatable {
        case ok
        case recommended
        case required
        case info
    }

    let status: Status
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)

            Text(label)
                .font(DesignSystem.Typography.micro.weight(.medium))
                .foregroundStyle(textColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(tint.opacity(0.12))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(accessibilityPrefix): \(label)")
    }

    private var tint: Color {
        switch status {
        case .ok: return DesignSystem.Colors.successGreen
        case .recommended: return DesignSystem.Colors.warningAmber
        case .required: return DesignSystem.Colors.errorRed
        case .info: return DesignSystem.Colors.textSecondary
        }
    }

    private var textColor: Color {
        switch status {
        case .ok: return DesignSystem.Colors.successGreen
        case .recommended: return DesignSystem.Colors.warningAmber
        case .required: return DesignSystem.Colors.errorRed
        case .info: return DesignSystem.Colors.textSecondary
        }
    }

    private var accessibilityPrefix: String {
        switch status {
        case .ok: return "Status OK"
        case .recommended: return "Action recommended"
        case .required: return "Action required"
        case .info: return "Status"
        }
    }
}

#Preview("Light", traits: .fixedLayout(width: 360, height: 220)) {
    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
        SettingsStatusChip(status: .ok, label: "Granted")
        SettingsStatusChip(status: .recommended, label: "Recommended")
        SettingsStatusChip(status: .required, label: "Required")
        SettingsStatusChip(status: .info, label: "Checking...")
    }
    .padding()
    .background(DesignSystem.Colors.background)
    .preferredColorScheme(.light)
}

#Preview("Dark", traits: .fixedLayout(width: 360, height: 220)) {
    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
        SettingsStatusChip(status: .ok, label: "Granted")
        SettingsStatusChip(status: .recommended, label: "Recommended")
        SettingsStatusChip(status: .required, label: "Required")
        SettingsStatusChip(status: .info, label: "Checking...")
    }
    .padding()
    .background(DesignSystem.Colors.background)
    .preferredColorScheme(.dark)
}
