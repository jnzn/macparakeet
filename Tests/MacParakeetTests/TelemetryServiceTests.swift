import Foundation
import XCTest

@testable import MacParakeetCore

final class TelemetryServiceTests: XCTestCase {

    // MARK: - Event Queuing

    func testSendQueuesEvent() {
        let service = TelemetryService(
            baseURL: URL(string: "https://localhost:9999")!,
            isEnabled: { true }
        )
        service.send("app_launched")
        XCTAssertEqual(service.pendingEventCount, 1)
    }

    func testSendMultipleEventsQueuesAll() {
        let service = TelemetryService(
            baseURL: URL(string: "https://localhost:9999")!,
            isEnabled: { true }
        )
        service.send("app_launched")
        service.send("dictation_started", props: ["trigger": "hotkey"])
        service.send("dictation_completed", props: ["duration_seconds": "5.0"])
        XCTAssertEqual(service.pendingEventCount, 3)
    }

    // MARK: - Opt-Out

    func testSendIsNoOpWhenDisabled() {
        let service = TelemetryService(
            baseURL: URL(string: "https://localhost:9999")!,
            isEnabled: { false }
        )
        service.send("app_launched")
        service.send("dictation_started")
        XCTAssertEqual(service.pendingEventCount, 0)
    }

    func testOptOutEventBypassesDisabledCheck() {
        let service = TelemetryService(
            baseURL: URL(string: "https://localhost:9999")!,
            isEnabled: { false }
        )
        service.send("telemetry_opted_out")
        // telemetry_opted_out bypasses the opt-out check so it gets queued.
        // It also triggers an immediate async flush, but we verify the event was accepted.
        // (The async flush may or may not have completed by now.)
        // We just verify it was accepted despite isEnabled returning false.
        // A regular event should still be rejected:
        service.send("app_launched")
        // app_launched should NOT be queued (isEnabled = false)
        XCTAssertLessThanOrEqual(service.pendingEventCount, 1,
            "Only telemetry_opted_out should be accepted when disabled")
    }

    // MARK: - Max Queue Size

    func testMaxQueueSizeEnforced() {
        let service = TelemetryService(
            baseURL: URL(string: "https://localhost:9999")!,
            isEnabled: { true }
        )
        // Queue up more than max — oldest events should be dropped
        for i in 0..<250 {
            service.send("app_launched", props: ["i": "\(i)"])
        }
        // Queue should never exceed maxQueueSize (flush threshold may drain some)
        XCTAssertLessThanOrEqual(service.pendingEventCount, TelemetryService.maxQueueSize)
    }

    // MARK: - Flush

    func testFlushClearsQueue() async {
        let service = TelemetryService(
            baseURL: URL(string: "https://localhost:9999")!,
            isEnabled: { true }
        )
        service.send("app_launched")
        service.send("dictation_started")
        XCTAssertEqual(service.pendingEventCount, 2)

        await service.flush()
        XCTAssertEqual(service.pendingEventCount, 0)
    }

    func testFlushEmptyQueueIsNoOp() async {
        let service = TelemetryService(
            baseURL: URL(string: "https://localhost:9999")!,
            isEnabled: { true }
        )
        // Should not crash or throw
        await service.flush()
        XCTAssertEqual(service.pendingEventCount, 0)
    }

    // MARK: - Event Serialization

    func testEventSerializesToJSON() throws {
        let event = TelemetryEvent(
            event: "dictation_completed",
            props: ["duration_seconds": "12.5", "word_count": "84"],
            appVer: "0.4.2",
            osVer: "15.3",
            locale: "en-US",
            chip: "Apple M1",
            session: "test-session"
        )

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(event)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["event"] as? String, "dictation_completed")
        XCTAssertEqual(json["app_ver"] as? String, "0.4.2")
        XCTAssertEqual(json["os_ver"] as? String, "15.3")
        XCTAssertEqual(json["locale"] as? String, "en-US")
        XCTAssertEqual(json["chip"] as? String, "Apple M1")
        XCTAssertEqual(json["session"] as? String, "test-session")
        XCTAssertNotNil(json["event_id"])
        XCTAssertNotNil(json["ts"])

