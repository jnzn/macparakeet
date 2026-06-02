import ArgumentParser
import Foundation
import MacParakeetCore

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
        let ids = MicInputProbe.capturingInputBundleIDs()
        let stamp = MicProcessesCommand.timeFormatter.string(from: Date())
        if ids.isEmpty {
            print("[\(stamp)] (no process is capturing mic input)")
            return
        }
        // Label against the pre-seeded call-app defaults. The app's live
        // allowlist lives in the GUI app's defaults domain, which this CLI
        // process can't read — defaults are close enough for a dev probe.
        let defaultPrefixes = MeetingCallApp.defaults.flatMap(\.bundleIDPrefixes)
        print("[\(stamp)] capturing mic input:")
        for id in ids.map({ $0 ?? "(unknown)" }).sorted() {
            let tag: String
            if MeetingCallActivity.pickerHiddenPrefixes.contains(where: { id.hasPrefix($0) }) {
                tag = "  <- MacParakeet (never counts as a call)"
            } else if MeetingCallActivity.pickerHiddenBundleIDs.contains(id) {
                tag = "  <- system daemon (never counts as a call)"
            } else if defaultPrefixes.contains(where: { id.hasPrefix($0) }) {
                tag = "  <- call app (in default allowlist)"
            } else {
                tag = "  <- not allowlisted (won't arm auto-stop unless added in Settings)"
            }
            print("    bundle=\(id)\(tag)")
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
