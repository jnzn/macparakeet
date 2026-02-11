import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

struct VocabularyView: View {
    @Bindable var settingsViewModel: SettingsViewModel
    @Bindable var customWordsViewModel: CustomWordsViewModel
    @Bindable var textSnippetsViewModel: TextSnippetsViewModel

    @State private var showCustomWords = false
    @State private var showTextSnippets = false

    var body: some View {
        ScrollView {
            VStack(spacing: DesignSystem.Spacing.lg) {
                // Hero question
                VStack(spacing: DesignSystem.Spacing.sm) {
                    Text("How should your text sound?")
                        .font(DesignSystem.Typography.pageTitle)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text("Choose how MacParakeet processes your dictation.")
                        .font(DesignSystem.Typography.bodySmall)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, DesignSystem.Spacing.lg)
                .padding(.top, DesignSystem.Spacing.lg)

                // Mode toggle cards
                HStack(spacing: DesignSystem.Spacing.md) {
                    modeCard(
                        title: "Raw",
                        subtitle: "As spoken",
                        icon: "text.quote",
                        isSelected: settingsViewModel.processingMode == "raw"
                    ) {
                        settingsViewModel.processingMode = "raw"
                    }

                    modeCard(
                        title: "Clean",
                        subtitle: "Polished",
                        icon: "sparkles",
                        isSelected: settingsViewModel.processingMode == "clean"
                    ) {
                        settingsViewModel.processingMode = "clean"
                    }
                }
                .padding(.horizontal, DesignSystem.Spacing.lg)

                // Pipeline card (only in clean mode)
                if settingsViewModel.processingMode == "clean" {
                    pipelineCard
                        .padding(.horizontal, DesignSystem.Spacing.lg)
                }

                // Footer note
                Text("Changes take effect on your next dictation.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DesignSystem.Spacing.lg)

                Spacer()
            }
        }
        .sheet(isPresented: $showCustomWords) {
            settingsViewModel.refreshStats()
        } content: {
            CustomWordsView(viewModel: customWordsViewModel)
                .frame(minWidth: 500, minHeight: 400)
        }
        .sheet(isPresented: $showTextSnippets) {
            settingsViewModel.refreshStats()
        } content: {
            TextSnippetsView(viewModel: textSnippetsViewModel)
                .frame(minWidth: 500, minHeight: 400)
        }
        .onAppear {
            settingsViewModel.refreshStats()
        }
    }

    // MARK: - Mode Card

    private func modeCard(title: String, subtitle: String, icon: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 24))
                    .foregroundStyle(isSelected ? DesignSystem.Colors.accent : .secondary)

                Text(title)
                    .font(DesignSystem.Typography.sectionTitle)
                    .foregroundStyle(isSelected ? .primary : .secondary)

                Text(subtitle)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignSystem.Spacing.lg)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                    .fill(isSelected ? DesignSystem.Colors.accentLight : DesignSystem.Colors.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                    .strokeBorder(
                        isSelected ? DesignSystem.Colors.accent.opacity(0.4) : DesignSystem.Colors.border,
                        lineWidth: isSelected ? 1.5 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Pipeline Card

    private var pipelineCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("The Clean Pipeline")
                .font(DesignSystem.Typography.sectionTitle)
                .padding(.horizontal, DesignSystem.Spacing.lg)
                .padding(.top, DesignSystem.Spacing.lg)
                .padding(.bottom, DesignSystem.Spacing.md)

            VStack(spacing: 0) {
                pipelineStep(
                    number: 1,
                    title: "Remove fillers",
                    detail: "um, uh, like, you know",
                    action: nil
                )

                Divider()
                    .padding(.leading, 48)

                pipelineStep(
                    number: 2,
                    title: "Fix words",
                    detail: "\(settingsViewModel.customWordCount) custom correction\(settingsViewModel.customWordCount == 1 ? "" : "s")",
                    action: {
                        customWordsViewModel.loadWords()
                        showCustomWords = true
                    }
                )

                Divider()
                    .padding(.leading, 48)

                pipelineStep(
                    number: 3,
                    title: "Expand snippets",
                    detail: "\(settingsViewModel.snippetCount) text snippet\(settingsViewModel.snippetCount == 1 ? "" : "s")",
                    action: {
                        textSnippetsViewModel.loadSnippets()
                        showTextSnippets = true
                    }
                )

                Divider()
                    .padding(.leading, 48)

                pipelineStep(
                    number: 4,
                    title: "Clean whitespace",
                    detail: "Fixes spacing & punctuation",
                    action: nil
                )
            }
            .padding(.bottom, DesignSystem.Spacing.md)
        }
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

    private func pipelineStep(number: Int, title: String, detail: String, action: (() -> Void)?) -> some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            // Step number
            Text("\(number)")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.accent)
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(DesignSystem.Colors.accent.opacity(0.1))
                )

            // Content
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DesignSystem.Typography.body)
                Text(detail)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Manage link
            if let action {
                Button("Manage") {
                    action()
                }
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.accent)
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.vertical, DesignSystem.Spacing.md)
    }
}
