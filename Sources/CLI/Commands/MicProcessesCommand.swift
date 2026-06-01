import ArgumentParser
import CoreAudio
import Foundation

/// Dev spike (ADR-023 Phase 0): enumerate which processes are currently
/// capturing microphone input, via the macOS 14+ Core Audio process API.
///
/// Run with `--watch` on a real Mac and join/leave a Zoom / Google Meet / Teams
/// call to confirm the call app appears (on join) and disappears (on End Call).
/// That acquire/release is the signal the activity-based auto-stop will key off.
/// MacParakeet's own capture is labelled so it can be excluded.
struct MicProcessesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mic-processes",
        abstract: "Spike: list/watch processes capturing microphone input (ADR-023 detection probe)."
    )

    @Flag(name: .long, help: "Poll continuously instead of printing a single snapshot.")
    var watch = false

    @Option(name: .long, help: "Polling interval in seconds (with --watch). Default 1.0.")
    var interval: Double = 1.0

    func run() throws {
        if watch {
            FileHandle.standardError.write(Data("Watching mic-capturing processes every \(interval)s — join/leave a call to test. Ctrl-C to stop.\n".utf8))
            while true {
                printSnapshot()
                Thread.sleep(forTimeInterval: max(0.2, interval))
            }
        } else {
            printSnapshot()
        }
    }

    private func printSnapshot() {
        let procs = MicInputProbe.processesCapturingInput()
        let stamp = MicProcessesCommand.timeFormatter.string(from: Date())
        if procs.isEmpty {
            print("[\(stamp)] (no process is capturing mic input)")
            return
        }
        print("[\(stamp)] capturing mic input:")
        for p in procs.sorted(by: { ($0.bundleID ?? "") < ($1.bundleID ?? "") }) {
            let tag = MicInputProbe.isMacParakeet(p.bundleID) ? "  <- MacParakeet (our own capture; auto-stop ignores this)" : ""
            print("    pid=\(p.pid)  bundle=\(p.bundleID ?? "(unknown)")\(tag)")
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

/// Read-only Core Audio probe for per-process microphone input capture.
/// macOS 14.2+ (the same process-object API the app already uses for meeting
/// system-audio taps).
enum MicInputProbe {
    struct Proc: Sendable {
        let pid: pid_t
        let bundleID: String?
    }

    static func isMacParakeet(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleID == "com.macparakeet.pdx"
            || bundleID == "com.macparakeet.MacParakeet"
            || bundleID.hasPrefix("com.macparakeet")
    }

    static func processesCapturingInput() -> [Proc] {
        processObjectIDs().compactMap { obj in
            guard boolProperty(obj, kAudioProcessPropertyIsRunningInput) else { return nil }
            return Proc(pid: pidProperty(obj), bundleID: stringProperty(obj, kAudioProcessPropertyBundleID))
        }
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

    private static func pidProperty(_ object: AudioObjectID) -> pid_t {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        _ = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return value
    }

    private static func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var cfString: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &cfString)
        guard status == noErr else { return nil }
        return cfString as String?
    }
}
