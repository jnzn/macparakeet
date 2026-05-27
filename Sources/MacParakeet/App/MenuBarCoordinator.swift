import AppKit
import UniformTypeIdentifiers
import MacParakeetCore
import MacParakeetViewModels

@MainActor
final class MenuBarCoordinator: NSObject, NSMenuDelegate {
    private let transcriptionViewModel: TranscriptionViewModel
    private let youtubeInputController: YouTubeInputPanelController
    private let environmentProvider: () -> AppEnvironment?
    private let hotkeyMenuTitleProvider: () -> String
    private let meetingHotkeyTriggerProvider: () -> HotkeyTrigger
    private let fileTranscriptionHotkeyTriggerProvider: () -> HotkeyTrigger
    private let youtubeTranscriptionHotkeyTriggerProvider: () -> HotkeyTrigger
    private let meetingRecordingActiveProvider: () -> Bool
    private let voiceMemoHotkeyTriggerProvider: () -> HotkeyTrigger
    private let voiceMemoActiveProvider: () -> Bool
    private let onOpenMainWindow: () -> Void
    private let onOpenSettings: () -> Void
    private let onToggleMeetingRecording: () -> Void
    private let onToggleVoiceMemo: () -> Void
    private let onQuit: () -> Void
    private let onShowAboutPanel: () -> Void

    private var statusItem: NSStatusItem?
    private var pasteLastMenuItem: NSMenuItem?
    private var recentDictationsMenuItem: NSMenuItem?
    private var recordMeetingMenuItem: NSMenuItem?
    private var recordVoiceMemoMenuItem: NSMenuItem?
    private var transcribeFileMenuItem: NSMenuItem?
    private var transcribeYouTubeMenuItem: NSMenuItem?
    private var hotkeyMenuItem: NSMenuItem?
    private var processingMenuItem: NSMenuItem?

    /// Number of meetings transcribing in the background, and the flow's own
    /// requested icon state. The displayed icon reconciles both:
    /// recording > processing > flow state.
    private var processingCount = 0
    private var flowIconState: BreathWaveIcon.MenuBarState = .idle

    init(
        transcriptionViewModel: TranscriptionViewModel,
        youtubeInputController: YouTubeInputPanelController,
        environmentProvider: @escaping () -> AppEnvironment?,
        hotkeyMenuTitleProvider: @escaping () -> String,
        meetingHotkeyTriggerProvider: @escaping () -> HotkeyTrigger,
        fileTranscriptionHotkeyTriggerProvider: @escaping () -> HotkeyTrigger,
        youtubeTranscriptionHotkeyTriggerProvider: @escaping () -> HotkeyTrigger,
        meetingRecordingActiveProvider: @escaping () -> Bool,
        voiceMemoHotkeyTriggerProvider: @escaping () -> HotkeyTrigger,
        voiceMemoActiveProvider: @escaping () -> Bool,
        onOpenMainWindow: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onToggleMeetingRecording: @escaping () -> Void,
        onToggleVoiceMemo: @escaping () -> Void,
        onQuit: @escaping () -> Void,
        onShowAboutPanel: @escaping () -> Void
    ) {
        self.transcriptionViewModel = transcriptionViewModel
        self.youtubeInputController = youtubeInputController
        self.environmentProvider = environmentProvider
        self.hotkeyMenuTitleProvider = hotkeyMenuTitleProvider
        self.meetingHotkeyTriggerProvider = meetingHotkeyTriggerProvider
        self.fileTranscriptionHotkeyTriggerProvider = fileTranscriptionHotkeyTriggerProvider
        self.youtubeTranscriptionHotkeyTriggerProvider = youtubeTranscriptionHotkeyTriggerProvider
        self.meetingRecordingActiveProvider = meetingRecordingActiveProvider
        self.voiceMemoHotkeyTriggerProvider = voiceMemoHotkeyTriggerProvider
        self.voiceMemoActiveProvider = voiceMemoActiveProvider
        self.onOpenMainWindow = onOpenMainWindow
        self.onOpenSettings = onOpenSettings
        self.onToggleMeetingRecording = onToggleMeetingRecording
        self.onToggleVoiceMemo = onToggleVoiceMemo
        self.onQuit = onQuit
        self.onShowAboutPanel = onShowAboutPanel
    }

    func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()

        let aboutItem = NSMenuItem(
            title: "About PDX Edition",
            action: #selector(showAboutPanel),
            keyEquivalent: ""
        )
        aboutItem.target = self
        appMenu.addItem(aboutItem)
        appMenu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit PDX Edition",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        appMenu.addItem(quitItem)

        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let statusItem,
              let button = statusItem.button else { return }

        button.image = BreathWaveIcon.menuBarIcon(pointSize: 18)

        let dropView = MenuBarDropView(frame: button.bounds)
        dropView.onDrop = { [weak self] url in
            Task { @MainActor in
                self?.handleDroppedFile(url)
            }
        }
        button.addSubview(dropView)

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        let openItem = NSMenuItem(
            title: "Open PDX Edition",
            action: #selector(openMainWindow),
            keyEquivalent: "o"
        )
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(NSMenuItem.separator())

