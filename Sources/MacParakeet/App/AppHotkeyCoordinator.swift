import AppKit
import MacParakeetCore
import MacParakeetViewModels

@MainActor
final class AppHotkeyCoordinator {
    private let settingsViewModel: SettingsViewModel
    private let aiAssistantConfigStore: AIAssistantConfigStore
    private let onStartDictation: (FnKeyStateMachine.RecordingMode) -> Void
    private let onStopDictation: () -> Void
    private let onCancelDictation: () -> Void
    private let onDiscardRecording: (Bool) -> Void
    private let onReadyForSecondTap: () -> Void
    private let onEscapeWhileIdle: () -> Void
    private let onToggleMeetingRecording: () -> Void
    private let onAIAssistantHotkeyPress: () -> Void
    private let onAIAssistantHotkeyRelease: () -> Void
    private let onAIAssistantHotkeyDoubleTap: () -> Void
    private let onTriggerFileTranscription: () -> Void
    private let onTriggerYouTubeTranscription: () -> Void
    private let onPrimaryHotkeyManagerChanged: (HotkeyManager?) -> Void
    private let onAnyHotkeyEnabled: () -> Void
    private let onHotkeyUnavailable: () -> Void

    private var hotkeyManager: HotkeyManager?
    private var meetingHotkeyManager: GlobalShortcutManager?
    private var aiAssistantHotkeyManager: GlobalShortcutManager?
    private var fileTranscriptionHotkeyManager: GlobalShortcutManager?
    private var youtubeTranscriptionHotkeyManager: GlobalShortcutManager?

    /// Fallback used only when the config store isn't yet available (never
    /// in practice — AppEnvironment constructs the store before the
    /// coordinator). Kept as a compile-time anchor.
    static let defaultAIAssistantTrigger: HotkeyTrigger = AIAssistantConfig.defaultHotkeyTrigger

    init(
        settingsViewModel: SettingsViewModel,
        aiAssistantConfigStore: AIAssistantConfigStore,
        onStartDictation: @escaping (FnKeyStateMachine.RecordingMode) -> Void,
        onStopDictation: @escaping () -> Void,
        onCancelDictation: @escaping () -> Void,
        onDiscardRecording: @escaping (Bool) -> Void,
        onReadyForSecondTap: @escaping () -> Void,
        onEscapeWhileIdle: @escaping () -> Void,
        onToggleMeetingRecording: @escaping () -> Void,
        onAIAssistantHotkeyPress: @escaping () -> Void,
        onAIAssistantHotkeyRelease: @escaping () -> Void,
        onAIAssistantHotkeyDoubleTap: @escaping () -> Void,
        onTriggerFileTranscription: @escaping () -> Void,
        onTriggerYouTubeTranscription: @escaping () -> Void,
        onPrimaryHotkeyManagerChanged: @escaping (HotkeyManager?) -> Void,
        onAnyHotkeyEnabled: @escaping () -> Void,
        onHotkeyUnavailable: @escaping () -> Void
    ) {
        self.settingsViewModel = settingsViewModel
        self.aiAssistantConfigStore = aiAssistantConfigStore
        self.onStartDictation = onStartDictation
        self.onStopDictation = onStopDictation
        self.onCancelDictation = onCancelDictation
        self.onDiscardRecording = onDiscardRecording
        self.onReadyForSecondTap = onReadyForSecondTap
        self.onEscapeWhileIdle = onEscapeWhileIdle
        self.onToggleMeetingRecording = onToggleMeetingRecording
        self.onAIAssistantHotkeyPress = onAIAssistantHotkeyPress
        self.onAIAssistantHotkeyRelease = onAIAssistantHotkeyRelease
        self.onAIAssistantHotkeyDoubleTap = onAIAssistantHotkeyDoubleTap
        self.onTriggerFileTranscription = onTriggerFileTranscription
        self.onTriggerYouTubeTranscription = onTriggerYouTubeTranscription
        self.onPrimaryHotkeyManagerChanged = onPrimaryHotkeyManagerChanged
        self.onAnyHotkeyEnabled = onAnyHotkeyEnabled
        self.onHotkeyUnavailable = onHotkeyUnavailable
    }

