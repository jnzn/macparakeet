import Foundation
import os

enum AudioCaptureDiagnostics {
    private static let lock = OSAllocatedUnfairLock(initialState: ())
    private static let maxLogBytes: UInt64 = 1_000_000

    static func append(_ message: @autoclosure () -> String) {
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
