import XCTest

@testable import MacParakeetCore

/// Gated integration test exercising the REAL Silero VAD model download path
/// end-to-end against the shared FluidAudio cache.
///
/// Run with:
/// `MACPARAKEET_VAD_INTEGRATION=1 swift test --filter MeetingVADModelDownloadIntegrationTests`
///
/// Confirms `downloadModel()` actually fetches + compiles the model and that it
/// lands exactly where `isModelCached()` looks — a green run means any
/// "model missing" bug is in the *trigger* (onboarding/pre-warm gating), not the
/// download itself. NOTE: the test binary makes its own network connection, so a
/// per-binary firewall (e.g. Little Snitch) must allow it or this will hang in
/// `mach_msg` waiting on the firewall decision.
final class MeetingVADModelDownloadIntegrationTests: XCTestCase {
    private var shouldRun: Bool {
        ProcessInfo.processInfo.environment["MACPARAKEET_VAD_INTEGRATION"] == "1"
    }

    func test_downloadModel_landsWhereIsModelCachedLooks() async throws {
        try XCTSkipUnless(
            shouldRun,
            "Set MACPARAKEET_VAD_INTEGRATION=1 to run (hits the network + writes the shared FluidAudio cache)"
        )

        try await MeetingVADService.downloadModel()

        XCTAssertTrue(
            MeetingVADService.isModelCached(),
            "downloadModel() returned but isModelCached() is still false — download landed in the wrong place or the required-models check is stale"
        )

        let service = await MeetingVADService.makeIfModelCached()
        XCTAssertNotNil(
            service,
            "makeIfModelCached() returned nil despite a successful download"
        )
    }
}
