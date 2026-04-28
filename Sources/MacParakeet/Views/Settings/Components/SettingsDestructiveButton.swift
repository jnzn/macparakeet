import SwiftUI

/// Red-tinted bordered button with built-in confirmation alert.
///
/// Wraps the SwiftUI `.alert` modifier and `Button(role: .destructive)` pattern
/// behind a single primitive, so the Reset & Cleanup card can declare three
/// destructive actions without each one re-implementing the confirmation
/// dance. Native `.alert` is intentionally preserved (not a custom modal) per
/// the locked decision in `plans/active/2026-04-settings-ia-overhaul.md`.
struct SettingsDestructiveButton: View {
    let title: String
    let confirmationTitle: String
    let confirmationMessage: String
    let confirmButtonLabel: String
    let action: () -> Void

    @State private var isPresented = false

    init(
        title: String,
        confirmationTitle: String,
        confirmationMessage: String,
        confirmButtonLabel: String,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.confirmationTitle = confirmationTitle
        self.confirmationMessage = confirmationMessage
        self.confirmButtonLabel = confirmButtonLabel
        self.action = action
    }

    var body: some View {
        Button(title, role: .destructive) {
            isPresented = true
        }
        .buttonStyle(.bordered)
        .alert(confirmationTitle, isPresented: $isPresented) {
            Button("Cancel", role: .cancel) {}
            Button(confirmButtonLabel, role: .destructive, action: action)
        } message: {
            Text(confirmationMessage)
        }
    }
}

#Preview("Light", traits: .fixedLayout(width: 420, height: 200)) {
    VStack(spacing: DesignSystem.Spacing.md) {
        SettingsDestructiveButton(
            title: "Clear All Dictations...",
            confirmationTitle: "Clear All Dictations?",
            confirmationMessage: "This will permanently delete all dictations and their audio files. This cannot be undone.",
            confirmButtonLabel: "Clear All"
        ) {}

        SettingsDestructiveButton(
            title: "Reset Lifetime Stats...",
            confirmationTitle: "Reset Lifetime Stats?",
            confirmationMessage: "This will zero your lifetime stats. Your dictation history is not affected.",
            confirmButtonLabel: "Reset"
        ) {}
    }
    .padding()
    .background(DesignSystem.Colors.background)
    .preferredColorScheme(.light)
}

#Preview("Dark", traits: .fixedLayout(width: 420, height: 200)) {
    VStack(spacing: DesignSystem.Spacing.md) {
        SettingsDestructiveButton(
            title: "Clear All Dictations...",
            confirmationTitle: "Clear All Dictations?",
            confirmationMessage: "This will permanently delete all dictations.",
            confirmButtonLabel: "Clear All"
        ) {}
    }
    .padding()
    .background(DesignSystem.Colors.background)
    .preferredColorScheme(.dark)
}
