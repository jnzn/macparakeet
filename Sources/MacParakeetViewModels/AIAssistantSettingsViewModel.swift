import Foundation
import MacParakeetCore

/// ViewModel for the AI Assistant settings card. Mirrors the shape of
/// `LLMSettingsViewModel` but writes to `AIAssistantConfigStore` and uses
/// `AIAssistantConfig` as its source of truth.
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
    private let executor: any AIAssistantExecuting

    public init(
        store: AIAssistantConfigStore = AIAssistantConfigStore(),
        executor: any AIAssistantExecuting = LocalCLIExecutor()
    ) {
        self.store = store
        self.executor = executor
        let loaded = store.load() ?? AIAssistantConfig.defaultClaude
        self.provider = loaded.provider
        self.commandTemplate = loaded.commandTemplate
        self.modelName = loaded.modelName
        self.timeoutSeconds = loaded.timeoutSeconds
        self.hotkeyTrigger = loaded.effectiveHotkeyTrigger
        self.bubbleBackgroundColor = loaded.effectiveBubbleBackgroundColor
        self.autoReplaceSelection = loaded.effectiveAutoReplaceSelection
    }

    public var currentConfig: AIAssistantConfig {
        AIAssistantConfig(
            provider: provider,
            commandTemplate: commandTemplate,
            modelName: modelName,
            timeoutSeconds: timeoutSeconds,
            hotkeyTrigger: hotkeyTrigger,
            bubbleBackgroundColor: bubbleBackgroundColor,
            autoReplaceSelection: autoReplaceSelection
        )
    }

    public func save() {
        try? store.save(currentConfig)
    }

    public func resetToProviderDefaults() {
        applyProviderDefaults()
        save()
    }

    /// Fire a minimal `Reply with OK`-style probe through the configured
    /// CLI. Surfaces failure messages verbatim so the user can diagnose
    /// "command not found" / bad flags etc.
    public func testConnection() async {
        testStatus = .running
        let config = currentConfig
        let cliConfig = LocalCLIConfig(
            commandTemplate: config.effectiveCommandTemplate,
            timeoutSeconds: min(30, config.timeoutSeconds)
        )
        do {
            let output = try await executor.execute(
                systemPrompt: "You are a connectivity test probe. Reply with the two letters OK and nothing else.",
                userPrompt: "Reply OK",
                config: cliConfig
            )
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            testStatus = trimmed.isEmpty ? .failure("Empty response from CLI.") : .success
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
