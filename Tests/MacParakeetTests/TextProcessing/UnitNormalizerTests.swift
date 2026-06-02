import XCTest
@testable import MacParakeetCore

final class UnitNormalizerTests: XCTestCase {
    func testPercent() {
        XCTAssertEqual(UnitNormalizer.normalize("50 percent"), "50%")
        XCTAssertEqual(UnitNormalizer.normalize("3.5 percent"), "3.5%")
    }
    func testDegrees() {
        XCTAssertEqual(UnitNormalizer.normalize("72 degrees"), "72°")
        XCTAssertEqual(UnitNormalizer.normalize("37 degrees celsius"), "37°C")
        XCTAssertEqual(UnitNormalizer.normalize("98 degrees fahrenheit"), "98°F")
    }
    func testMeasurements() {
        XCTAssertEqual(UnitNormalizer.normalize("5 kilometers"), "5 km")
        XCTAssertEqual(UnitNormalizer.normalize("6 feet"), "6 ft")
        XCTAssertEqual(UnitNormalizer.normalize("10 miles"), "10 mi")
    }
    func testDataSizes() {
        XCTAssertEqual(UnitNormalizer.normalize("500 megabytes"), "500 MB")
        XCTAssertEqual(UnitNormalizer.normalize("16 gigabytes"), "16 GB")
        XCTAssertEqual(UnitNormalizer.normalize("2 terabytes"), "2 TB")
    }
    func testFractions() {
        XCTAssertEqual(UnitNormalizer.normalize("1 half"), "1/2")
        XCTAssertEqual(UnitNormalizer.normalize("3 quarters"), "3/4")
    }
    func testWordsWithoutDigitsPassThrough() {
        XCTAssertEqual(UnitNormalizer.normalize("a few percent higher"), "a few percent higher")
    }
}