    var hotkeyMenuTitle: String {
        Self.menuTitle(for: HotkeyTrigger.current)
    }

    static func menuTitle(for trigger: HotkeyTrigger) -> String {
        if trigger.isDisabled {
            return "Hotkey: Disabled"
        }
        return "Hotkey: \(trigger.displayName) (double-tap / hold)"
    }

    func setupPrimaryHotkey() {
        let trigger = HotkeyTrigger.current
        guard !trigger.isDisabled else {
            hotkeyManager = nil
            onPrimaryHotkeyManagerChanged(nil)
            return
        }

        let manager = HotkeyManager(trigger: trigger)
        manager.onStartRecording = { [weak self] mode in
            self?.onStartDictation(mode)
        }
        manager.onStopRecording = { [weak self] in
            self?.onStopDictation()
        }
        manager.onCancelRecording = { [weak self] in
            self?.onCancelDictation()
        }
        manager.onDiscardRecording = { [weak self] showReadyPill in
            self?.onDiscardRecording(showReadyPill)
        }
        manager.onReadyForSecondTap = { [weak self] in
            self?.onReadyForSecondTap()
        }
        manager.onEscapeWhileIdle = { [weak self] in
            self?.onEscapeWhileIdle()
        }

        if manager.start() {
            hotkeyManager = manager
            onPrimaryHotkeyManagerChanged(manager)
            onAnyHotkeyEnabled()
        } else {
            hotkeyManager = nil
            onPrimaryHotkeyManagerChanged(nil)
            onHotkeyUnavailable()
        }
    }

    func setupMeetingHotkey() {
        guard AppFeatures.meetingRecordingEnabled else {
            meetingHotkeyManager = nil
            return
        }
        meetingHotkeyManager = startAuxiliaryHotkey(
            trigger: settingsViewModel.meetingHotkeyTrigger,
            conflicts: [
                settingsViewModel.hotkeyTrigger,
                settingsViewModel.fileTranscriptionHotkeyTrigger,
                settingsViewModel.youtubeTranscriptionHotkeyTrigger,
            ],
            onTrigger: { [weak self] in
                self?.onToggleMeetingRecording()
            }
        )
    }

    func setupFileTranscriptionHotkey() {
        fileTranscriptionHotkeyManager = startAuxiliaryHotkey(
            trigger: settingsViewModel.fileTranscriptionHotkeyTrigger,
            conflicts: [
                settingsViewModel.hotkeyTrigger,
                settingsViewModel.meetingHotkeyTrigger,
                settingsViewModel.youtubeTranscriptionHotkeyTrigger,
            ],
            onTrigger: { [weak self] in
                self?.onTriggerFileTranscription()
            }
        )
    }

    func setupYouTubeTranscriptionHotkey() {
        youtubeTranscriptionHotkeyManager = startAuxiliaryHotkey(
            trigger: settingsViewModel.youtubeTranscriptionHotkeyTrigger,
            conflicts: [
                settingsViewModel.hotkeyTrigger,
                settingsViewModel.meetingHotkeyTrigger,
                settingsViewModel.fileTranscriptionHotkeyTrigger,
            ],
            onTrigger: { [weak self] in
                self?.onTriggerYouTubeTranscription()
            }
        )
    }

    /// Shared setup for auxiliary (non-dictation) hotkeys: disabled-check,
    /// conflict-check against all other configured triggers, start via
    /// `GlobalShortcutManager`, and surface the availability callback.
    private func startAuxiliaryHotkey(
        trigger: HotkeyTrigger,
        conflicts: [HotkeyTrigger],
        onTrigger: @escaping @MainActor () -> Void
    ) -> GlobalShortcutManager? {
        guard !trigger.isDisabled else { return nil }
        if conflicts.contains(where: { !$0.isDisabled && $0 == trigger }) {
            return nil
        }

        let manager = GlobalShortcutManager(trigger: trigger)
        manager.onTrigger = {
            Task { @MainActor in
                onTrigger()
            }
        }

        if manager.start() {
            onAnyHotkeyEnabled()
            return manager
        } else {
            onHotkeyUnavailable()
            return nil
        }
    }

