import CoreAudio
import Foundation
import os

public enum AudioCaptureDiagnostics {
    private static let lock = OSAllocatedUnfairLock(initialState: ())
    /// On-disk cap for `dictation-audio.log`. Crossing it deletes the file
    /// (not append-rotate). Sized so a heavy user dictating 30–60 min/day
    /// retains tens of days of context — enough that a stall reported via
    /// the in-app feedback flow still has its surrounding window in the
    /// log when the user shares it. Bumped from 1 MB after PR #210 added
    /// the 5 s heartbeat, which roughly doubles per-recording log volume.
    private static let maxLogBytes: UInt64 = 5_000_000

    /// Format a device as `<id>:<name>` for log lines, or `none` if the
    /// device couldn't be resolved. Single canonical shape so grep works
    /// across mic/dictation events.
    static func deviceLabel(_ deviceID: AudioDeviceID?) -> String {
        guard let deviceID else { return "none" }
        let name = AudioDeviceManager.deviceName(deviceID) ?? "unknown"
        return "\(deviceID):\(name)"
    }

    static func defaultInputDeviceLabel() -> String {
        deviceLabel(AudioDeviceManager.defaultInputDevice())
    }

    public static func append(_ message: @autoclosure () -> String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line = "\(formatter.string(from: Date())) \(message())\n"

        guard let data = line.data(using: .utf8) else { return }

        lock.withLock {
            let fm = FileManager.default
            let logURL = URL(fileURLWithPath: AppPaths.logsDir, isDirectory: true)
                .appendingPathComponent("dictation-audio.log")

            do {
                try fm.createDirectory(
                    at: logURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )

                if let attributes = try? fm.attributesOfItem(atPath: logURL.path),
                   let size = attributes[.size] as? UInt64,
                   size > maxLogBytes {
                    try? fm.removeItem(at: logURL)
                }

                if fm.fileExists(atPath: logURL.path),
                   let handle = try? FileHandle(forWritingTo: logURL) {
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    try handle.close()
                } else {
                    try data.write(to: logURL, options: .atomic)
                }
            } catch {
                // Diagnostics must never affect audio capture.
            }
        }
    }
}
