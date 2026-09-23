import CoreAudio
import Foundation

/// Read-only Core Audio probe (macOS 14.2+): bundle IDs of processes currently
/// capturing microphone input. Validated by the ADR-023 Phase 0 `mic-processes`
/// spike. Pair with `MeetingCallActivity.isCall(capturingBundleIDs:allowedPrefixes:)`.
public enum MicInputProbe {
    /// Bundle IDs of every process currently running audio input (incl. nil for
    /// processes without a bundle id). No filtering — callers apply exclusions.
    public static func capturingInputBundleIDs() -> [String?] {
        processObjectIDs()
            .filter { boolProperty($0, kAudioProcessPropertyIsRunningInput) }
            .map { stringProperty($0, kAudioProcessPropertyBundleID) }
    }

    private static func processObjectIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func boolProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &address) else { return false }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    private static func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        // CoreAudio returns a +1 retained CFStringRef; take ownership via
        // Unmanaged so ARC releases it (matches AudioDeviceManager's pattern).
        var cfString: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &cfString) == noErr else { return nil }
        return cfString?.takeRetainedValue() as String?
    }
}
