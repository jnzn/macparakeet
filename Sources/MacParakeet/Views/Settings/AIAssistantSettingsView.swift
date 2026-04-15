import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

/// Settings UI for the AI Assistant hotkey (Control+Shift+A). Lets the user
/// pick provider, edit the command template + model, and smoke-test the
/// connection. Persists to `AIAssistantConfigStore` on save.
struct AIAssistantSettingsView: View {
    @Bindable var viewModel: AIAssistantSettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Text("Hold Control+Shift+A to ask the agentic CLI (Claude Code or Codex) about your current selection. Hotkey is hardcoded in this build; a configurable picker lands later.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.secondary)

            HStack {
                Text("Provider").font(.callout)
                Spacer()
                Picker("Provider", selection: $viewModel.provider) {
                    ForEach(AIAssistantConfig.Provider.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Command template").font(.callout)
                TextField("", text: $viewModel.commandTemplate, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1...3)
                Text("Includes the skip-permissions flag. Append --model only if you don't want the Model field applied.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: DesignSystem.Spacing.md) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Model").font(.callout)
                    TextField("", text: $viewModel.modelName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Timeout").font(.callout)
                    HStack(spacing: 4) {
                        TextField("", value: $viewModel.timeoutSeconds, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                        Text("sec").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 140, alignment: .leading)
            }

            HStack(spacing: DesignSystem.Spacing.md) {
                Button("Save") {
                    viewModel.save()
                }
                .buttonStyle(.borderedProminent)

                Button("Reset to \(viewModel.provider.displayName) defaults") {
                    viewModel.resetToProviderDefaults()
                }
                .buttonStyle(.bordered)

                Button("Test") {
                    Task { await viewModel.testConnection() }
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.testStatus == .running)

                testStatusLabel
            }
        }
    }

    @ViewBuilder
    private var testStatusLabel: some View {
        switch viewModel.testStatus {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Testing…").font(.caption).foregroundStyle(.secondary)
            }
        case .success:
            Label("OK", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }
}