    func setupAIAssistantHotkey() {
        // Load the user-configured trigger from the AI Assistant config.
        // Falls back to the shipped default when no config is saved yet.
        let trigger = (aiAssistantConfigStore.load() ?? AIAssistantConfig.defaultClaude).effectiveHotkeyTrigger
        guard !trigger.isDisabled,
              trigger != settingsViewModel.hotkeyTrigger,
              trigger != settingsViewModel.meetingHotkeyTrigger
        else {
            aiAssistantHotkeyManager = nil
            return
        }

        let manager = GlobalShortcutManager(trigger: trigger)
        manager.onTrigger = { [weak self] in
            Task { @MainActor in
                self?.onAIAssistantHotkeyPress()
            }
        }
        manager.onRelease = { [weak self] in
            Task { @MainActor in
                self?.onAIAssistantHotkeyRelease()
            }
        }
        manager.onDoubleTap = { [weak self] in
            Task { @MainActor in
                self?.onAIAssistantHotkeyDoubleTap()
            }
        }

        if manager.start() {
            aiAssistantHotkeyManager = manager
            onAnyHotkeyEnabled()
        } else {
            aiAssistantHotkeyManager = nil
            onHotkeyUnavailable()
        }
    }

    func refreshAllHotkeys() {
        hotkeyManager?.stop()
        meetingHotkeyManager?.stop()
        aiAssistantHotkeyManager?.stop()
        fileTranscriptionHotkeyManager?.stop()
        youtubeTranscriptionHotkeyManager?.stop()
        hotkeyManager = nil
        meetingHotkeyManager = nil
        aiAssistantHotkeyManager = nil
        fileTranscriptionHotkeyManager = nil
        youtubeTranscriptionHotkeyManager = nil
        onPrimaryHotkeyManagerChanged(nil)
        setupPrimaryHotkey()
        setupMeetingHotkey()
        setupAIAssistantHotkey()
        setupFileTranscriptionHotkey()
        setupYouTubeTranscriptionHotkey()
    }

    /// Rebind only the AI Assistant hotkey (without touching primary /
    /// meeting). Called when the user saves a new trigger from Settings.
    func refreshAIAssistantHotkey() {
        aiAssistantHotkeyManager?.stop()
        aiAssistantHotkeyManager = nil
        setupAIAssistantHotkey()
    }

    func refreshMeetingHotkey() {
        meetingHotkeyManager?.stop()
        meetingHotkeyManager = nil
        setupMeetingHotkey()
    }

    func refreshFileTranscriptionHotkey() {
        fileTranscriptionHotkeyManager?.stop()
        fileTranscriptionHotkeyManager = nil
        setupFileTranscriptionHotkey()
    }

    func refreshYouTubeTranscriptionHotkey() {
        youtubeTranscriptionHotkeyManager?.stop()
        youtubeTranscriptionHotkeyManager = nil
        setupYouTubeTranscriptionHotkey()
    }

    func applyMeetingHotkey(to item: NSMenuItem) {
        let trigger = settingsViewModel.meetingHotkeyTrigger
        guard trigger.kind == .chord, let code = trigger.keyCode else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            return
        }
        let keyName = KeyCodeNames.name(for: code).shortSymbol
        item.keyEquivalent = keyName.lowercased()
        var mask: NSEvent.ModifierFlags = []
        for modifier in trigger.chordModifiers ?? [] {
            switch modifier {
            case "command": mask.insert(.command)
            case "shift": mask.insert(.shift)
            case "control": mask.insert(.control)
            case "option": mask.insert(.option)
            default: break
            }
        }
        item.keyEquivalentModifierMask = mask
    }

    func stopAll() {
        hotkeyManager?.stop()
        meetingHotkeyManager?.stop()
        aiAssistantHotkeyManager?.stop()
        fileTranscriptionHotkeyManager?.stop()
        youtubeTranscriptionHotkeyManager?.stop()
        hotkeyManager = nil
        meetingHotkeyManager = nil
        aiAssistantHotkeyManager = nil
        fileTranscriptionHotkeyManager = nil
        youtubeTranscriptionHotkeyManager = nil
        onPrimaryHotkeyManagerChanged(nil)
    }
}