        let processingItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        processingItem.isEnabled = false
        processingItem.isHidden = true
        menu.addItem(processingItem)
        processingMenuItem = processingItem

        let pasteItem = NSMenuItem(
            title: "Paste Last Dictation",
            action: #selector(pasteLastDictation),
            keyEquivalent: ""
        )
        pasteItem.isEnabled = false
        pasteItem.target = self
        menu.addItem(pasteItem)
        pasteLastMenuItem = pasteItem

        let recentItem = NSMenuItem(
            title: "Recent Dictations",
            action: nil,
            keyEquivalent: ""
        )
        recentItem.submenu = NSMenu()
        recentItem.isHidden = true
        menu.addItem(recentItem)
        recentDictationsMenuItem = recentItem

        menu.addItem(NSMenuItem.separator())

        let transcribeFileItem = NSMenuItem(
            title: "Transcribe File...",
            action: #selector(transcribeFileFromMenu),
            keyEquivalent: ""
        )
        transcribeFileItem.target = self
        applyChordShortcut(fileTranscriptionHotkeyTriggerProvider(), to: transcribeFileItem)
        menu.addItem(transcribeFileItem)
        transcribeFileMenuItem = transcribeFileItem

        let transcribeYouTubeItem = NSMenuItem(
            title: "Transcribe from YouTube...",
            action: #selector(transcribeFromYouTubeMenu),
            keyEquivalent: ""
        )
        transcribeYouTubeItem.target = self
        applyChordShortcut(youtubeTranscriptionHotkeyTriggerProvider(), to: transcribeYouTubeItem)
        menu.addItem(transcribeYouTubeItem)
        transcribeYouTubeMenuItem = transcribeYouTubeItem

        if AppFeatures.meetingRecordingEnabled {
            let recordMeetingItem = NSMenuItem(
                title: "Record Meeting",
                action: #selector(toggleMeetingRecordingFromMenu),
                keyEquivalent: ""
            )
            recordMeetingItem.target = self
            applyChordShortcut(meetingHotkeyTriggerProvider(), to: recordMeetingItem)
            menu.addItem(recordMeetingItem)
            recordMeetingMenuItem = recordMeetingItem
        }

        let recordVoiceMemoItem = NSMenuItem(
            title: "Record Voice Memo",
            action: #selector(toggleVoiceMemoFromMenu),
            keyEquivalent: ""
        )
        recordVoiceMemoItem.target = self
        applyChordShortcut(voiceMemoHotkeyTriggerProvider(), to: recordVoiceMemoItem)
        menu.addItem(recordVoiceMemoItem)
        recordVoiceMemoMenuItem = recordVoiceMemoItem

        menu.addItem(NSMenuItem.separator())

        let hotkeyItem = NSMenuItem(
            title: hotkeyMenuTitleProvider(),
            action: nil,
            keyEquivalent: ""
        )
        hotkeyItem.isEnabled = false
        menu.addItem(hotkeyItem)
        hotkeyMenuItem = hotkeyItem

        let settingsItem = NSMenuItem(
            title: "Settings...",
            action: #selector(showSettingsWindow),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit PDX Edition",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    func refreshHotkeyTitle() {
        hotkeyMenuItem?.title = hotkeyMenuTitleProvider()
    }

    func refreshMeetingHotkeyShortcut() {
        guard let recordMeetingMenuItem else { return }
        applyChordShortcut(meetingHotkeyTriggerProvider(), to: recordMeetingMenuItem)
    }

    func refreshTranscriptionHotkeyShortcuts() {
        if let transcribeFileMenuItem {
            applyChordShortcut(fileTranscriptionHotkeyTriggerProvider(), to: transcribeFileMenuItem)
        }
        if let transcribeYouTubeMenuItem {
            applyChordShortcut(youtubeTranscriptionHotkeyTriggerProvider(), to: transcribeYouTubeMenuItem)
        }
    }

    func refreshVoiceMemoHotkeyShortcut() {
        guard let recordVoiceMemoMenuItem else { return }
        applyChordShortcut(voiceMemoHotkeyTriggerProvider(), to: recordVoiceMemoMenuItem)
    }

    /// Entry point for the file-transcription global hotkey. Shares its
    /// implementation with the menu-bar item so both behave identically.
    func invokeTranscribeFileFlow() {
        transcribeFileFlow()
    }

    /// Entry point for the YouTube-transcription global hotkey. Shares its
    /// implementation with the menu-bar item.
    func invokeTranscribeYouTubeFlow() {
        transcribeYouTubeFlow()
    }

    func updateIcon(state: BreathWaveIcon.MenuBarState) {
        flowIconState = state
        refreshDisplayedIcon()
    }

    /// Update the count of meetings transcribing in the background. Shows/hides
    /// the "N processing" menu row and keeps the icon in `.processing` while
    /// work is in flight (active recording still takes priority).
    func setProcessingCount(_ count: Int) {
        processingCount = max(0, count)
        processingMenuItem?.isHidden = processingCount == 0
        processingMenuItem?.title = processingCount == 1
            ? "\u{27F3} 1 meeting processing\u{2026}"
            : "\u{27F3} \(processingCount) meetings processing\u{2026}"
        refreshDisplayedIcon()
    }

