import XCTest
@testable import MacParakeetCore

final class TriggerKeyTests: XCTestCase {
    // MARK: - Raw Value Roundtrip

    func testRawValueRoundtripForAllCases() {
        for key in TriggerKey.allCases {
            let restored = TriggerKey(rawValue: key.rawValue)
            XCTAssertEqual(restored, key, "Roundtrip failed for \(key)")
        }
    }

    // MARK: - Display Name

    func testDisplayNames() {
        XCTAssertEqual(TriggerKey.fn.displayName, "Fn")
        XCTAssertEqual(TriggerKey.control.displayName, "Control")
        XCTAssertEqual(TriggerKey.option.displayName, "Option")
        XCTAssertEqual(TriggerKey.shift.displayName, "Shift")
        XCTAssertEqual(TriggerKey.command.displayName, "Command")
    }

    // MARK: - Short Symbol

    func testShortSymbols() {
        XCTAssertEqual(TriggerKey.fn.shortSymbol, "fn")
        XCTAssertEqual(TriggerKey.control.shortSymbol, "⌃")
        XCTAssertEqual(TriggerKey.option.shortSymbol, "⌥")
        XCTAssertEqual(TriggerKey.shift.shortSymbol, "⇧")
        XCTAssertEqual(TriggerKey.command.shortSymbol, "⌘")
    }

    // MARK: - Default Value

    func testCurrentDefaultsToFn() {
        // With no UserDefaults entry, .current should be .fn
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "hotkeyTrigger")
        XCTAssertEqual(TriggerKey.current, .fn)
    }

    func testCurrentReadsFromUserDefaults() {
        let defaults = UserDefaults.standard
        defaults.set("control", forKey: "hotkeyTrigger")
        XCTAssertEqual(TriggerKey.current, .control)

        defaults.set("option", forKey: "hotkeyTrigger")
        XCTAssertEqual(TriggerKey.current, .option)

        // Clean up
        defaults.removeObject(forKey: "hotkeyTrigger")
    }

    func testCurrentFallsBackToFnForInvalidValue() {
        let defaults = UserDefaults.standard
        defaults.set("invalid_key", forKey: "hotkeyTrigger")
        XCTAssertEqual(TriggerKey.current, .fn)

        // Clean up
        defaults.removeObject(forKey: "hotkeyTrigger")
    }

    // MARK: - Codable

    func testCodableRoundtrip() throws {
        for key in TriggerKey.allCases {
            let data = try JSONEncoder().encode(key)
            let decoded = try JSONDecoder().decode(TriggerKey.self, from: data)
            XCTAssertEqual(decoded, key, "Codable roundtrip failed for \(key)")
        }
    }

    // MARK: - All Cases

    func testAllCasesCount() {
        XCTAssertEqual(TriggerKey.allCases.count, 5)
    }
}
