import XCTest

@testable import MacParakeetCore

/// Unit tests for seeding a bundled Silero VAD model into FluidAudio's cache.
/// Uses injectable source/dest dirs so it never touches the real shared cache
/// or the network.
final class MeetingVADSeedTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// Mirrors the bundled layout: `silero-vad/` containing `config.json` and the
    /// `…mlmodelc/` directory of compiled files.
    private func makeFakeBundledModel() throws -> URL {
        let src = tmp.appendingPathComponent("bundle/SileroVAD/silero-vad")
        let mlmodelc = src.appendingPathComponent("silero-vad-unified-256ms-v6.0.0.mlmodelc")
        try FileManager.default.createDirectory(at: mlmodelc, withIntermediateDirectories: true)
        try "{}".write(to: src.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try Data([0x42]).write(to: mlmodelc.appendingPathComponent("coremldata.bin"))
        return src
    }

    func test_seedBundledModel_copiesConfigAndCompiledModelDir() throws {
        let source = try makeFakeBundledModel()
        let dest = tmp.appendingPathComponent("Models/silero-vad")

        try MeetingVADService.seedBundledModel(from: source, to: dest)

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: dest.appendingPathComponent("config.json").path))
        XCTAssertTrue(fm.fileExists(atPath:
            dest.appendingPathComponent("silero-vad-unified-256ms-v6.0.0.mlmodelc/coremldata.bin").path),
            "the compiled .mlmodelc directory must be copied recursively")
    }

    func test_seedBundledModel_doesNotClobberExistingFiles() throws {
        let source = try makeFakeBundledModel()
        let dest = tmp.appendingPathComponent("Models/silero-vad")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let existing = dest.appendingPathComponent("config.json")
        try "EXISTING".write(to: existing, atomically: true, encoding: .utf8)

        try MeetingVADService.seedBundledModel(from: source, to: dest)

        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "EXISTING",
                       "seeding must not overwrite a file already present in the cache")
    }
}
