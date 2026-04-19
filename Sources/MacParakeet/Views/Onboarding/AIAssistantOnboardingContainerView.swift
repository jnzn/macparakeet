import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

/// Container view for the optional "Ask AI Assistant" onboarding step.
/// Switches on `AIAssistantOnboardingViewModel.card` to render intro,
/// per-provider, default-picker, or finished sub-states. Inner buttons
/// (Continue / Skip / Enable / Skip / Finish) drive the VM; the outer
/// `OnboardingFlowView` Continue button skip-all-and-advances regardless.
struct AIAssistantOnboardingContainerView: View {
    @Bindable var viewModel: AIAssistantOnboardingViewModel
    /// Called when the user reaches the end of the AI step (either by
    /// finishing the default picker or by clicking [Skip all →]). The
    /// container has already called `viewModel.finish()` if applicable.
    let onAdvance: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch viewModel.card {
            case .intro:
                introCard
            case .provider(let provider):
                providerCard(for: provider)
            case .defaultPicker:
                defaultPickerCard
            case .finished:
                finishedCard
            }
        }
    }

    // MARK: - Intro

    private var introCard: some View {
        cardShell(title: "Pick your AI assistants", icon: "sparkles") {
            Text("MacParakeet's AI Assistant hotkey (Fn / Globe by default) lets you ask questions about whatever text you've selected. Each provider runs a CLI you already have installed — we'll detect which ones are on your machine.")
                .font(DesignSystem.Typography.bodySmall)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Skip any (or all) — you can wire them later in Settings → AI Assistant.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                primaryButton("Continue") {
                    viewModel.continueFromIntro()
                }

                secondaryButton("Skip all →") {
                    viewModel.skipAll()
                    onAdvance()
                }
            }
        }
    }

    // MARK: - Per-provider

    private func providerCard(for provider: AIAssistantConfig.Provider) -> some View {
        Group {
            if provider == .ollama {
                ollamaCard
            } else {
                cliProviderCard(for: provider)
            }
        }
    }

    private func cliProviderCard(for provider: AIAssistantConfig.Provider) -> some View {
        cardShell(title: provider.displayName, icon: provider.iconSystemName) {
            Text(productDescription(for: provider))
                .font(DesignSystem.Typography.bodySmall)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            integrationNoteRow(for: provider)

            detectionRow(for: provider)
                .task(id: provider) { await viewModel.detect(provider) }

            smokeTestRow(for: provider)

            HStack(spacing: 10) {
                primaryButton(enableLabel(for: provider), disabled: !canEnableCLI(provider)) {
                    Task { await viewModel.enableCurrentProviderWithSmokeTest() }
                }

                secondaryButton("Skip") {
                    viewModel.skipCurrentProvider()
                }
            }
        }
    }

    // MARK: - Ollama (special: HTTP probe + remote branch)

    private var ollamaCard: some View {
        cardShell(title: "Ollama", icon: "cpu") {
            Text("Ollama runs open-weights models (Llama 3, Qwen, Mistral, …) on your own hardware. The bubble talks to the daemon via HTTP — no `ollama` binary needed on PATH.")
                .font(DesignSystem.Typography.bodySmall)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ollamaProbeRow
                .task { await viewModel.probeOllamaLocal() }

            if shouldShowRemoteBranch {
                remoteOllamaSection
            }

            if case .foundLocal = viewModel.ollamaProbe {
                modelPicker(models: localModels, selection: localOllamaModelBinding)
            } else if case .foundRemote = viewModel.ollamaProbe {
                modelPicker(models: remoteModels, selection: remoteOllamaModelBinding)
            }

            HStack(spacing: 10) {
                primaryButton("Enable Ollama", disabled: !canEnableOllama) {
                    Task { await viewModel.enableCurrentProviderWithSmokeTest() }
                }
                secondaryButton("Skip") {
                    viewModel.skipCurrentProvider()
                }
            }
        }
    }

    private var ollamaProbeRow: some View {
        HStack(spacing: 8) {
            switch viewModel.ollamaProbe {
            case .unknown, .checking:
                ProgressView()
                    .controlSize(.small)
                Text("Probing http://localhost:11434/api/tags…")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            case .foundLocal(let models):
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(DesignSystem.Colors.successGreen)
                Text("Ollama running locally — \(models.count) model\(models.count == 1 ? "" : "s") installed")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            case .foundRemote(let models):
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(DesignSystem.Colors.successGreen)
                Text("Connected — \(models.count) model\(models.count == 1 ? "" : "s") available")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            case .localMissing:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DesignSystem.Colors.warningAmber)
                Text("No daemon at localhost:11434.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            case .remoteFailed(let error):
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text(remoteErrorMessage(error))
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var remoteOllamaSection: some View {
        Toggle(isOn: Binding(
            get: { viewModel.remoteOllama.enabled },
            set: { viewModel.setRemoteOllamaEnabled($0) }
        )) {
            Text("Is Ollama on another computer?")
                .font(DesignSystem.Typography.bodySmall)
        }
        .toggleStyle(.checkbox)

        if viewModel.remoteOllama.enabled {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("Host (e.g. studio.local or my-tailnet.ts.net)", text: $viewModel.remoteOllama.host)
                        .textFieldStyle(.roundedBorder)
                    TextField("Port", text: $viewModel.remoteOllama.port)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                }

                if let error = viewModel.remoteOllama.validationError {
                    Text(error)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.red)
                }

                Button("Test connection") {
                    Task { await viewModel.probeOllamaRemote() }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Default picker

    private var defaultPickerCard: some View {
        cardShell(title: "Pick your default", icon: "checkmark.seal") {
            if viewModel.enabledProviders.isEmpty {
                Text("You didn't enable any providers — the Fn / Globe hotkey will stay inactive. You can configure providers later in Settings → AI Assistant.")
                    .font(DesignSystem.Typography.bodySmall)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Pressing Fn opens the default first. You can switch providers in the bubble's bottom row.")
                    .font(DesignSystem.Typography.bodySmall)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(AIAssistantConfig.Provider.allCases, id: \.rawValue) { provider in
                        if viewModel.enabledProviders.contains(provider) {
                            defaultProviderRow(provider)
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                primaryButton("Finish AI setup", disabled: viewModel.defaultProvider == nil) {
                    do {
                        _ = try viewModel.finish()
                        onAdvance()
                    } catch {
                        // Persistence is UserDefaults + Keychain; failures
                        // are extremely rare. Drop to logs and still advance
                        // so the user isn't trapped on the card.
                        onAdvance()
                    }
                }

                secondaryButton("Skip — don't enable hotkey") {
                    viewModel.skipAll()
                    onAdvance()
                }
            }
        }
    }

    private func defaultProviderRow(_ provider: AIAssistantConfig.Provider) -> some View {
        HStack(spacing: 10) {
            Image(systemName: viewModel.defaultProvider == provider ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(viewModel.defaultProvider == provider ? DesignSystem.Colors.accent : .secondary)
            Image(systemName: provider.iconSystemName)
                .foregroundStyle(.secondary)
            Text(provider.displayName)
                .font(.system(size: 13))
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.setDefaultProvider(provider)
        }
    }

    // MARK: - Finished

    private var finishedCard: some View {
        cardShell(title: "AI setup complete", icon: "checkmark.circle") {
            Text("You're done with this step. Click Continue to download the speech model.")
                .font(DesignSystem.Typography.bodySmall)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Smoke / detection rows

    private func detectionRow(for provider: AIAssistantConfig.Provider) -> some View {
        HStack(spacing: 8) {
            switch viewModel.cliDetection[provider] ?? .unknown {
            case .unknown, .checking:
                ProgressView().controlSize(.small)
                Text("Checking PATH…")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            case .found(let url):
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(DesignSystem.Colors.successGreen)
                Text(url.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            case .notFound:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DesignSystem.Colors.warningAmber)
                Text("Not detected on your PATH — Skip and install later if you want to use it.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func smokeTestRow(for provider: AIAssistantConfig.Provider) -> some View {
        switch viewModel.smokeTest[provider] ?? .idle {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Running connectivity test…")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            }
        case .succeeded:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(DesignSystem.Colors.successGreen)
                Text("Connection works.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text("Smoke test failed.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.red)
                }
                Text(message)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(DesignSystem.Colors.surfaceElevated)
                    )
                Button("Try again") {
                    Task { await viewModel.enableCurrentProviderWithSmokeTest() }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Helpers

    private func cardShell<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.accent)
                Text(title)
                    .font(DesignSystem.Typography.sectionTitle)
            }
            content()
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

    private func primaryButton(
        _ title: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.onAccent)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Layout.buttonCornerRadius)
                        .fill(disabled ? DesignSystem.Colors.accent.opacity(0.4) : DesignSystem.Colors.accent)
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func secondaryButton(
        _ title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
    }

    private func enableLabel(for provider: AIAssistantConfig.Provider) -> String {
        "Enable \(provider.displayName)"
    }

    private func productDescription(for provider: AIAssistantConfig.Provider) -> String {
        switch provider {
        case .claude:
            return "Anthropic's agentic CLI. Reads context from your selection, runs tools (file edits, shell commands) under permission gates."
        case .codex:
            return "OpenAI's agentic CLI for code tasks — read, edit, and run code from your terminal."
        case .gemini:
            return "Google's CLI for Gemini models. Good at code reasoning and long-context document analysis."
        case .ollama:
            return ""
        }
    }

    @ViewBuilder
    private func integrationNoteRow(for provider: AIAssistantConfig.Provider) -> some View {
        switch provider {
        case .claude:
            Text("We invoke `claude --dangerously-skip-permissions -p` so it auto-approves tool use during the bubble session.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        case .codex:
            Text("We invoke `codex exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check`.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        case .gemini:
            Text("We invoke `gemini --yolo --prompt \"\"` so it auto-accepts actions and reads the prompt from stdin.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        case .ollama:
            EmptyView()
        }
    }

    private func remoteErrorMessage(_ error: OllamaReachability.ProbeError) -> String {
        switch error {
        case .invalidURL:
            return "Couldn't build a valid URL — only loopback, Tailscale (*.ts.net), .local, RFC1918, and HTTPS hosts are accepted."
        case .timeout:
            return "Timed out — verify the host and port and that the daemon is up."
        case .connectionRefused:
            return "Connection refused — the daemon may not be listening on that port."
        case .http(let status):
            return "Daemon responded HTTP \(status) instead of 200."
        case .parse:
            return "Daemon responded but the body wasn't a valid /api/tags response."
        case .other(let message):
            return "Couldn't reach: \(message)"
        }
    }

    // MARK: - Ollama derived state

    private var shouldShowRemoteBranch: Bool {
        switch viewModel.ollamaProbe {
        case .localMissing, .remoteFailed, .foundRemote:
            return true
        default:
            return viewModel.remoteOllama.enabled
        }
    }

    private var localModels: [String] {
        if case .foundLocal(let models) = viewModel.ollamaProbe { return models }
        return []
    }

    private var remoteModels: [String] {
        if case .foundRemote(let models) = viewModel.ollamaProbe { return models }
        return []
    }

    private func canEnableCLI(_ provider: AIAssistantConfig.Provider) -> Bool {
        let isRunning = viewModel.smokeTest[provider] == .running
        switch viewModel.cliDetection[provider] ?? .unknown {
        case .found: return !isRunning
        default: return false
        }
    }

    private var canEnableOllama: Bool {
        switch viewModel.ollamaProbe {
        case .foundLocal(let models):
            return !models.isEmpty
        case .foundRemote(let models):
            return !models.isEmpty
        default:
            return false
        }
    }

    private var localOllamaModelBinding: Binding<String?> {
        Binding(
            get: { viewModel.providerModels[.ollama] },
            set: { newValue in
                if let newValue { viewModel.setOllamaModel(newValue) }
            }
        )
    }

    private var remoteOllamaModelBinding: Binding<String?> {
        Binding(
            get: { viewModel.remoteOllama.selectedModel },
            set: { newValue in
                if let newValue { viewModel.setOllamaModel(newValue) }
            }
        )
    }

    private func modelPicker(models: [String], selection: Binding<String?>) -> some View {
        HStack(spacing: 8) {
            Text("Model:")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
            Picker("", selection: selection) {
                ForEach(models, id: \.self) { name in
                    Text(name).tag(Optional(name))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }
}
