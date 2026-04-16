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
            Text("Hold the hotkey to ask the agentic CLI (Claude Code or Codex) about your current selection. Voice is transcribed while held; release submits.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.secondary)

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hotkey").font(.callout)
                    Text("Hold to speak; release to send.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: DesignSystem.Spacing.md)
                HotkeyRecorderView(
                    trigger: $viewModel.hotkeyTrigger,
                    defaultTrigger: AIAssistantConfig.defaultHotkeyTrigger
                )
            }

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bubble color").font(.callout)
                    Text("Background of the AI Assistant bubble. Text contrast adapts automatically.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: DesignSystem.Spacing.md)
                HStack(spacing: 8) {
                    // Live preview swatch — shows the picked color over a
                    // checkerboard-ish neutral so translucency is visible
                    // before opening the bubble.
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(viewModel.bubbleBackgroundColor.toSwiftUIColor())
                        .frame(width: 60, height: 30)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.primary.opacity(0.15), lineWidth: 0.5)
                        )
                    ColorPicker(
                        "Bubble color",
                        selection: bubbleColorBinding,
                        supportsOpacity: true
                    )
                    .labelsHidden()
                    Button("Reset") {
                        viewModel.resetBubbleColorToDefault()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Reset bubble tint to the default (transparent — uses system material).")
                }
            }

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

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-replace selection with first response").font(.callout)
                    Text("Claude's first reply to the initial question pastes over your original selection. Later replies still require the per-turn Replace button.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: DesignSystem.Spacing.md)
                Toggle("", isOn: Binding(
                    get: { viewModel.autoReplaceSelection },
                    set: { newValue in
                        viewModel.autoReplaceSelection = newValue
                        viewModel.save()
                    }
                ))
                .labelsHidden()
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

    /// Bridges the viewmodel's `CodableColor` (UI-free) to a SwiftUI `Color`
    /// binding for `ColorPicker`. Round-trips via the sRGB extension defined
    /// in the app target.
    private var bubbleColorBinding: Binding<Color> {
        Binding(
            get: { viewModel.bubbleBackgroundColor.toSwiftUIColor() },
            set: { viewModel.bubbleBackgroundColor = $0.toCodableColor() }
        )
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
