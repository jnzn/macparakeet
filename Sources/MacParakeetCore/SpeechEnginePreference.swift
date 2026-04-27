import Foundation

public enum SpeechEnginePreference: String, CaseIterable, Codable, Sendable {
    case parakeet
    case whisper

    public static let defaultsKey = "speechRecognitionEngine"
    public static let whisperDefaultLanguageKey = "whisperDefaultLanguage"
    public static let whisperModelVariantKey = "whisperModelVariant"

    public static let defaultWhisperModelVariant = "large-v3-v20240930_turbo_632MB"

    public static func current(defaults: UserDefaults = .standard) -> SpeechEnginePreference {
        guard let rawValue = defaults.string(forKey: defaultsKey),
              let preference = SpeechEnginePreference(rawValue: rawValue) else {
            return .parakeet
        }
        return preference
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }

    public static func whisperDefaultLanguage(defaults: UserDefaults = .standard) -> String? {
        normalizeLanguage(defaults.string(forKey: whisperDefaultLanguageKey))
    }

    public static func saveWhisperDefaultLanguage(_ language: String?, defaults: UserDefaults = .standard) {
        guard let normalized = normalizeLanguage(language) else {
            defaults.removeObject(forKey: whisperDefaultLanguageKey)
            return
        }
        defaults.set(normalized, forKey: whisperDefaultLanguageKey)
    }

    public static func whisperModelVariant(defaults: UserDefaults = .standard) -> String {
        let stored = defaults.string(forKey: whisperModelVariantKey)
        return normalizeModelVariant(stored) ?? defaultWhisperModelVariant
    }

    public static func saveWhisperModelVariant(_ variant: String?, defaults: UserDefaults = .standard) {
        guard let normalized = normalizeModelVariant(variant) else {
            defaults.removeObject(forKey: whisperModelVariantKey)
            return
        }
        defaults.set(normalized, forKey: whisperModelVariantKey)
    }

    public static func normalizeLanguage(_ language: String?) -> String? {
        guard let language else { return nil }
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowercased = trimmed.replacingOccurrences(of: "_", with: "-").lowercased()
        return lowercased == "auto" || lowercased == "auto-detect" ? nil : lowercased
    }

    public static func normalizeModelVariant(_ variant: String?) -> String? {
        guard let variant else { return nil }
        let trimmed = variant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.hasPrefix("whisper-") ? String(trimmed.dropFirst("whisper-".count)) : trimmed
    }
}

public struct SpeechEngineSelection: Codable, Equatable, Sendable {
    public let engine: SpeechEnginePreference
    public let language: String?

    public init(engine: SpeechEnginePreference, language: String? = nil) {
        self.engine = engine
        self.language = engine == .whisper ? SpeechEnginePreference.normalizeLanguage(language) : nil
    }

    public static func current(defaults: UserDefaults = .standard) -> SpeechEngineSelection {
        let engine = SpeechEnginePreference.current(defaults: defaults)
        return SpeechEngineSelection(
            engine: engine,
            language: engine == .whisper ? SpeechEnginePreference.whisperDefaultLanguage(defaults: defaults) : nil
        )
    }
}

public struct SpeechEngineLease: Equatable, Sendable {
    public let id: UUID
    public let selection: SpeechEngineSelection

    public init(id: UUID = UUID(), selection: SpeechEngineSelection) {
        self.id = id
        self.selection = selection
    }
}
