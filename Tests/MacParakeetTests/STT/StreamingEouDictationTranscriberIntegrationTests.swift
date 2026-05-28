@preconcurrency import AVFoundation
import XCTest

@testable import MacParakeetCore

/// Gated integration test for the concrete `StreamingEouDictationTranscriber`.
///
/// Downloads and loads the real Parakeet EOU 120 M CoreML model (~70 s cold,
/// ~1.8 s warm) and feeds a generated WAV through it in realtime chunks.
/// Skipped unless `MACPARAKEET_STREAMING_INTEGRATION=1` is set in the env —
/// protects CI from the model download + runtime cost.
final class StreamingEouDictationTranscriberIntegrationTests: XCTestCase {
    private var shouldRun: Bool {
        ProcessInfo.processInfo.environment["MACPARAKEET_STREAMING_INTEGRATION"] == "1"
    }

    private func generateTestWAV() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let aiffURL = tempDir.appendingPathComponent("spike_raw_\(UUID().uuidString).aiff")
        let wavURL = tempDir.appendingPathComponent("spike_\(UUID().uuidString).wav")

        let sayProcess = Process()
        sayProcess.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        sayProcess.arguments = [
            "-v", "Samantha",
            "-o", aiffURL.path,
            "streaming dictation integration test one two three four five",
        ]
        try sayProcess.run()
        sayProcess.waitUntilExit()
        guard sayProcess.terminationStatus == 0 else {
            throw XCTSkip("say command failed with status \(sayProcess.terminationStatus)")
        }

        let afconvert = Process()
        afconvert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        afconvert.arguments = [
            "-f", "WAVE",
            "-d", "LEI16@16000",
            "-c", "1",
            aiffURL.path,
            wavURL.path,
        ]
        try afconvert.run()
        afconvert.waitUntilExit()
        guard afconvert.terminationStatus == 0 else {
            throw XCTSkip("afconvert failed with status \(afconvert.terminationStatus)")
        }

        try? FileManager.default.removeItem(at: aiffURL)
        return wavURL
    }

    func test_realEouTranscriber_yieldsPartialsAndFinalText() async throws {
        try XCTSkipUnless(shouldRun, "Set MACPARAKEET_STREAMING_INTEGRATION=1 to run")

        let wavURL = try generateTestWAV()
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let transcriber = StreamingEouDictationTranscriber()
        try await transcriber.loadModels()
        let ready = await transcriber.isReady()
        XCTAssertTrue(ready)

        let partialStream = try await transcriber.startSession()

        let file = try AVAudioFile(forReading: wavURL)
        let format = file.processingFormat
        let totalFrames = file.length

        let collector = PartialCollector()
        let partialTask = Task {
            for await partial in partialStream {
                await collector.append(partial)
            }
        }

        let framesPerChunk: AVAudioFrameCount = 1600
        while file.framePosition < totalFrames {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesPerChunk)!
            try file.read(into: buffer, frameCount: framesPerChunk)
            guard buffer.frameLength > 0 else { break }
            try await transcriber.appendAudio(buffer)
        }

        let finalText = try await transcriber.finish()
        _ = await partialTask.value

        let partials = await collector.all()
        let partialCount = partials.count
        let lastPartial = partials.last ?? ""

        XCTAssertGreaterThan(partialCount, 3, "expected multiple partials for a 5+ s clip")
        XCTAssertFalse(finalText.trimmingCharacters(in: .whitespaces).isEmpty, "final text empty")
        XCTAssertFalse(lastPartial.isEmpty, "last partial empty")

        print("[integration] partials: \(partialCount)")
        print("[integration] last partial: \(lastPartial)")
        print("[integration] final: \(finalText)")

        await transcriber.shutdown()
    }
}

private actor PartialCollector {
    private var partials: [String] = []
    func append(_ partial: String) { partials.append(partial) }
    func all() -> [String] { partials }
}
