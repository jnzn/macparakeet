import SwiftUI

/// Semantic role for an actionable control. Apply via `.parakeetAction(_:)`.
///
/// Replaces ad-hoc `.buttonStyle(.bordered) + .tint(...)` composition with a
/// single intent-carrying modifier. The role drives visual treatment so
/// callsites carry meaning, not styling primitives.
enum ParakeetActionRole {
    /// The single primary CTA on a surface. Brand coral.
    case primary
    /// Default action weight. System label color, neutral chrome.
    case secondary
    /// Irreversible action. System destructive red.
    /// Pair with `Button(role: .destructive)` to also carry VoiceOver semantics.
    case destructive
    /// Lower visual weight than `.secondary`. Borderless, secondary label
    /// color. For non-essential actions in dense rows or as inline links.
    case subtle
}

extension View {
    /// Apply a semantic action role to a control.
    ///
    /// - Parameters:
    ///   - role: The action's intent.
    ///   - prominent: If true, use `.borderedProminent`. Reserve for the
    ///     single highest-priority action on a sheet or modal. Default false.
    @ViewBuilder
    func parakeetAction(_ role: ParakeetActionRole, prominent: Bool = false) -> some View {
        switch role {
        case .primary:
            if prominent {
                self.buttonStyle(.borderedProminent)
                    .tint(DesignSystem.Colors.accent)
            } else {
                self.buttonStyle(.bordered)
                    .tint(DesignSystem.Colors.accent)
            }
        case .secondary:
            self.buttonStyle(.bordered)
                .tint(DesignSystem.Colors.tintNeutral)
        case .destructive:
            if prominent {
                self.buttonStyle(.borderedProminent)
                    .tint(DesignSystem.Colors.errorRed)
            } else {
                self.buttonStyle(.bordered)
                    .tint(DesignSystem.Colors.errorRed)
            }
        case .subtle:
            self.buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
    }
}
