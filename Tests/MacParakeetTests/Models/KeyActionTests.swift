import XCTest
@testable import MacParakeetCore

final class KeyActionTests: XCTestCase {
    func testKeyActionKeyCodes() {
        XCTAssertEqual(KeyAction.returnKey.keyCode, 0x24)
        XCTAssertEqual(KeyAction.tab.keyCode, 0x30)
        XCTAssertEqual(KeyAction.escape.keyCode, 0x35)
    }

    func testKeyActionCodable() throws {
        for action in KeyAction.allCases {
            let data = try JSONEncoder().encode(action)
            let decoded = try JSONDecoder().decode(KeyAction.self, from: data)
            XCTAssertEqual(decoded, action)
        }
    }

    func testKeyActionLabels() {
        XCTAssertFalse(KeyAction.returnKey.label.isEmpty)
        XCTAssertFalse(KeyAction.tab.label.isEmpty)
        XCTAssertFalse(KeyAction.escape.label.isEmpty)
    }

    func testKeyActionRawValues() {
        XCTAssertEqual(KeyAction.returnKey.rawValue, "return")
        XCTAssertEqual(KeyAction.tab.rawValue, "tab")
        XCTAssertEqual(KeyAction.escape.rawValue, "escape")
    }

    func testKeyActionAllCasesCount() {
        XCTAssertEqual(KeyAction.allCases.count, 3)
    }
}
