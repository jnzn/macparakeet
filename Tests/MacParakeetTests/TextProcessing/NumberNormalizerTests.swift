import XCTest

@testable import MacParakeetCore

final class NumberNormalizerTests: XCTestCase {
    private func check(
        _ input: String, _ expected: String,
        file: StaticString = #file, line: UInt = #line
    ) {
        XCTAssertEqual(NumberNormalizer.normalize(input), expected, "input: \"\(input)\"", file: file, line: line)
    }

    func test_simpleCardinals() {
        check("zero", "0")
        check("five", "5")
        check("nineteen", "19")
        check("twenty", "20")
    }

    func test_compoundTensUnits() {
        check("twenty five", "25")
        check("Twenty-five", "25")   // case + hyphen
        check("ninety nine", "99")
    }

    func test_hundredsAndThousands() {
        check("three hundred forty two", "342")
        check("a hundred", "100")
        check("one hundred thousand", "100000")
        check("two thousand twenty four", "2024")
        check("fifteen hundred", "1500")
    }

    func test_andConnective() {
        check("three hundred and five", "305")
    }

    func test_decimals() {
        check("three point five", "3.5")
        check("three point one four", "3.14")
    }

    func test_nonComposableRunsStaySeparate() {
        check("one two three", "1 2 3")   // units can't chain
        check("seven seven", "7 7")
        check("thirty forty", "30 40")    // tens can't chain
    }

    func test_embeddedInProse() {
        check("I need twenty five dollars", "I need 25 dollars")
        check("two reasons", "2 reasons")          // aggressive by design
        check("call me at four", "call me at 4")
    }

    func test_passthrough() {
        check("no numbers here", "no numbers here")
        check("", "")
    }

    func test_punctuationAdjacency() {
        check("twenty five.", "25.")
        check("thirty, forty", "30, 40")
    }
}
