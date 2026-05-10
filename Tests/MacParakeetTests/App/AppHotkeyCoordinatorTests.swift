import XCTest
import MacParakeetCore
import MacParakeetViewModels
@testable import MacParakeet

@MainActor
final class AppHotkeyCoordinatorTests: XCTestCase {

    private func makeViewModel(functionName: String = #function) -> SettingsViewModel {
        let suiteName = "AppHotkeyCoordinatorTests.\(functionName).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return SettingsViewModel(defaults: defaults)
    }

    private func makeCoordinator(
        settingsViewModel: SettingsViewModel,
        onAnyHotkeyEnabled: @escaping () -> Void = {},
        onHotkeyUnavailable: @escaping () -> Void = {},
        onHotkeyConflict: @escaping (HotkeyTrigger, [HotkeyTrigger]) -> Void
    ) -> AppHotkeyCoordinator {
        AppHotkeyCoordinator(
            settingsViewModel: settingsViewModel,
            onStartDictation: { _ in },
            onStopDictation: {},
            onCancelDictation: {},
            onDiscardRecording: { _ in },
            onReadyForSecondTap: {},
            onEscapeWhileIdle: {},
            onToggleMeetingRecording: {},
            onTriggerFileTranscription: {},
            onTriggerYouTubeTranscription: {},
            onPrimaryHotkeyManagerChanged: { _ in },
            onAnyHotkeyEnabled: onAnyHotkeyEnabled,
            onHotkeyUnavailable: onHotkeyUnavailable,
            onHotkeyConflict: onHotkeyConflict
        )
    }

    func testSetupFileTranscriptionHotkeyReportsConflictInsteadOfSilentlyDropping() {
        let viewModel = makeViewModel()
        let conflictingTrigger = HotkeyTrigger.modifierChord(modifiers: ["command", "option"])
        viewModel.hotkeyTrigger = conflictingTrigger
        viewModel.fileTranscriptionHotkeyTrigger = conflictingTrigger
        var reportedTrigger: HotkeyTrigger?
        var reportedConflicts: [HotkeyTrigger] = []
        var enabledCount = 0
        var unavailableCount = 0

        let coordinator = makeCoordinator(
            settingsViewModel: viewModel,
            onAnyHotkeyEnabled: { enabledCount += 1 },
            onHotkeyUnavailable: { unavailableCount += 1 },
            onHotkeyConflict: { trigger, conflicts in
                reportedTrigger = trigger
                reportedConflicts = conflicts
            }
        )

        coordinator.setupFileTranscriptionHotkey()

        XCTAssertEqual(reportedTrigger, conflictingTrigger)
        XCTAssertEqual(reportedConflicts, [conflictingTrigger])
        XCTAssertEqual(enabledCount, 0)
        XCTAssertEqual(unavailableCount, 0)
    }
}
