import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class MeetingsWorkspaceViewModelTests: XCTestCase {
    private var defaultsSuiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "MeetingsWorkspaceViewModelTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaults = nil
        defaultsSuiteName = nil
        super.tearDown()
    }

    func testRefreshUpcomingEventsSkipsFetchWhenCalendarModeIsOff() async {
        let calendar = MockCalendarService()
        calendar.stubPermissionStatus = .granted
        calendar.stubEvents = [makeEvent(title: "Design Review", meetUrl: "https://meet.google.com/abc")]
        let viewModel = makeViewModel(calendarMode: .off, calendarService: calendar)
        viewModel.settingsViewModel.calendarPermissionStatus = .granted

        await viewModel.refreshUpcomingEvents().value

        XCTAssertEqual(calendar.fetchUpcomingEventsCallCount, 0)
        XCTAssertTrue(viewModel.upcomingEvents.isEmpty)
        XCTAssertEqual(viewModel.calendarStatus, AppFeatures.calendarEnabled ? .off : .unavailable)
    }

    func testRefreshUpcomingEventsFiltersByMeetingRulesAndExcludedCalendars() async {
        let calendar = MockCalendarService()
        calendar.stubPermissionStatus = .granted
        calendar.stubEvents = [
            makeEvent(title: "Design Review", meetUrl: "https://zoom.us/j/123", calendarIdentifier: "work"),
            makeEvent(title: "Focus Block", meetUrl: nil, calendarIdentifier: "work"),
            makeEvent(title: "Ignored Review", meetUrl: "https://meet.google.com/abc", calendarIdentifier: "personal")
        ]
        let viewModel = makeViewModel(
            calendarMode: .notify,
            triggerFilter: .withLink,
            excludedCalendarIds: ["personal"],
            calendarService: calendar
        )
        viewModel.settingsViewModel.calendarPermissionStatus = .granted

        await viewModel.refreshUpcomingEvents().value

        if AppFeatures.calendarEnabled {
            XCTAssertEqual(calendar.fetchUpcomingEventsCallCount, 1)
            XCTAssertEqual(viewModel.upcomingEvents.map(\.title), ["Design Review"])
            XCTAssertEqual(viewModel.calendarStatus, .ready(mode: .notify))
        } else {
            XCTAssertEqual(calendar.fetchUpcomingEventsCallCount, 0)
            XCTAssertTrue(viewModel.upcomingEvents.isEmpty)
            XCTAssertEqual(viewModel.calendarStatus, .unavailable)
        }
    }

    func testRecordingStatusTracksMeetingPillState() {
        let pill = MeetingRecordingPillViewModel()
        let viewModel = makeViewModel(meetingPillViewModel: pill)

        pill.state = .recording
        XCTAssertEqual(viewModel.recordingStatus, .recording)
        XCTAssertTrue(viewModel.hasActiveRecording)

        pill.state = .paused
        XCTAssertEqual(viewModel.recordingStatus, .paused)
        XCTAssertTrue(viewModel.hasActiveRecording)

        pill.state = .error("capture failed")
        XCTAssertEqual(viewModel.recordingStatus, .error("capture failed"))
        XCTAssertFalse(viewModel.hasActiveRecording)
    }

    func testAttentionItemsDoNotDuplicateCalendarAndAISetupStates() {
        let viewModel = makeViewModel(calendarMode: .notify)
        viewModel.settingsViewModel.calendarPermissionStatus = .notDetermined

        let ids = Set(viewModel.attentionItems.map(\.id))

        XCTAssertFalse(ids.contains("calendar-permission"))
        XCTAssertFalse(ids.contains("ai-setup"))
        XCTAssertEqual(viewModel.calendarStatus, AppFeatures.calendarEnabled ? .permissionNeeded : .unavailable)
        XCTAssertEqual(viewModel.intelligenceStatus, .setupNeeded)
    }

    func testConfigureLoadsLiveAskPromptPreview() throws {
        let manager = try DatabaseManager()
        let quickPromptRepo = QuickPromptRepository(dbQueue: manager.dbQueue)
        let transcriptionRepo = TranscriptionRepository(dbQueue: manager.dbQueue)
        let viewModel = makeViewModel()

        viewModel.configure(
            transcriptionRepo: transcriptionRepo,
            quickPromptRepo: quickPromptRepo
        )

        XCTAssertEqual(
            viewModel.quickPromptsViewModel.pinnedCount,
            QuickPrompt.builtInPrompts().filter(\.isPinned).count
        )
        XCTAssertEqual(
            viewModel.liveAskPromptVisiblePinnedCount,
            viewModel.quickPromptsViewModel.visiblePinned.count
        )
        XCTAssertEqual(
            viewModel.liveAskPromptPreviewPrompts.map(\.label),
            viewModel.quickPromptsViewModel.visiblePinned.prefix(2).map(\.label)
        )
    }

    func testRefreshQuickPromptsIsSafeBeforeRepositoryConfiguration() {
        let viewModel = makeViewModel()

        viewModel.refreshQuickPrompts()

        XCTAssertTrue(viewModel.liveAskPromptPreviewPrompts.isEmpty)
        XCTAssertEqual(viewModel.liveAskPromptVisiblePinnedCount, 0)
        XCTAssertEqual(viewModel.quickPromptsViewModel.pinnedCount, 0)
    }

    func testLiveAskPromptPreviewIsEmptyWhenNoPromptsArePinned() throws {
        let manager = try DatabaseManager()
        let quickPromptRepo = QuickPromptRepository(dbQueue: manager.dbQueue)
        let transcriptionRepo = TranscriptionRepository(dbQueue: manager.dbQueue)
        let viewModel = makeViewModel()
        viewModel.configure(
            transcriptionRepo: transcriptionRepo,
            quickPromptRepo: quickPromptRepo
        )

        for prompt in viewModel.quickPromptsViewModel.allPinned {
            try quickPromptRepo.setPinned(id: prompt.id, isPinned: false)
        }
        viewModel.refreshQuickPrompts()

        XCTAssertTrue(viewModel.liveAskPromptPreviewPrompts.isEmpty)
        XCTAssertEqual(viewModel.liveAskPromptVisiblePinnedCount, 0)
        XCTAssertEqual(viewModel.quickPromptsViewModel.pinnedCount, 0)
    }

    func testLiveAskPromptCountTracksVisiblePinnedPromptsAfterHiding() throws {
        let manager = try DatabaseManager()
        let quickPromptRepo = QuickPromptRepository(dbQueue: manager.dbQueue)
        let transcriptionRepo = TranscriptionRepository(dbQueue: manager.dbQueue)
        let viewModel = makeViewModel()
        viewModel.configure(
            transcriptionRepo: transcriptionRepo,
            quickPromptRepo: quickPromptRepo
        )

        for prompt in viewModel.quickPromptsViewModel.visiblePinned {
            try quickPromptRepo.toggleVisibility(id: prompt.id)
        }
        viewModel.refreshQuickPrompts()

        XCTAssertTrue(viewModel.liveAskPromptPreviewPrompts.isEmpty)
        XCTAssertEqual(viewModel.liveAskPromptVisiblePinnedCount, 0)
        XCTAssertEqual(viewModel.quickPromptsViewModel.pinnedCount, 0)
    }

    func testMeetingAutoNotesListVisibleResultPromptsAndReflectScope() throws {
        let promptRepo = MockPromptRepository()
        promptRepo.prompts = [
            // Unscoped auto-run (nil = all sources) → counts as on for meetings.
            makeResultPrompt(name: "Summary", isAutoRun: true, sortOrder: 0),
            // Off by default.
            makeResultPrompt(name: "Action Items", isAutoRun: false, sortOrder: 1),
            // Auto-run but scoped to YouTube only → not a meeting auto-note.
            makeResultPrompt(name: "Blog Post", isAutoRun: true, sortOrder: 2, appliesToSources: [.youtube]),
            // Hidden → excluded from the card entirely.
            makeResultPrompt(name: "Hidden", isVisible: false, sortOrder: 3),
        ]
        let promptsVM = PromptsViewModel()
        promptsVM.configure(repo: promptRepo)

        let viewModel = makeViewModel(promptsViewModel: promptsVM)

        XCTAssertEqual(viewModel.meetingAutoNotePrompts.map(\.name), ["Summary", "Action Items", "Blog Post"])
        XCTAssertEqual(viewModel.meetingAutoNoteActivePrompts.map(\.name), ["Summary"])
        XCTAssertEqual(viewModel.meetingAutoNoteActiveCount, 1)
    }

    func testSetMeetingAutoNoteScopesToMeetingOnly() throws {
        let promptRepo = MockPromptRepository()
        promptRepo.prompts = [
            makeResultPrompt(name: "Action Items", isAutoRun: false, sortOrder: 0),
        ]
        let promptsVM = PromptsViewModel()
        promptsVM.configure(repo: promptRepo)
        let viewModel = makeViewModel(promptsViewModel: promptsVM)

        let actionItems = try XCTUnwrap(viewModel.meetingAutoNotePrompts.first)
        XCTAssertFalse(viewModel.isMeetingAutoNote(actionItems))

        viewModel.setMeetingAutoNote(actionItems, enabled: true)

        let toggled = try XCTUnwrap(viewModel.meetingAutoNotePrompts.first)
        XCTAssertTrue(viewModel.isMeetingAutoNote(toggled))
        XCTAssertEqual(toggled.appliesToSources, [.meeting], "Enabling from the Meetings card must scope to meetings only.")
        XCTAssertEqual(viewModel.meetingAutoNoteActiveCount, 1)
    }

    private func makeViewModel(
        calendarMode: CalendarAutoStartMode = .off,
        triggerFilter: MeetingTriggerFilter = .withLink,
        excludedCalendarIds: Set<String> = [],
        meetingPillViewModel: MeetingRecordingPillViewModel? = nil,
        promptsViewModel: PromptsViewModel? = nil,
        calendarService: MockCalendarService = MockCalendarService()
    ) -> MeetingsWorkspaceViewModel {
        defaults.set(calendarMode.rawValue, forKey: CalendarAutoStartPreferences.modeKey)
        defaults.set(triggerFilter.rawValue, forKey: CalendarAutoStartPreferences.triggerFilterKey)
        defaults.set(Array(excludedCalendarIds), forKey: CalendarAutoStartPreferences.excludedCalendarIdsKey)

        let settingsViewModel = SettingsViewModel(defaults: defaults)
        let llmSettingsViewModel = LLMSettingsViewModel(defaults: defaults)
        return MeetingsWorkspaceViewModel(
            recentMeetingsViewModel: TranscriptionLibraryViewModel(scope: .meetings),
            meetingPillViewModel: meetingPillViewModel ?? MeetingRecordingPillViewModel(),
            settingsViewModel: settingsViewModel,
            llmSettingsViewModel: llmSettingsViewModel,
            promptsViewModel: promptsViewModel,
            calendarService: calendarService
        )
    }

    private func makeResultPrompt(
        name: String,
        isVisible: Bool = true,
        isAutoRun: Bool = false,
        sortOrder: Int,
        appliesToSources: Set<Transcription.SourceType>? = nil
    ) -> Prompt {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        return Prompt(
            id: UUID(),
            name: name,
            content: "content for \(name)",
            category: .result,
            isBuiltIn: true,
            isVisible: isVisible,
            isAutoRun: isAutoRun,
            sortOrder: sortOrder,
            createdAt: date,
            updatedAt: date,
            appliesToSources: appliesToSources
        )
    }

    private func makeEvent(
        title: String,
        meetUrl: String?,
        calendarIdentifier: String? = nil
    ) -> CalendarEvent {
        CalendarEvent(
            id: UUID().uuidString,
            title: title,
            startTime: Date().addingTimeInterval(3600),
            endTime: Date().addingTimeInterval(5400),
            meetUrl: meetUrl,
            participants: [EventParticipant(name: "Ava")],
            calendarName: "Work",
            calendarIdentifier: calendarIdentifier
        )
    }
}
