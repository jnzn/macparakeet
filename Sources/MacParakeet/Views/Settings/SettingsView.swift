import Foundation
import Sparkle
import SwiftUI
import AppKit
import MacParakeetCore
import MacParakeetViewModels

struct SettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    @Bindable var llmSettingsViewModel: LLMSettingsViewModel
    let updater: SPUUpdater

    @State private var rootViewModel = SettingsRootViewModel()
    @FocusState private var searchFieldFocused: Bool
    /// Set when a search-result row is tapped. Each tab's `ScrollView`
    /// watches this via `.task(id:)`; whichever ScrollView is on screen
    /// when this transitions to a non-nil anchor scrolls itself there
    /// and clears the target. Using `task(id:)` (not `onChange`) so it
    /// fires both on transition AND on initial mount of the destination
    /// tab — important because tapping a result almost always triggers
    /// a tab swap, which mounts a new ScrollView.
    @State private var pendingScrollTarget: String?
    @State private var automaticallyChecksForUpdates: Bool
    @State private var automaticallyDownloadsUpdates: Bool
    @State private var copiedBuildIdentity = false

    init(viewModel: SettingsViewModel, llmSettingsViewModel: LLMSettingsViewModel, updater: SPUUpdater) {
        self.viewModel = viewModel
        self.llmSettingsViewModel = llmSettingsViewModel
        self.updater = updater
        self._automaticallyChecksForUpdates = State(initialValue: updater.automaticallyChecksForUpdates)
        self._automaticallyDownloadsUpdates = State(initialValue: updater.automaticallyDownloadsUpdates)
    }

    var body: some View {
        VStack(spacing: 0) {
            settingsHeaderShell
                .padding(.horizontal, DesignSystem.Spacing.lg)
                .padding(.top, DesignSystem.Spacing.md)
                .padding(.bottom, DesignSystem.Spacing.sm)

            // The tab bar stays visible during search so the user can
            // bail back to a tab at any time. Search results replace
            // the tab body; pending scroll targets only fire after the
            // user picks a result and the destination tab mounts.
            //
            // The animation crossfades the body when entering/exiting
            // search. Tab-to-tab swaps stay snappy: only `isSearching`
            // is animated, not `activeTab`.
            Group {
                if rootViewModel.isSearching {
                    SettingsSearchResultsList(
                        results: SettingsSearchIndex.matches(rootViewModel.searchQuery),
                        onSelect: handleSearchResultTap
                    )
                } else {
                    switch rootViewModel.activeTab {
                    case .modes:
                        modesTabContent
                    case .engine:
                        engineTabContent
                    case .ai:
                        aiTabContent
                    case .system:
                        systemTabContent
                    }
                }
            }
            .animation(DesignSystem.Animation.contentSwap, value: rootViewModel.isSearching)
        }
        .background(DesignSystem.Colors.background)
        .background(focusSearchHotkey)
        .onAppear {
            viewModel.refreshLaunchAtLoginStatus()
            viewModel.startPermissionPolling()
            viewModel.refreshStats()
            viewModel.refreshEntitlements()
            viewModel.refreshModelStatus()
            viewModel.refreshPendingMeetingRecoveries()
        }
        .onDisappear {
            viewModel.stopPermissionPolling()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            viewModel.refreshPermissions()
        }
    }

    // MARK: - Tabbed Shell

    /// Top-of-panel header: tab bar on the left, search field on the right.
    /// Tab badges roll up the worst per-card status the user can act on.
    /// `.ok` / `.info` are intentionally silent on the badges — a
    /// permanent green dot would just be visual debt.
    private var settingsHeaderShell: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            SettingsTabBar(
                activeTab: tabBindingExitingSearch,
                tabBadges: tabBadges
            )

            Spacer(minLength: DesignSystem.Spacing.md)

            SettingsSearchField(
                query: $rootViewModel.searchQuery,
                isFocused: $searchFieldFocused
            )
            .frame(maxWidth: 280)
        }
    }

    /// Per-tab attention badges. Only `.required` and `.recommended`
    /// surface here — they're the two states that mean "the user has
    /// something to do on this tab." `resetCleanupCard`'s `.required
    /// "Destructive"` chip is intentionally excluded: the chip is a
    /// severity *label* on a deliberate destination, not an action item.
    /// Wraps `rootViewModel.activeTab` so that any tab tap during search
    /// also exits search mode. Without this, the body stays gated on
    /// `isSearching` first and the tab pill slides over to the new tab
    /// while the search results remain on screen — the click looks
    /// accepted but nothing useful happens. `clearSearch()` is a no-op
    /// when not searching, so non-search tab taps are unaffected.
    private var tabBindingExitingSearch: Binding<SettingsTab> {
        Binding(
            get: { rootViewModel.activeTab },
            set: { newTab in
                rootViewModel.activeTab = newTab
                rootViewModel.clearSearch()
            }
        )
    }

    private var tabBadges: [SettingsTab: SettingsStatusChip.Status] {
        var badges: [SettingsTab: SettingsStatusChip.Status] = [:]

        var modesStatuses: [SettingsCardStatus?] = [
            viewModel.microphoneGranted
                ? SettingsCardStatus(.ok, label: "Granted")
                : SettingsCardStatus(.required, label: "Permission required")
        ]
        if AppFeatures.meetingRecordingEnabled {
            modesStatuses.append(meetingRecordingCardStatus)
        }
        if let badge = Self.attentionBadge(for: modesStatuses) {
            badges[.modes] = badge
        }

        if let badge = Self.attentionBadge(for: [
            engineSelectorCardStatus,
            enginesModelsCardStatus
        ]) {
            badges[.engine] = badge
        }

        if let badge = Self.attentionBadge(for: [aiProviderCardStatus]) {
            badges[.ai] = badge
        }

        if let badge = Self.attentionBadge(for: [permissionsCardStatus]) {
            badges[.system] = badge
        }

        return badges
    }

    /// Picks the worst actionable severity from a card-status list, or
    /// returns nil when nothing is actionable (`.ok` / `.info` / no chip
    /// at all). Static so it can't accidentally read view state.
    private static func attentionBadge(for statuses: [SettingsCardStatus?]) -> SettingsStatusChip.Status? {
        let actual = statuses.compactMap { $0?.status }
        if actual.contains(.required) { return .required }
        if actual.contains(.recommended) { return .recommended }
        return nil
    }

    /// Search-result tap handler. Order of operations matters:
    /// 1. Set the scroll target so `task(id:)` on the destination tab's
    ///    ScrollView sees a non-nil value when it mounts.
    /// 2. Switch to the result's tab — this swaps the body away from
    ///    the search results and into the destination tab's ScrollView.
    /// 3. Clear the search query — this also drops `isSearching` to
    ///    false. SwiftUI batches these so the user perceives one swap.
    private func handleSearchResultTap(_ entry: SettingsSearchEntry) {
        pendingScrollTarget = entry.cardAnchor
        rootViewModel.activeTab = entry.tab
        rootViewModel.clearSearch()
    }

    /// Hidden button that registers ⌘F as a focus shortcut. Lives in a
    /// `.background` so it's not visible but still reachable by the
    /// keyboard-shortcut dispatcher. macOS convention.
    private var focusSearchHotkey: some View {
        Button("Focus Search") {
            searchFieldFocused = true
        }
        .keyboardShortcut("f", modifiers: .command)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    /// Modes tab — daily-ops config for the three product modes, plus the
    /// Audio Input prerequisite that gates them. The legacy `headerCard`
    /// "Workspace Controls" was eliminated (its stat chips are redundant
    /// with Storage / Permissions / per-mode chips). The legacy `generalCard`
    /// was split: "Show idle pill" lives on the Dictation card now;
    /// Launch at Login + Menu Bar Only moved to the System Startup card.
    /// The Calendar card was folded into Meeting Recording.
    private var modesTabContent: some View {
        scrollableTabBody {
            audioInputCard.id("audio.input")
            dictationCard.id("dictation")
            transcriptionCard.id("transcription")
            if AppFeatures.meetingRecordingEnabled {
                meetingRecordingCard.id("meeting")
            }
        }
    }

    /// Engine tab — speech recognition stack, decomposed into three cards
    /// so each surface owns one decision the user makes:
    ///
    /// 1. `engineSelectorCard` — which engine? (Parakeet vs Whisper)
    /// 2. `engineLanguageCard` — which language? (Whisper only — Parakeet
    ///    auto-detects from its 25 supported European languages)
    /// 3. `enginesModelsCard` — what's the local model state?
    ///
    /// Sub-VM split (`EngineSettingsViewModel`) lands in a later commit;
    /// the cards keep reading from `viewModel` for now.
    private var engineTabContent: some View {
        scrollableTabBody {
            engineSelectorCard.id("engine.selector")
            engineLanguageCard.id("engine.language")
            enginesModelsCard.id("engine.models")
        }
    }

    /// AI tab — LLM provider config. The card embeds `LLMSettingsView`,
    /// which already serves as its own first-run UX (the provider picker
    /// IS the call to action), so a separate empty-state card would be
    /// redundant. The header chip rolls up the latest signal we have:
    /// per locked decision #5 we never go red on the AI surface (it's
    /// opt-in), and we only flag yellow on a real failure the user
    /// can act on.
    private var aiTabContent: some View {
        scrollableTabBody {
            aiProviderCard.id("ai.provider")
        }
    }

    /// System tab — everything that isn't daily-ops, ordered by frequency of
    /// use. Destructive controls are fenced off at the bottom inside
    /// `resetCleanupCard`, separated by a visible divider so a user
    /// scrolling through configuration can't fat-finger a wipe.
    private var systemTabContent: some View {
        scrollableTabBody {
            startupCard.id("system.startup")
            permissionsCard.id("system.permissions")
            storageCard.id("system.storage")
            updatesCard.id("system.updates")
            privacyCard.id("system.privacy")
            onboardingCard.id("system.onboarding")
            aboutCard.id("system.about")

            resetCleanupSeparator
            resetCleanupCard.id("system.reset")
        }
    }

    /// Common scaffold for all four tab bodies: ScrollView wrapped in a
    /// `ScrollViewReader`, with a `.task(id: pendingScrollTarget)` that
    /// scrolls to a search-result anchor when the parent sets one.
    ///
    /// Using `task(id:)` (not `onChange`) means we react both to in-tab
    /// transitions AND to the destination tab's freshly-mounted ScrollView
    /// — important because tapping a search result usually triggers a
    /// tab swap, mounting a new ScrollView that needs to scroll to a
    /// target the parent set just before the swap.
    @ViewBuilder
    private func scrollableTabBody<Content: View>(
        @ViewBuilder _ cards: @escaping () -> Content
    ) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    cards()
                }
                .padding(DesignSystem.Spacing.lg)
            }
            .task(id: pendingScrollTarget) {
                guard let target = pendingScrollTarget else { return }
                // Tiny delay so the destination ScrollView has had a
                // layout pass before we ask it to scroll. Without this,
                // scrollTo on a freshly-mounted ScrollView is a no-op
                // because the target id isn't registered yet.
                try? await Task.sleep(nanoseconds: 50_000_000)
                withAnimation(DesignSystem.Animation.contentSwap) {
                    proxy.scrollTo(target, anchor: .top)
                }
                pendingScrollTarget = nil
            }
        }
    }

    /// Visual fence between configuration and destructive operations.
    /// "Danger zone"-style cue without the heavy chrome — a faint divider
    /// plus a small caption is enough signal at the cadence the user
    /// actually scans this tab.
    private var resetCleanupSeparator: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Rectangle()
                .fill(DesignSystem.Colors.border.opacity(0.4))
                .frame(height: 0.5)
                .padding(.top, DesignSystem.Spacing.sm)

            Text("Reset & Cleanup")
                .font(DesignSystem.Typography.caption.weight(.medium))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .tracking(0.6)
        }
    }

    // MARK: - Audio Input

    private var audioInputCard: some View {
        SettingsCard(
            title: "Audio Input",
            subtitle: "Choose the microphone used for dictation and meetings.",
            icon: "mic",
            status: viewModel.microphoneGranted
                ? SettingsCardStatus(.ok, label: "Granted")
                : SettingsCardStatus(.required, label: "Permission required")
        ) {
            VStack(spacing: DesignSystem.Spacing.md) {
                HStack(alignment: .center) {
                    rowText(
                        title: "Microphone",
                        detail: viewModel.selectedMicrophoneStatusText
                    )
                    Spacer(minLength: DesignSystem.Spacing.md)
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Picker("Microphone", selection: $viewModel.selectedMicrophoneDeviceUID) {
                            Text("System Default").tag(SettingsViewModel.systemDefaultMicrophoneSelection)
                            ForEach(viewModel.microphoneDeviceOptions) { device in
                                Text(device.displayName).tag(device.uid)
                                    .disabled(!device.isAvailable)
                            }
                        }
                        .labelsHidden()
                        .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)

                        Button {
                            viewModel.refreshMicrophoneDevices()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .help("Refresh microphones")
                        .accessibilityLabel("Refresh microphones")
                    }
                }

                Divider()

                HStack(alignment: .center, spacing: DesignSystem.Spacing.md) {
                    microphoneTestStatus
                    Spacer(minLength: DesignSystem.Spacing.md)
                    Button {
                        switch viewModel.microphoneTestState {
                        case .testing:
                            viewModel.cancelMicrophoneTest()
                        default:
                            viewModel.testSelectedMicrophone()
                        }
                    } label: {
                        Label(
                            viewModel.microphoneTestState == .testing ? "Stop Test" : "Test Input",
                            systemImage: viewModel.microphoneTestState == .testing ? "stop.fill" : "waveform"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignSystem.Colors.accent)
                    .disabled(!viewModel.microphoneGranted && viewModel.microphoneTestState != .testing)
                }
            }
        }
    }

    private var microphoneTestStatus: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            microphoneLevelMeter(level: viewModel.microphoneTestLevel)
            VStack(alignment: .leading, spacing: 2) {
                Text(microphoneTestTitle)
                    .font(DesignSystem.Typography.body)
                Text(microphoneTestDetail)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(microphoneTestDetailColor)
                    .lineLimit(2)
            }
        }
    }

    private var microphoneTestTitle: String {
        switch viewModel.microphoneTestState {
        case .idle:
            return "Input test"
        case .testing:
            return "Listening..."
        case .succeeded:
            return "Input detected"
        case .failed:
            return "Input test failed"
        }
    }

    private var microphoneTestDetail: String {
        switch viewModel.microphoneTestState {
        case .idle:
            return viewModel.microphoneGranted ? "Run a short level check before recording." : "Grant microphone permission before testing."
        case .testing:
            return "Speak into the selected microphone."
        case .succeeded:
            return "This microphone is producing audio."
        case .failed(let message):
            return message
        }
    }

    private var microphoneTestDetailColor: Color {
        switch viewModel.microphoneTestState {
        case .failed:
            return DesignSystem.Colors.errorRed
        default:
            return .secondary
        }
    }

    private func microphoneLevelMeter(level: Float) -> some View {
        GeometryReader { proxy in
            let clamped = CGFloat(max(0, min(1, level)))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(DesignSystem.Colors.surfaceElevated)
                Capsule()
                    .fill(DesignSystem.Colors.accent)
                    .frame(width: max(6, proxy.size.width * clamped))
                    .animation(.easeOut(duration: 0.12), value: clamped)
            }
        }
        .frame(width: 96, height: 8)
        .accessibilityLabel("Microphone input level")
        .accessibilityValue("\(Int(max(0, min(1, level)) * 100)) percent")
    }

    // MARK: - Startup

    /// OS-integration card in System tab. Renamed from the legacy
    /// `generalCard` and stripped of "Show idle pill" (which moved to the
    /// Dictation card during the IA refactor — the idle pill is a
    /// dictation-UX choice, not OS chrome).
    private var startupCard: some View {
        settingsCard(
            title: "Startup",
            subtitle: "How MacParakeet shows up on your Mac at sign-in.",
            icon: "power"
        ) {
            VStack(spacing: DesignSystem.Spacing.md) {
                settingsToggleRow(
                    title: "Launch at login",
                    detail: "Start MacParakeet automatically when you sign in.",
                    isOn: $viewModel.launchAtLogin
                )

                if !viewModel.launchAtLoginDetail.isEmpty || viewModel.launchAtLoginError != nil {
                    VStack(alignment: .leading, spacing: 4) {
                        if !viewModel.launchAtLoginDetail.isEmpty {
                            Text(viewModel.launchAtLoginDetail)
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let error = viewModel.launchAtLoginError {
                            Text(error)
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.errorRed)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider()

                settingsToggleRow(
                    title: "Menu bar only mode",
                    detail: "Hide the Dock icon and run from the menu bar only.",
                    isOn: $viewModel.menuBarOnlyMode
                )
            }
        }
    }

    // MARK: - Dictation

    private var dictationCard: some View {
        settingsCard(
            title: "Dictation",
            subtitle: "Global hotkey and silence behavior.",
            icon: "waveform"
        ) {
            VStack(spacing: DesignSystem.Spacing.md) {
                HStack(alignment: .center) {
                    rowText(
                        title: "Hotkey",
                        detail: "System-wide key used to start and stop dictation."
                    )
                    Spacer(minLength: DesignSystem.Spacing.md)
                    VStack(alignment: .trailing, spacing: 4) {
                        HotkeyRecorderView(trigger: $viewModel.hotkeyTrigger) { candidate in
                            guard AppFeatures.meetingRecordingEnabled else { return .allowed }
                            guard !candidate.isDisabled, candidate == viewModel.meetingHotkeyTrigger else { return .allowed }
                            return .blocked("Already used by meeting recording.")
                        }

                        if AppFeatures.meetingRecordingEnabled,
                           !viewModel.hotkeyTrigger.isDisabled,
                           viewModel.hotkeyTrigger == viewModel.meetingHotkeyTrigger {
                            hotkeyConflictText
                        }
                    }
                }

                if !viewModel.hotkeyTrigger.isDisabled {
                    Divider()

                    dictationModeGuide
                }

                Divider()

                settingsToggleRow(
                    title: "Auto-stop after silence",
                    detail: "Stops recording when speech pauses for the selected delay.",
                    isOn: $viewModel.silenceAutoStop
                )

                if viewModel.silenceAutoStop {
                    Divider()
                    HStack(alignment: .center) {
                        rowText(
                            title: "Silence delay",
                            detail: "How long silence must persist before dictation stops."
                        )
                        Spacer(minLength: DesignSystem.Spacing.md)
                        Picker("Silence delay", selection: $viewModel.silenceDelay) {
                            Text("1 sec").tag(1.0)
                            Text("1.5 sec").tag(1.5)
                            Text("2 sec").tag(2.0)
                            Text("3 sec").tag(3.0)
                            Text("5 sec").tag(5.0)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 140)
                    }
                }

                Divider()

                // Relocated from the legacy `generalCard` during the IA
                // refactor. The idle pill *is* the dictation summon button,
                // so it belongs alongside the dictation hotkey, not in the
                // OS-integration startup section.
                settingsToggleRow(
                    title: "Show dictation pill at all times",
                    detail: "When off, the pill hides until you press the hotkey.",
                    isOn: $viewModel.showIdlePill
                )
            }
        }
    }

    // MARK: - Transcription

    private var meetingRecordingCard: some View {
        SettingsCard(
            title: "Meeting Recording",
            subtitle: "System-audio + mic capture, with optional calendar auto-start.",
            icon: "record.circle",
            status: meetingRecordingCardStatus
        ) {
            VStack(spacing: DesignSystem.Spacing.md) {
                HStack(alignment: .center) {
                    rowText(
                        title: "Meeting hotkey",
                        detail: "Global shortcut that immediately starts or stops meeting recording."
                    )
                    Spacer(minLength: DesignSystem.Spacing.md)
                    VStack(alignment: .trailing, spacing: 4) {
                        HotkeyRecorderView(
                            trigger: $viewModel.meetingHotkeyTrigger,
                            defaultTrigger: .defaultMeetingRecording
                        ) { candidate in
                            guard !candidate.isDisabled, candidate == viewModel.hotkeyTrigger else { return .allowed }
                            return .blocked("Already used by dictation.")
                        }

                        if !viewModel.meetingHotkeyTrigger.isDisabled, viewModel.hotkeyTrigger == viewModel.meetingHotkeyTrigger {
                            hotkeyConflictText
                        }
                    }
                }

                if viewModel.pendingMeetingRecoveryCount > 0 {
                    Divider()

                    HStack(alignment: .center) {
                        rowText(
                            title: "Pending recovery",
                            detail: "\(viewModel.pendingMeetingRecoveryCount) partial recording\(viewModel.pendingMeetingRecoveryCount == 1 ? "" : "s")"
                        )
                        Spacer(minLength: DesignSystem.Spacing.md)
                        Button {
                            viewModel.requestPendingMeetingRecovery()
                        } label: {
                            Label("Recover", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Divider()

                settingsToggleRow(
                    title: "Auto-save meetings to disk",
                    detail: "Automatically write a file to the chosen folder after every meeting recording completes.",
                    isOn: $viewModel.meetingAutoSave
                )

                if viewModel.meetingAutoSave {
                    meetingAutoSaveOptionsView
                }

                Divider()

                // Calendar section folded in from the legacy standalone
                // `calendarCard`. Calendar is meeting-only — folding it
                // here removes a card without losing any controls.
                meetingCalendarSection
            }
        }
    }

    /// Header status chip for the Meeting Recording card. Surfaces the
    /// screen-recording-permission state since system audio capture is
    /// gated on it.
    private var meetingRecordingCardStatus: SettingsCardStatus? {
        SettingsStatusRules.meetingRecordingCardStatus(
            meetingRecordingEnabled: AppFeatures.meetingRecordingEnabled,
            screenRecordingGranted: viewModel.screenRecordingGranted
        )
    }

    /// Calendar auto-start controls, rendered inline within the Meeting
    /// Recording card after the auto-save section. Visually demoted to a
    /// section heading so it reads as part of meeting setup.
    private var meetingCalendarSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Calendar auto-start")
                    .font(DesignSystem.Typography.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            CalendarSettingsView(viewModel: viewModel)
        }
    }

    private var meetingAutoSaveOptionsView: some View {
        autoSaveOptions(
            format: $viewModel.meetingAutoSaveFormat,
            folderPath: viewModel.meetingAutoSaveFolderPath,
            formatDetail: "File format for saved meetings.",
            panelMessage: "Select a folder for auto-saved meeting recordings",
            onChooseFolder: { viewModel.chooseMeetingAutoSaveFolder(url: $0) },
            onClearFolder: { viewModel.clearMeetingAutoSaveFolder() }
        )
    }

    private var transcriptionCard: some View {
        settingsCard(
            title: "Transcription",
            subtitle: "Options for file and YouTube transcription.",
            icon: "doc.text"
        ) {
            VStack(spacing: DesignSystem.Spacing.md) {
                transcriptionHotkeyRow(
                    title: "File transcription hotkey",
                    detail: "Opens the file picker from anywhere on macOS.",
                    trigger: $viewModel.fileTranscriptionHotkeyTrigger,
                    otherTranscriptionTrigger: viewModel.youtubeTranscriptionHotkeyTrigger,
                    otherTranscriptionName: "YouTube transcription"
                )

                Divider()

                transcriptionHotkeyRow(
                    title: "YouTube transcription hotkey",
                    detail: "Opens the YouTube URL panel from anywhere on macOS.",
                    trigger: $viewModel.youtubeTranscriptionHotkeyTrigger,
                    otherTranscriptionTrigger: viewModel.fileTranscriptionHotkeyTrigger,
                    otherTranscriptionName: "file transcription"
                )

                Divider()

                settingsToggleRow(
                    title: "Speaker detection",
                    detail: "Identify who said what using Pyannote community-1. Typically ~85% accurate — best with clear audio and distinct voices.",
                    isOn: $viewModel.speakerDiarization
                )

                Divider()

                settingsToggleRow(
                    title: "Auto-save transcripts to disk",
                    detail: "Automatically write a file to the chosen folder after every transcription completes.",
                    isOn: $viewModel.autoSaveTranscripts
                )

                if viewModel.autoSaveTranscripts {
                    autoSaveOptionsView
                }
            }
        }
    }

    /// A transcription-hotkey row with a recorder and an inline conflict
    /// warning when the trigger collides with dictation, meeting, or the
    /// other transcription hotkey. Default trigger is `.disabled` — users opt
    /// in by recording a key.
    private func transcriptionHotkeyRow(
        title: String,
        detail: String,
        trigger: Binding<HotkeyTrigger>,
        otherTranscriptionTrigger: HotkeyTrigger,
        otherTranscriptionName: String
    ) -> some View {
        HStack(alignment: .center) {
            rowText(title: title, detail: detail)
            Spacer(minLength: DesignSystem.Spacing.md)
            VStack(alignment: .trailing, spacing: 4) {
                HotkeyRecorderView(
                    trigger: trigger,
                    defaultTrigger: .disabled
                ) { candidate in
                    guard !candidate.isDisabled else { return .allowed }
                    if candidate == viewModel.hotkeyTrigger {
                        return .blocked("Already used by dictation.")
                    }
                    if AppFeatures.meetingRecordingEnabled, candidate == viewModel.meetingHotkeyTrigger {
                        return .blocked("Already used by meeting recording.")
                    }
                    if candidate == otherTranscriptionTrigger {
                        return .blocked("Already used by \(otherTranscriptionName).")
                    }
                    return .allowed
                }

                if let conflict = conflictMessage(
                    trigger: trigger.wrappedValue,
                    otherTranscription: otherTranscriptionTrigger,
                    otherTranscriptionName: otherTranscriptionName
                ) {
                    transcriptionHotkeyConflictText(conflict)
                }
            }
        }
    }

    private func conflictMessage(
        trigger: HotkeyTrigger,
        otherTranscription: HotkeyTrigger,
        otherTranscriptionName: String
    ) -> String? {
        guard !trigger.isDisabled else { return nil }
        if trigger == viewModel.hotkeyTrigger {
            return "Disabled — conflicts with dictation hotkey."
        }
        if AppFeatures.meetingRecordingEnabled, trigger == viewModel.meetingHotkeyTrigger {
            return "Disabled — conflicts with meeting recording hotkey."
        }
        if trigger == otherTranscription {
            return "Disabled — conflicts with \(otherTranscriptionName) hotkey."
        }
        return nil
    }

    private func transcriptionHotkeyConflictText(_ message: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 10))
            Text(message)
                .font(DesignSystem.Typography.micro)
        }
        .foregroundStyle(DesignSystem.Colors.errorRed)
    }

    private var hotkeyConflictText: some View {
        HStack(spacing: 4) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 10))
            Text("Dictation and meeting recording cannot use the same shortcut.")
                .font(DesignSystem.Typography.micro)
        }
        .foregroundStyle(DesignSystem.Colors.errorRed)
    }

    private var autoSaveOptionsView: some View {
        autoSaveOptions(
            format: $viewModel.autoSaveFormat,
            folderPath: viewModel.autoSaveFolderPath,
            formatDetail: "File format for saved transcripts.",
            panelMessage: "Select a folder for auto-saved transcripts",
            onChooseFolder: { viewModel.chooseAutoSaveFolder(url: $0) },
            onClearFolder: { viewModel.clearAutoSaveFolder() }
        )
    }

    private func autoSaveOptions(
        format: Binding<AutoSaveFormat>,
        folderPath: String?,
        formatDetail: String,
        panelMessage: String,
        onChooseFolder: @escaping (URL) -> Void,
        onClearFolder: @escaping () -> Void
    ) -> some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            HStack {
                rowText(title: "Format", detail: formatDetail)
                Spacer(minLength: DesignSystem.Spacing.md)
                Picker("", selection: format) {
                    ForEach(AutoSaveFormat.allCases, id: \.self) { fmt in
                        Text(fmt.displayName).tag(fmt)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Folder")
                        .font(DesignSystem.Typography.body)
                    if let path = folderPath {
                        Text(path)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("No folder selected")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: DesignSystem.Spacing.md)
                if folderPath != nil {
                    Button("Clear") { onClearFolder() }
                        .buttonStyle(.bordered)
                }
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    panel.allowsMultipleSelection = false
                    panel.prompt = "Choose"
                    panel.message = panelMessage
                    if panel.runModal() == .OK, let url = panel.url {
                        onChooseFolder(url)
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(DesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated)
        )
    }

    // MARK: - AI Provider

    private var aiProviderCard: some View {
        SettingsCard(
            title: "AI Provider",
            subtitle: "Optional. Powers transcript summaries and chat.",
            icon: "brain",
            status: aiProviderCardStatus
        ) {
            LLMSettingsView(viewModel: llmSettingsViewModel)
        }
    }

    /// AI tab is opt-in, so this never returns `.required`. We only show
    /// signal when there is something actionable: yellow when the last
    /// connection test failed (the user pressed "Test Connection" and it
    /// errored), green when a saved configuration exists and nothing is
    /// currently broken. Silent in the not-yet-configured state — the
    /// card body already explains the empty case.
    private var aiProviderCardStatus: SettingsCardStatus? {
        if case .error = llmSettingsViewModel.connectionTestState {
            return SettingsCardStatus(.recommended, label: "Last test failed")
        }
        if llmSettingsViewModel.isConfigured {
            return SettingsCardStatus(.ok, label: "Configured")
        }
        return nil
    }

    // MARK: - Storage

    /// Storage card is read-only stats + retention toggles. Destructive
    /// operations moved to `resetCleanupCard` so the configuration surface
    /// can stay scrollable without exposing a wipe button to a misclick.
    private var storageCard: some View {
        SettingsCard(
            title: "Storage",
            subtitle: "Retention preferences and current disk usage.",
            icon: "internaldrive"
        ) {
            VStack(spacing: DesignSystem.Spacing.md) {
                settingsToggleRow(
                    title: "Save dictation history",
                    detail: "When off, dictations are transcribed and pasted but not saved. Voice stats still tracked.",
                    isOn: $viewModel.saveDictationHistory
                )

                Divider()

                settingsToggleRow(
                    title: "Save audio recordings",
                    detail: "Keep audio alongside your dictation history.",
                    isOn: $viewModel.saveAudioRecordings
                )

                Divider()

                settingsToggleRow(
                    title: "Keep downloaded YouTube audio",
                    detail: "Turn off to auto-delete downloaded audio after transcription.",
                    isOn: $viewModel.saveTranscriptionAudio
                )

                Divider()

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 190), spacing: DesignSystem.Spacing.md)],
                    spacing: DesignSystem.Spacing.md
                ) {
                    metricTile(
                        title: "Dictation Records",
                        value: "\(viewModel.dictationCount)",
                        detail: viewModel.dictationCount == 1 ? "entry" : "entries"
                    )

                    metricTile(
                        title: "YouTube Downloads",
                        value: "\(viewModel.youtubeDownloadCount)",
                        detail: viewModel.formattedYouTubeStorage
                    )
                }
            }
        }
    }

    // MARK: - Reset & Cleanup

    /// Holds every destructive operation in the app. Lives at the bottom of
    /// the System tab behind a visible divider; the card itself uses the
    /// `.required` chip semantically (red dot) to telegraph severity even
    /// when the user lands here scrolled past the divider.
    private var resetCleanupCard: some View {
        SettingsCard(
            title: "Reset & Cleanup",
            subtitle: "Permanent. These cannot be undone.",
            icon: "trash",
            status: SettingsCardStatus(.required, label: "Destructive")
        ) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                maintenanceGroup(
                    label: "Delete data",
                    detail: "Removes rows from your library. Lifetime stats are preserved."
                ) {
                    SettingsDestructiveButton(
                        title: "Clear All Dictations...",
                        confirmationTitle: "Clear All Dictations?",
                        confirmationMessage: "This will permanently delete all \(viewModel.dictationCount) dictation\(viewModel.dictationCount == 1 ? "" : "s"), their audio files, and any private metric-only entries. Lifetime stats are not affected. This cannot be undone.",
                        confirmButtonLabel: "Clear All"
                    ) {
                        viewModel.clearAllDictations()
                    }

                    SettingsDestructiveButton(
                        title: "Clear Downloaded YouTube Audio...",
                        confirmationTitle: "Clear Downloaded YouTube Audio?",
                        confirmationMessage: "This will permanently delete all downloaded YouTube audio files and detach them from existing transcriptions.",
                        confirmButtonLabel: "Clear Audio"
                    ) {
                        viewModel.clearDownloadedYouTubeAudio()
                    }
                }

                maintenanceGroup(
                    label: "Reset counters",
                    detail: "Zeros lifetime stats. Your dictation history is untouched."
                ) {
                    SettingsDestructiveButton(
                        title: "Reset Lifetime Stats...",
                        confirmationTitle: "Reset Lifetime Stats?",
                        confirmationMessage: "This will zero your total words, total time, total dictation count, and longest dictation. Your dictation history is not affected. This cannot be undone.",
                        confirmButtonLabel: "Reset"
                    ) {
                        viewModel.resetLifetimeStats()
                    }
                }
            }
            .padding(DesignSystem.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                    .fill(DesignSystem.Colors.errorRed.opacity(0.06))
            )
        }
    }

    // MARK: - Engine

    /// Engine card: which speech recognition engine to use. Status chip
    /// surfaces only signal — silent in the steady state, `.info` while
    /// switching, `.required` if the last switch failed (the existing red
    /// inline error is preserved underneath for the full message).
    private var engineSelectorCard: some View {
        SettingsCard(
            title: "Speech Recognition",
            subtitle: "Parakeet is fastest. Whisper adds Korean and broader multilingual coverage.",
            icon: "cpu",
            status: engineSelectorCardStatus
        ) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                HStack(alignment: .center) {
                    rowText(
                        title: "Engine",
                        detail: viewModel.speechEngineSwitching
                            ? "Switching speech engine..."
                            : "Used by dictation, file transcription, and meetings."
                    )
                    Spacer(minLength: DesignSystem.Spacing.md)
                    Picker("Speech Engine", selection: $viewModel.speechEnginePreference) {
                        Text("Parakeet").tag(SpeechEnginePreference.parakeet)
                        Text("Whisper").tag(SpeechEnginePreference.whisper)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                    .disabled(viewModel.speechEngineSwitching)
                }

                if let error = viewModel.speechEngineError {
                    Text(error)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.errorRed)
                }
            }
        }
    }

    /// Whisper-only language card. Stays visible when Parakeet is active so
    /// the user knows the control exists; the picker mutes itself and the
    /// header chip reads "Inactive" so the visual state matches reality.
    /// The picker button itself surfaces the current selection — no need for
    /// a redundant left-side label.
    private var engineLanguageCard: some View {
        let isWhisperActive = viewModel.speechEnginePreference == .whisper
        return SettingsCard(
            title: "Whisper Language",
            subtitle: "Only used when Whisper is the active engine. Auto-detect works for most files.",
            icon: "globe",
            status: isWhisperActive ? nil : SettingsCardStatus(.info, label: "Inactive")
        ) {
            HStack(alignment: .center) {
                Text("Default language")
                    .font(DesignSystem.Typography.body)
                Spacer(minLength: DesignSystem.Spacing.md)
                LanguagePickerButton(
                    selection: $viewModel.whisperDefaultLanguage,
                    isDisabled: !isWhisperActive
                )
            }
        }
    }

    /// Local-model dashboard. Status chip rolls up the worst severity across
    /// both engines: any `.failed` → `.required`; missing model on the
    /// active engine → `.recommended`; all `.ready` → `.ok`; transient
    /// states → no chip (the per-row status pills already telegraph it).
    private var enginesModelsCard: some View {
        SettingsCard(
            title: "Local Models",
            subtitle: "Models live on this Mac. No audio is sent to the cloud.",
            icon: "internaldrive",
            status: enginesModelsCardStatus
        ) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                modelStatusRow(
                    title: "Parakeet",
                    detail: viewModel.parakeetStatusDetail,
                    status: viewModel.parakeetStatus,
                    isRepairing: viewModel.parakeetRepairing,
                    actionLabel: "Repair"
                ) {
                    viewModel.repairParakeetModel()
                }

                Divider()

                modelStatusRow(
                    title: "Whisper",
                    detail: viewModel.whisperModelStatusDetail,
                    status: viewModel.whisperModelStatus,
                    isRepairing: viewModel.whisperDownloading,
                    actionLabel: whisperModelActionLabel,
                    actionDisabled: !isWhisperModelActionEnabled
                ) {
                    viewModel.downloadWhisperModel()
                }
            }
        }
    }

    private var engineSelectorCardStatus: SettingsCardStatus? {
        if viewModel.speechEngineSwitching {
            return SettingsCardStatus(.info, label: "Switching…")
        }
        if viewModel.speechEngineError != nil {
            return SettingsCardStatus(.required, label: "Action needed")
        }
        return nil
    }

    private var enginesModelsCardStatus: SettingsCardStatus? {
        SettingsStatusRules.localModelsCardStatus(
            parakeet: viewModel.parakeetStatus,
            whisper: viewModel.whisperModelStatus,
            activeEngine: viewModel.speechEnginePreference
        )
    }

    private var whisperModelActionLabel: String {
        switch viewModel.whisperModelStatus {
        case .notDownloaded:
            return "Download"
        case .notLoaded:
            // The badge already says "Downloaded ✓"; pairing it with "Repair"
            // implied the model was broken. The button actually re-runs the
            // download (fast no-op via HuggingFace cache when files are
            // intact), so name it for what it does.
            return "Re-download"
        case .failed:
            return "Retry"
        case .ready:
            return "Ready"
        case .checking:
            return "Checking"
        case .repairing:
            return "Working..."
        case .unknown:
            return "Check"
        }
    }

    private var isWhisperModelActionEnabled: Bool {
        switch viewModel.whisperModelStatus {
        case .notDownloaded, .notLoaded, .failed:
            return !viewModel.whisperDownloading
        case .unknown, .checking, .ready, .repairing:
            return false
        }
    }

    /// Roll-up of the three permissions. `.required` if any feature gate is
    /// missing; Screen Recording is required for meeting recording because the
    /// runtime has no mic-only meeting fallback.
    private var permissionsCardStatus: SettingsCardStatus? {
        SettingsStatusRules.permissionsCardStatus(
            meetingRecordingEnabled: AppFeatures.meetingRecordingEnabled,
            microphoneGranted: viewModel.microphoneGranted,
            accessibilityGranted: viewModel.accessibilityGranted,
            screenRecordingGranted: viewModel.screenRecordingGranted
        )
    }

    private var permissionsCard: some View {
        let permissionsSubtitle = AppFeatures.meetingRecordingEnabled
            ? "Microphone and Accessibility are required. Screen Recording is required for meetings."
            : "Microphone and Accessibility are required."

        return SettingsCard(
            title: "Permissions",
            subtitle: permissionsSubtitle,
            icon: "lock.shield",
            status: permissionsCardStatus
        ) {
            VStack(spacing: DesignSystem.Spacing.md) {
                HStack {
                    rowText(title: "Microphone", detail: "Required for voice capture.")
                    Spacer()
                    permissionPill(granted: viewModel.microphoneGranted)
                }

                Divider()

                HStack {
                    rowText(title: "Accessibility", detail: "Required for global hotkey and paste.")
                    Spacer()
                    permissionPill(granted: viewModel.accessibilityGranted)
                }

                if AppFeatures.meetingRecordingEnabled {
                    Divider()

                    HStack {
                        rowText(
                            title: "Screen & System Audio Recording",
                            detail: "Required for meeting audio capture. MacParakeet never records your screen."
                        )
                        Spacer()
                        permissionPill(granted: viewModel.screenRecordingGranted)
                    }
                }

                let needsScreenRecordingAction = AppFeatures.meetingRecordingEnabled && !viewModel.screenRecordingGranted
                if !viewModel.accessibilityGranted || needsScreenRecordingAction {
                    Divider()
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        if !viewModel.accessibilityGranted {
                            Button("Open Accessibility Settings") {
                                openAccessibilitySettings()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(DesignSystem.Colors.accent)
                        }

                        if needsScreenRecordingAction {
                            Button("Enable meeting recording") {
                                viewModel.requestScreenRecordingAccess()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(DesignSystem.Colors.accent)

                            Button("Open Screen Recording Settings") {
                                viewModel.openScreenRecordingSystemSettings()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Privacy

    private var privacyCard: some View {
        settingsCard(
            title: "Privacy",
            subtitle: "Your audio and transcriptions never leave your device.",
            icon: "hand.raised"
        ) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                settingsToggleRow(
                    title: "Help improve MacParakeet",
                    detail: "Send non-identifying usage statistics like feature popularity and performance metrics. No personal data is collected.",
                    isOn: $viewModel.telemetryEnabled
                )
                Button {
                    if let url = URL(string: "https://github.com/moona3k/macparakeet/blob/main/docs/telemetry.md") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("See the full event catalog")
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption)
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(.link)
                .font(DesignSystem.Typography.caption)
                .accessibilityHint("Opens the telemetry documentation on GitHub in your browser.")
            }
        }
    }

    // MARK: - Updates

    private var updatesCard: some View {
        settingsCard(
            title: "Updates",
            subtitle: "Keep MacParakeet up to date.",
            icon: "arrow.triangle.2.circlepath"
        ) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack {
                    Toggle("Automatically check for updates", isOn: $automaticallyChecksForUpdates)
                        .onChange(of: automaticallyChecksForUpdates) { _, newValue in
                            updater.automaticallyChecksForUpdates = newValue
                        }
                        .font(DesignSystem.Typography.body)
                }

                HStack {
                    Toggle("Automatically download updates", isOn: $automaticallyDownloadsUpdates)
                        .onChange(of: automaticallyDownloadsUpdates) { _, newValue in
                            updater.automaticallyDownloadsUpdates = newValue
                        }
                        .font(DesignSystem.Typography.body)
                        .disabled(!automaticallyChecksForUpdates)
                }

                Divider()

                HStack {
                    rowText(
                        title: "Manual check",
                        detail: "Check for a new version right now."
                    )
                    Spacer()
                    Button("Check for Updates...") {
                        updater.checkForUpdates()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignSystem.Colors.accent)
                    .disabled(!updater.canCheckForUpdates)
                }
            }
        }
    }

    // MARK: - Onboarding

    private var onboardingCard: some View {
        settingsCard(
            title: "Setup",
            subtitle: "Re-run the guided setup if something isn't working.",
            icon: "arrow.counterclockwise"
        ) {
            HStack {
                rowText(
                    title: "Run setup again",
                    detail: "Re-opens guided setup for permissions and model download."
                )
                Spacer()
                Button("Open Setup...") {
                    NotificationCenter.default.post(name: .macParakeetOpenOnboarding, object: nil)
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.accent)
            }
        }
    }

    // MARK: - About

    private var aboutCard: some View {
        let identity = BuildIdentity.current
        return settingsCard(
            title: "About",
            subtitle: "Version info and diagnostics.",
            icon: "info.circle"
        ) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack(spacing: DesignSystem.Spacing.md) {
                    SpinnerRingView(size: 18, revolutionDuration: 8.0, tintColor: DesignSystem.Colors.accent)
                        .opacity(0.6)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("MacParakeet \(identity.version) (\(identity.buildNumber))")
                            .font(DesignSystem.Typography.body)
                        Text("Fast, private voice for Mac")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(copiedBuildIdentity ? "Copied" : "Copy Build Info") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(buildIdentityReport(identity), forType: .string)
                        copiedBuildIdentity = true
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(1.2))
                            copiedBuildIdentity = false
                        }
                    }
                    .buttonStyle(.bordered)
                }

                Divider()

                aboutRow(label: "Source", value: identity.buildSource)
                aboutRow(label: "Commit", value: identity.gitCommit)
                aboutRow(label: "Built", value: identity.buildDateUTC)
                aboutRow(label: "Executable", value: identity.executablePath)
            }
        }
    }

    // MARK: - Reusable UI

    @ViewBuilder
    private func settingsCard<Content: View>(
        title: String,
        subtitle: String,
        icon: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        SettingsCard(title: title, subtitle: subtitle, icon: icon, content: content)
    }

    private func settingsToggleRow(
        title: String,
        detail: String,
        isOn: Binding<Bool>
    ) -> some View {
        SettingsToggleRow(title: title, detail: detail, isOn: isOn)
    }

    private func rowText(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(DesignSystem.Typography.body)
            Text(detail)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func maintenanceGroup<Buttons: View>(
        label: String,
        detail: String,
        @ViewBuilder buttons: () -> Buttons
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.sm) {
                Text(label)
                    .font(DesignSystem.Typography.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(detail)
                    .font(DesignSystem.Typography.micro)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            FlowLayout(spacing: DesignSystem.Spacing.sm) {
                buttons()
            }
        }
    }

    private func metricTile(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(DesignSystem.Typography.micro)
                .foregroundStyle(.secondary)
            Text(value)
                .font(DesignSystem.Typography.sectionTitle)
            Text(detail)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated)
        )
    }

    private func modelStatusRow(
        title: String,
        detail: String,
        status: SettingsViewModel.LocalModelStatus,
        isRepairing: Bool,
        actionLabel: String = "Repair",
        actionDisabled: Bool = false,
        onRepair: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DesignSystem.Typography.body)
                Text(detail)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: DesignSystem.Spacing.sm)

            modelStatusPill(status)

            Button(isRepairing ? "Working..." : actionLabel) {
                onRepair()
            }
            .buttonStyle(.bordered)
            .disabled(isRepairing || actionDisabled)
        }
    }

    // MARK: - Dictation Mode Guide

    private var dictationModeGuide: some View {
        VStack(spacing: 0) {
            modeShortcutRow(
                keys: [viewModel.hotkeyTrigger.shortSymbol, viewModel.hotkeyTrigger.shortSymbol],
                separator: "·",
                action: "Persistent dictation",
                detail: "Tap again to stop"
            )

            Divider()
                .padding(.leading, 88)

            modeShortcutRow(
                keys: [viewModel.hotkeyTrigger.shortSymbol],
                separator: nil,
                action: "Push-to-talk",
                detail: "Release to stop"
            )
        }
        .padding(DesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated)
        )
    }

    private func modeShortcutRow(keys: [String], separator: String?, action: String, detail: String) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: 3) {
                if keys.count == 2, let sep = separator {
                    miniSettingsKeyCap(keys[0])
                    Text(sep)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                    miniSettingsKeyCap(keys[1])
                } else {
                    Text("Hold")
                        .font(DesignSystem.Typography.micro)
                        .foregroundStyle(.secondary)
                    miniSettingsKeyCap(keys[0])
                }
            }
            .frame(width: 80, alignment: .center)

            Text(action)
                .font(DesignSystem.Typography.bodySmall.weight(.medium))

            Spacer()

            Text(detail)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    private func miniSettingsKeyCap(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(DesignSystem.Colors.cardBackground)
                    .shadow(color: .black.opacity(0.06), radius: 0.5, x: 0, y: 0.5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(DesignSystem.Colors.border, lineWidth: 0.5)
            )
    }

    // MARK: - Helpers

    private func aboutRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(DesignSystem.Typography.micro)
                .foregroundStyle(.secondary)
            Text(value)
                .font(DesignSystem.Typography.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func buildIdentityReport(_ identity: BuildIdentity) -> String {
        [
            "MacParakeet Build Identity",
            "Version: \(identity.version)",
            "Build: \(identity.buildNumber)",
            "Source: \(identity.buildSource)",
            "Commit: \(identity.gitCommit)",
            "Built: \(identity.buildDateUTC)",
            "Executable: \(identity.executablePath)",
            "Bundle: \(identity.bundlePath)",
        ]
        .joined(separator: "\n")
    }

    @ViewBuilder
    private func permissionPill(granted: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 10))
            Text(granted ? "Granted" : "Not Granted")
                .font(DesignSystem.Typography.micro)
        }
        .foregroundStyle(granted ? DesignSystem.Colors.successGreen : DesignSystem.Colors.errorRed)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(granted ? DesignSystem.Colors.successGreen.opacity(0.1) : DesignSystem.Colors.errorRed.opacity(0.1))
        )
    }

    @ViewBuilder
    private func modelStatusPill(_ status: SettingsViewModel.LocalModelStatus) -> some View {
        let (icon, text, color): (String, String, Color) = switch status {
        case .unknown:
            ("questionmark.circle.fill", "Unknown", .secondary)
        case .checking:
            ("clock.fill", "Checking", DesignSystem.Colors.warningAmber)
        case .ready:
            ("checkmark.circle.fill", "Ready", DesignSystem.Colors.successGreen)
        case .notLoaded:
            // The model is on disk and will lazy-load on first use; this is a
            // healthy idle state, not an error. Earlier copy ("Not Loaded"
            // with a pause icon) read as broken and prompted users to hit
            // Repair to "fix" something that wasn't actually broken.
            ("checkmark.circle.fill", "Downloaded", DesignSystem.Colors.successGreen)
        case .notDownloaded:
            ("arrow.down.circle.fill", "Not Downloaded", DesignSystem.Colors.errorRed)
        case .repairing:
            ("wrench.and.screwdriver.fill", "Repairing", DesignSystem.Colors.warningAmber)
        case .failed:
            ("xmark.circle.fill", "Failed", DesignSystem.Colors.errorRed)
        }

        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(text)
                .font(DesignSystem.Typography.micro)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(color.opacity(0.12))
        )
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
