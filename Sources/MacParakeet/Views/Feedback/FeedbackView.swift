import SwiftUI
import AppKit
import MacParakeetCore
import MacParakeetViewModels

/// PDX Edition feedback surface — minimal contact card. The original
/// in-app form posted to the upstream MacParakeet Cloudflare worker
/// (which routes to moona3k/macparakeet GitHub Issues), so it isn't
/// useful from a fork. Replaced with a one-click mailto.
struct FeedbackView: View {
    let viewModel: FeedbackViewModel

    @State private var copiedEmail = false

    private let contactEmail = "pdxedition@fastmail.com"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                contactCard
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .background(DesignSystem.Colors.background)
    }

    private var contactCard: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(spacing: 10) {
                Image(systemName: "envelope")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.accent)
                Text("Contact PDX Edition")
                    .font(DesignSystem.Typography.sectionTitle)
            }

            Text("Bug reports, feature ideas, or anything else: email me directly. PDX Edition is a personal fork — there's no shared issue tracker.")
                .font(DesignSystem.Typography.bodySmall)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    openMail()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "envelope.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Email \(contactEmail)")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(DesignSystem.Colors.onAccent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Layout.buttonCornerRadius)
                            .fill(DesignSystem.Colors.accent)
                    )
                }
                .buttonStyle(.plain)

                Button {
                    copyEmailToClipboard()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: copiedEmail ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11))
                        Text(copiedEmail ? "Copied" : "Copy address")
                    }
                }
                .buttonStyle(.bordered)
            }

            Text("Include your macOS version, the rough sequence of steps, and what you saw vs. what you expected. Crash logs from `~/Library/Logs/DiagnosticReports/` are especially helpful.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                .strokeBorder(DesignSystem.Colors.border.opacity(0.5), lineWidth: 0.5)
        )
    }

    private func openMail() {
        let subject = "MacParakeet (PDX Edition) — feedback"
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = contactEmail
        components.queryItems = [URLQueryItem(name: "subject", value: subject)]
        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
    }

    private func copyEmailToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(contactEmail, forType: .string)
        withAnimation { copiedEmail = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            withAnimation { copiedEmail = false }
        }
    }
}