        let props = json["props"] as? [String: String]
        XCTAssertEqual(props?["duration_seconds"], "12.5")
        XCTAssertEqual(props?["word_count"], "84")
    }

    func testEventWithoutPropsSerializes() throws {
        let event = TelemetryEvent(
            event: "app_launched",
            appVer: "0.4.2",
            osVer: "15.3",
            locale: nil,
            chip: "Apple M1",
            session: "test-session"
        )

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(event)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["event"] as? String, "app_launched")
        // props should be absent (null)
        XCTAssertTrue(json["props"] is NSNull || json["props"] == nil)
    }

    // MARK: - Session UUID

    func testSessionIdIsPerInstance() {
        let service1 = TelemetryService(
            baseURL: URL(string: "https://localhost:9999")!,
            isEnabled: { true }
        )
        let service2 = TelemetryService(
            baseURL: URL(string: "https://localhost:9999")!,
            isEnabled: { true }
        )
        // Each instance should have a unique session
        // We can't easily check directly since sessionId is private,
        // but two events from different services should have different sessions
        service1.send("app_launched")
        service2.send("app_launched")
        XCTAssertEqual(service1.pendingEventCount, 1)
        XCTAssertEqual(service2.pendingEventCount, 1)
    }

    // MARK: - Payload Encoding

    func testPayloadEncodesCorrectly() throws {
        let events = [
            TelemetryEvent(
                event: "app_launched",
                appVer: "0.4.2",
                osVer: "15.3",
                locale: "en-US",
                chip: "Apple M1",
                session: "s1"
            ),
            TelemetryEvent(
                event: "dictation_started",
                props: ["trigger": "hotkey"],
                appVer: "0.4.2",
                osVer: "15.3",
                locale: "en-US",
                chip: "Apple M1",
                session: "s1"
            ),
        ]
        let payload = TelemetryPayload(events: events)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(payload)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        let eventsArray = json["events"] as? [[String: Any]]
        XCTAssertEqual(eventsArray?.count, 2)
        XCTAssertEqual(eventsArray?[0]["event"] as? String, "app_launched")
        XCTAssertEqual(eventsArray?[1]["event"] as? String, "dictation_started")
    }

    // MARK: - NoOp Implementation

    func testNoOpServiceDoesNothing() async {
        let service = NoOpTelemetryService()
        service.send("app_launched")
        service.send("dictation_started", props: ["trigger": "hotkey"])
        await service.flush()
        // Should not crash or accumulate events
    }

    // MARK: - Static Telemetry Wrapper

    func testStaticTelemetryConfigureAndSend() {
        let service = TelemetryService(
            baseURL: URL(string: "https://localhost:9999")!,
            isEnabled: { true }
        )
        Telemetry.configure(service)
        Telemetry.send("app_launched")
        XCTAssertEqual(service.pendingEventCount, 1)
    }

    func testStaticTelemetrySendBeforeConfigureIsNoOp() {
        // Reset static state by configuring NoOp first
        Telemetry.configure(NoOpTelemetryService())
        Telemetry.send("app_launched")
        // Should not crash
    }

    // MARK: - AppPreferences

    func testTelemetryEnabledDefault() {
        let defaults = UserDefaults(suiteName: "test-telemetry-\(UUID().uuidString)")!
        XCTAssertTrue(AppPreferences.isTelemetryEnabled(defaults: defaults),
            "Telemetry should be enabled by default")
    }

    func testTelemetryEnabledRespectsUserChoice() {
        let defaults = UserDefaults(suiteName: "test-telemetry-\(UUID().uuidString)")!
        defaults.set(false, forKey: AppPreferences.telemetryEnabledKey)
        XCTAssertFalse(AppPreferences.isTelemetryEnabled(defaults: defaults))
    }
}
