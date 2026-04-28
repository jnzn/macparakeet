import XCTest
@testable import CLI
@testable import MacParakeetCore

final class ConfigCommandTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        // Isolate each test in a unique UserDefaults suite so we never touch
        // the user's real `com.macparakeet.MacParakeet` plist.
        suiteName = "macparakeet.test.config.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - read

    func testReadTelemetryDefaultsToOn() throws {
        // Mirror AppPreferences.isTelemetryEnabled: missing key → on.
        let value = try ConfigCommand.read(key: "telemetry", defaults: defaults)
        XCTAssertEqual(value, "on")
    }

    func testReadTelemetryReflectsExplicitFalse() throws {
        defaults.set(false, forKey: AppPreferences.telemetryEnabledKey)
        XCTAssertEqual(try ConfigCommand.read(key: "telemetry", defaults: defaults), "off")
    }

    func testReadTelemetryReflectsExplicitTrue() throws {
        defaults.set(true, forKey: AppPreferences.telemetryEnabledKey)
        XCTAssertEqual(try ConfigCommand.read(key: "telemetry", defaults: defaults), "on")
    }

    func testReadUnknownKeyThrows() {
        XCTAssertThrowsError(try ConfigCommand.read(key: "bogus", defaults: defaults)) { error in
            guard case ConfigError.unknownKey(let key)? = error as? ConfigError else {
                return XCTFail("Expected ConfigError.unknownKey, got \(error)")
            }
            XCTAssertEqual(key, "bogus")
        }
    }

    // MARK: - write

    func testWriteTelemetryOffPersists() throws {
        let canonical = try ConfigCommand.write(key: "telemetry", value: "off", defaults: defaults)
        XCTAssertEqual(canonical, "off")
        XCTAssertEqual(defaults.object(forKey: AppPreferences.telemetryEnabledKey) as? Bool, false)
    }

    func testWriteTelemetryOnPersists() throws {
        defaults.set(false, forKey: AppPreferences.telemetryEnabledKey)
        let canonical = try ConfigCommand.write(key: "telemetry", value: "on", defaults: defaults)
        XCTAssertEqual(canonical, "on")
        XCTAssertEqual(defaults.object(forKey: AppPreferences.telemetryEnabledKey) as? Bool, true)
    }

    func testWriteAcceptsAllBoolSynonyms() throws {
        for (synonym, expectedBool) in [
            ("on", true), ("ON", true), ("true", true), ("yes", true),
            ("1", true), ("enable", true), ("enabled", true),
            ("off", false), ("OFF", false), ("false", false), ("no", false),
            ("0", false), ("disable", false), ("disabled", false)
        ] {
            let canonical = try ConfigCommand.write(key: "telemetry", value: synonym, defaults: defaults)
            XCTAssertEqual(canonical, expectedBool ? "on" : "off",
                           "Synonym '\(synonym)' should canonicalize to \(expectedBool ? "on" : "off")")
            XCTAssertEqual(defaults.object(forKey: AppPreferences.telemetryEnabledKey) as? Bool, expectedBool)
        }
    }

    func testWriteRejectsInvalidValue() {
        XCTAssertThrowsError(try ConfigCommand.write(key: "telemetry", value: "maybe", defaults: defaults)) { error in
            guard case ConfigError.invalidValue(let key, let value)? = error as? ConfigError else {
                return XCTFail("Expected ConfigError.invalidValue, got \(error)")
            }
            XCTAssertEqual(key, "telemetry")
            XCTAssertEqual(value, "maybe")
        }
        // Defaults must not have been mutated.
        XCTAssertNil(defaults.object(forKey: AppPreferences.telemetryEnabledKey))
    }

    func testWriteUnknownKeyThrows() {
        XCTAssertThrowsError(try ConfigCommand.write(key: "bogus", value: "on", defaults: defaults)) { error in
            guard case ConfigError.unknownKey? = error as? ConfigError else {
                return XCTFail("Expected ConfigError.unknownKey, got \(error)")
            }
        }
    }

    // MARK: - parseBool

    func testParseBoolRejectsEmpty() {
        XCTAssertThrowsError(try ConfigCommand.parseBool("", key: "telemetry"))
    }
}
