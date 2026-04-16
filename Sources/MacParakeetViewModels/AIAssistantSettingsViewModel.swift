import Foundation
import MacParakeetCore

/// ViewModel for the AI Assistant settings card. Mirrors the shape of
/// `LLMSettingsViewModel` but writes to `AIAssistantConfigStore` and uses
/// `AIAssistantConfig` as its source of truth. CLI providers still use
/// `LocalCLIExecutor`; Ollama is routed through the formatter's configured
/// HTTP endpoint via `AIAssistantOllamaExecutor`.
@MainActor
@Observable
public final class AIAssistantSettingsViewModel {
    // Stored identity.
    public var provider: AIAssistantConfig.Provider {
        didSet { if oldValue != provider { applyProviderDefaults() } }
    }
    public var commandTemplate: String
    public var modelName: String
    public var timeoutSeconds: Double
    /// Bound to `HotkeyRecorderView`. Persisted as-is; `onHotkeyChanged`
    /// fires whenever the user commits a new shortcut so the AppHotkey
    /// coordinator can rebind without restarting the app.
    public var hotkeyTrigger: HotkeyTrigger {
        didSet { if oldValue != hotkeyTrigger { onHotkeyChanged?() } }
    }
    public var onHotkeyChanged: (() -> Void)?
    /// User-picked translucent background color for the AI bubble. The
    /// SwiftUI `ColorPicker` writes to this directly; persistence is opt-in
    /// via `save()` so the user can experiment without committing.
    public var bubbleBackgroundColor: CodableColor
    /// When on, Claude/Codex's first response to the initial question
    /// auto-pastes over the user's original selection in the source app.
    /// Bound to a Settings toggle; persisted on `save()`.
    public var autoReplaceSelection: Bool
    /// Set of providers that should appear as switchable icons in the
    /// bubble's bottom row. The current default provider is always
    /// implicitly enabled regardless of this set.
    public var enabledProviders: Set<AIAssistantConfig.Provider>

    /// Feedback surface for test-connection calls. Cleared as the user edits
    /// the command.
    public private(set) var testStatus: TestStatus = .idle

    public enum TestStatus: Equatable, Sendable {
        case idle
        case running
        case success
        case failure(String)
    }

    private let store: AIAssistantConfigStore
    private let cliExecutor: any AIAssistantExecuting
    private let ollamaExecutor: any AIAssistantExecuting

    public init(
        store: AIAssistantConfigStore = AIAssistantConfigStore(),
        executor: any AIAssistantExecuting = LocalCLIExecutor(),
        ollamaExecutor: any AIAssistantExecuting = AIAssistantOllamaExecutor()
    ) {
        self.store = store
        self.cliExecutor = executor
        self.ollamaExecutor = ollamaExecutor
        let loaded = store.load() ?? AIAssistantConfig.defaultClaude
        self.provider = loaded.provider
        self.commandTemplate = loaded.commandTemplate
        self.modelName = loaded.modelName
        self.timeoutSeconds = loaded.timeoutSeconds
        self.hotkeyTrigger = loaded.effectiveHotkeyTrigger
        self.bubbleBackgroundColor = loaded.effectiveBubbleBackgroundColor
        self.autoReplaceSelection = loaded.effectiveAutoReplaceSelection
        self.enabledProviders = Set(loaded.effectiveEnabledProviders)
    }

    public var currentConfig: AIAssistantConfig {
        // Always force-include the current default provider so the user
        // can't lock themselves out of their own pick.
        let providers = enabledProviders.union([provider])
        let enabledRawValues = AIAssistantConfig.Provider.allCases
            .filter { providers.contains($0) }
            .map(\.rawValue)
        return AIAssistantConfig(
            provider: provider,
            commandTemplate: commandTemplate,
            modelName: modelName,
            timeoutSeconds: timeoutSeconds,
            hotkeyTrigger: hotkeyTrigger,
            bubbleBackgroundColor: bubbleBackgroundColor,
            autoReplaceSelection: autoReplaceSelection,
            enabledProviders: enabledRawValues
        )
    }

    /// Whether a given provider should show as a switchable icon in the
    /// bubble. Always returns true for the current default so the toggle
    /// for it is visibly checked-and-disabled in the UI.
    public func isProviderEnabled(_ p: AIAssistantConfig.Provider) -> Bool {
        p == provider || enabledProviders.contains(p)
    }

    public func setProvider(_ p: AIAssistantConfig.Provider, enabled: Bool) {
        if enabled {
            enabledProviders.insert(p)
        } else if p != provider {
            enabledProviders.remove(p)
        }
        save()
    }

    public func save() {
        try? store.save(currentConfig)
    }

    public func resetToProviderDefaults() {
        applyProviderDefaults()
        save()
    }

    /// Fire a minimal `Reply with OK`-style probe through the currently
    /// selected provider. Surfaces failure messages verbatim so the user can
    /// diagnose bad local CLI flags or an unreachable Ollama endpoint.
    public func testConnection() async {
        testStatus = .running
        let config = currentConfig
        let executionConfig = LocalCLIConfig(
            commandTemplate: config.effectiveCommandTemplate,
            timeoutSeconds: min(30, config.timeoutSeconds)
        )
        let executor = provider == .ollama ? ollamaExecutor : cliExecutor
        do {
            let output = try await executor.execute(
                systemPrompt: "You are a connectivity test probe. Reply with the two letters OK and nothing else.",
                userPrompt: "Reply OK",
                config: executionConfig
            )
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            testStatus = trimmed.isEmpty ? .failure("Empty response from provider.") : .success
        } catch {
            testStatus = .failure(error.localizedDescription)
        }
    }

    // MARK: - Private

    private func applyProviderDefaults() {
        commandTemplate = provider.defaultCommandTemplate
        modelName = provider.defaultModel
        timeoutSeconds = AIAssistantConfig.defaultTimeout
        bubbleBackgroundColor = AIAssistantConfig.defaultBubbleBackgroundColor
        testStatus = .idle
    }

    /// Called by the AppHotkeyCoordinator (via `onHotkeyChanged`) after it
    /// has successfully applied the new trigger. Persists the change.
    public func persistHotkeyIfChanged() {
        save()
    }

    /// Restore the bubble tint to the shipped transparent default and
    /// persist. Separate from `resetToProviderDefaults` so users can wipe
    /// just the color without losing their command template / model edits.
    public func resetBubbleColorToDefault() {
        bubbleBackgroundColor = AIAssistantConfig.defaultBubbleBackgroundColor
        save()
    }
}
