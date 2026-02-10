import Foundation
import MacParakeetCore

@MainActor
@Observable
public final class SettingsViewModel {
    // General
    public var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: "launchAtLogin") }
    }

    // Dictation
    public var silenceAutoStop: Bool {
        didSet { defaults.set(silenceAutoStop, forKey: "silenceAutoStop") }
    }
    public var silenceDelay: Double {
        didSet { defaults.set(silenceDelay, forKey: "silenceDelay") }
    }

    // Storage
    public var saveAudioRecordings: Bool {
        didSet { defaults.set(saveAudioRecordings, forKey: "saveAudioRecordings") }
    }

    // Permission status
    public var microphoneGranted = false
    public var accessibilityGranted = false

    // Stats
    public var dictationCount = 0
    public var dictationStorageMB: Double = 0

    private var permissionService: PermissionServiceProtocol?
    private var dictationRepo: DictationRepositoryProtocol?
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        launchAtLogin = defaults.bool(forKey: "launchAtLogin")
        silenceAutoStop = defaults.bool(forKey: "silenceAutoStop")
        let delay = defaults.double(forKey: "silenceDelay")
        silenceDelay = delay == 0 ? 2.0 : delay
        saveAudioRecordings = defaults.object(forKey: "saveAudioRecordings") as? Bool ?? true
    }

    public func configure(
        permissionService: PermissionServiceProtocol,
        dictationRepo: DictationRepositoryProtocol
    ) {
        self.permissionService = permissionService
        self.dictationRepo = dictationRepo
        refreshPermissions()
        refreshStats()
    }

    public func refreshPermissions() {
        Task {
            if let service = permissionService {
                let micStatus = await service.checkMicrophonePermission()
                let accStatus = service.checkAccessibilityPermission()
                microphoneGranted = micStatus == .granted
                accessibilityGranted = accStatus
            }
        }
    }

    public func refreshStats() {
        guard let repo = dictationRepo else { return }
        if let stats = try? repo.stats() {
            dictationCount = stats.totalCount
        }
    }

    public func clearAllDictations() {
        guard let repo = dictationRepo else { return }
        try? repo.deleteAll()
        refreshStats()
    }
}
