import AppKit
import Foundation
import MacParakeetCore
import MacParakeetViewModels

@MainActor
final class OnboardingCoordinator {
    private let onboardingWindowController: OnboardingWindowController
    private let onRefreshHotkeys: () -> Void
    private let onOpenMainWindow: () -> Void
    private let onOpenSettings: () -> Void

    private var reopenOnNextActivate = false

    init(
        onboardingWindowController: OnboardingWindowController,
        onRefreshHotkeys: @escaping () -> Void,
        onOpenMainWindow: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.onboardingWindowController = onboardingWindowController
        self.onRefreshHotkeys = onRefreshHotkeys
        self.onOpenMainWindow = onOpenMainWindow
        self.onOpenSettings = onOpenSettings
    }

    var isVisible: Bool {
        onboardingWindowController.isVisible
    }

    func maybeShow(environment: AppEnvironment?) {
        guard let environment else { return }
        let completed = UserDefaults.standard.string(forKey: OnboardingViewModel.onboardingCompletedKey) != nil
        if !completed {
            show(
                permissionService: environment.permissionService,
                sttClient: environment.sttScheduler,
                diarizationService: environment.diarizationService,
                entitlementsService: environment.entitlementsService
            )
        } else {
            Task { @MainActor [weak self] in
                await self?.checkPermissionsAfterOnboarding(environment: environment)
            }
        }
    }

    func show(environment: AppEnvironment?) {
        guard let environment else { return }
        show(
            permissionService: environment.permissionService,
            sttClient: environment.sttScheduler,
            diarizationService: environment.diarizationService,
            entitlementsService: environment.entitlementsService
        )
    }

    func handleApplicationDidBecomeActive(environment: AppEnvironment?) {
        guard reopenOnNextActivate else { return }
        maybeShow(environment: environment)
    }

    private func show(
        permissionService: PermissionServiceProtocol,
        sttClient: STTClientProtocol,
        diarizationService: DiarizationServiceProtocol?,
        entitlementsService: EntitlementsService
    ) {
        onboardingWindowController.show(
            permissionService: permissionService,
            sttClient: sttClient,
            diarizationService: diarizationService,
            onFinish: { [weak self] in
                self?.reopenOnNextActivate = false
                self?.onRefreshHotkeys()
                Task {
                    await entitlementsService.bootstrapTrialIfNeeded()
                }
            },
            onOpenMainApp: { [weak self] in
                self?.onOpenMainWindow()
            },
            onOpenSettings: { [weak self] in
                self?.onOpenSettings()
            },
            onIncompleteDismiss: { [weak self] in
                self?.reopenOnNextActivate = true
            }
        )
    }

    private func checkPermissionsAfterOnboarding(environment: AppEnvironment) async {
        let micStatus = await environment.permissionService.checkMicrophonePermission()
        let micGranted = micStatus == .granted
        let axGranted = environment.permissionService.checkAccessibilityPermission()
        let screenGranted = environment.permissionService.checkScreenRecordingPermission()

        let missing = LaunchPermissionChecker.check(
            micGranted: micGranted,
            accessibilityGranted: axGranted,
            screenRecordingGranted: screenGranted,
            meetingRecordingEnabled: AppFeatures.meetingRecordingEnabled
        )

        LaunchPermissionChecker.saveFingerprint(
            micGranted: micGranted,
            accessibilityGranted: axGranted,
            screenRecordingGranted: screenGranted,
            meetingRecordingEnabled: AppFeatures.meetingRecordingEnabled
        )

        guard !missing.isEmpty else { return }
        showPermissionAlert(missing: missing, permissionService: environment.permissionService)
    }

    private func showPermissionAlert(
        missing: [MissingPermission],
        permissionService: PermissionServiceProtocol
    ) {
        let alert = NSAlert()
        alert.messageText = "MacParakeet needs some permissions"

        var lines: [String] = []
        if missing.contains(.microphone) {
            lines.append("• Microphone — required for dictation and meeting recording.")
        }
        if missing.contains(.accessibility) {
            lines.append("• Accessibility — required to paste dictated text.")
        }
        if missing.contains(.screenRecording) {
            lines.append("• Screen & System Audio Recording — required for meeting recording.")
        }
        alert.informativeText = lines.joined(separator: "\n")

        // Track which button index maps to which open-settings action.
        // NSAlert buttons appear right-to-left: first button added = rightmost = default.
        var actions: [() -> Void] = []
        for perm in missing {
            switch perm {
            case .microphone:
                alert.addButton(withTitle: "Open Microphone Settings")
                actions.append { permissionService.openMicrophoneSettings() }
            case .accessibility:
                alert.addButton(withTitle: "Open Accessibility Settings")
                actions.append { permissionService.openAccessibilitySettings() }
            case .screenRecording:
                alert.addButton(withTitle: "Open Screen Recording Settings")
                actions.append { permissionService.openScreenRecordingSettings() }
            }
        }
        alert.addButton(withTitle: "Later")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if index >= 0, index < actions.count {
            actions[index]()
        }
        // "Later" index equals actions.count — falls through with no action.
    }
}