    private func refreshDisplayedIcon() {
        let displayed: BreathWaveIcon.MenuBarState
        if flowIconState == .recording {
            displayed = .recording
        } else if processingCount > 0 {
            displayed = .processing
        } else {
            displayed = flowIconState
        }
        statusItem?.button?.image = BreathWaveIcon.menuBarIcon(pointSize: 18, state: displayed)
    }

    @objc private func showAboutPanel() {
        onShowAboutPanel()
    }

    @objc private func openMainWindow() {
        onOpenMainWindow()
    }

    // Named to avoid matching the macOS 14+ `openSettings:` system action,
    // which would trigger automatic gear SF Symbol decoration on the menu item.
    @objc private func showSettingsWindow() {
        onOpenSettings()
    }

    @objc private func quitApp() {
        onQuit()
    }

    @objc private func pasteLastDictation() {
        guard let env = environmentProvider() else { return }
        Task {
            guard let dictation = (try? env.dictationRepo.fetchAll(limit: 1))?.first else { return }
            let text = dictation.cleanTranscript ?? dictation.rawTranscript
            await pasteFromMenu(text: text, clipboardService: env.clipboardService)
        }
    }

    @objc private func pasteRecentDictation(_ sender: NSMenuItem) {
        guard let env = environmentProvider(),
              let id = sender.representedObject as? UUID else { return }
        Task {
            guard let dictation = try? env.dictationRepo.fetch(id: id) else { return }
            let text = dictation.cleanTranscript ?? dictation.rawTranscript
            await pasteFromMenu(text: text, clipboardService: env.clipboardService)
        }
    }

    @objc private func transcribeFileFromMenu() {
        transcribeFileFlow()
    }

    @objc private func transcribeFromYouTubeMenu() {
        transcribeYouTubeFlow()
    }

    private func transcribeFileFlow() {
        guard environmentProvider() != nil else { return }

        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = AudioFileConverter.supportedExtensions.compactMap {
            UTType(filenameExtension: $0)
        }

        if panel.runModal() == .OK, let url = panel.url {
            onOpenMainWindow()
            transcriptionViewModel.transcribeFile(url: url)
            SoundManager.shared.play(.fileDropped)
        }
    }

    private func transcribeYouTubeFlow() {
        guard environmentProvider() != nil else { return }
        youtubeInputController.show()
    }

    @objc private func toggleMeetingRecordingFromMenu() {
        onToggleMeetingRecording()
    }

    @objc private func toggleVoiceMemoFromMenu() {
        onToggleVoiceMemo()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let env = environmentProvider() else {
            pasteLastMenuItem?.isEnabled = false
            recentDictationsMenuItem?.isHidden = true
            return
        }

        let dictations = (try? env.dictationRepo.fetchAll(limit: 5)) ?? []
        pasteLastMenuItem?.isEnabled = !dictations.isEmpty
        rebuildRecentDictationsSubmenu(with: dictations)

        recordMeetingMenuItem?.title = meetingRecordingActiveProvider()
            ? "Stop Meeting Recording"
            : "Record Meeting"

        recordVoiceMemoMenuItem?.title = voiceMemoActiveProvider()
            ? "Stop Voice Memo"
            : "Record Voice Memo"
    }

    private func handleDroppedFile(_ url: URL) {
        onOpenMainWindow()
        transcriptionViewModel.transcribeFile(url: url)
        SoundManager.shared.play(.fileDropped)
    }

    /// Resign menu-bar focus, wait for the target app to regain focus, then paste.
    private func pasteFromMenu(text: String, clipboardService: ClipboardServiceProtocol) async {
        NSApp.deactivate()
        try? await Task.sleep(for: .milliseconds(200))
        do {
            try await clipboardService.pasteText(text)
        } catch {
            await clipboardService.copyToClipboard(text)
        }
    }

    private func rebuildRecentDictationsSubmenu(with dictations: [Dictation]) {
        guard let recentItem = recentDictationsMenuItem else { return }
        recentItem.isHidden = dictations.isEmpty

        let submenu = NSMenu()
        for dictation in dictations {
            let text = (dictation.cleanTranscript ?? dictation.rawTranscript)
                .replacingOccurrences(of: "\n", with: " ")
            let truncated = text.count > 40 ? String(text.prefix(40)) + "…" : text
            let item = NSMenuItem(
                title: truncated,
                action: #selector(pasteRecentDictation(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = dictation.id
            submenu.addItem(item)
        }
        recentItem.submenu = submenu
    }

    /// Apply a chord trigger's visual shortcut to a menu item. Non-chord or
    /// disabled triggers clear the key equivalent.
    ///
    /// Note: this only paints the visual hint. The actual hotkey is handled by
    /// `GlobalShortcutManager` in the app layer, so keyEquivalent matches
    /// aren't required for the shortcut to fire while the menu is closed.
    private func applyChordShortcut(_ trigger: HotkeyTrigger, to item: NSMenuItem) {
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
}
