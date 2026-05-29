import XCTest
@testable import MacParakeetCore

final class TerminalSymbolExpansionTests: XCTestCase {
    private let pipeline = TextProcessingPipeline()

    // MARK: - Single symbol substitutions

    func testSlashReplaced() {
        let result = pipeline.expandTerminalSymbols(in: "foo slash bar")
        XCTAssertEqual(result, "foo/bar")
    }

    func testBackslashReplaced() {
        let result = pipeline.expandTerminalSymbols(in: "foo backslash bar")
        XCTAssertEqual(result, "foo\\bar")
    }

    func testTildeReplaced() {
        let result = pipeline.expandTerminalSymbols(in: "tilde slash dev")
        XCTAssertEqual(result, "~/dev")
    }

    func testUnderscoreReplaced() {
        let result = pipeline.expandTerminalSymbols(in: "my underscore file")
        XCTAssertEqual(result, "my_file")
    }

    func testDashReplaced() {
        // Dash is a shell metacharacter (flag prefix/range); spaces preserved.
        let result = pipeline.expandTerminalSymbols(in: "ls dash la")
        XCTAssertEqual(result, "ls - la")
    }

    func testDotReplaced() {
        let result = pipeline.expandTerminalSymbols(in: "readme dot md")
        XCTAssertEqual(result, "readme.md")
    }

    func testPipeReplaced() {
        // Pipe is a shell command separator; spaces preserved.
        let result = pipeline.expandTerminalSymbols(in: "grep foo pipe less")
        XCTAssertEqual(result, "grep foo | less")
    }

    func testAmpersandReplaced() {
        // Ampersand is a shell metacharacter (background/AND); spaces preserved.
        let result = pipeline.expandTerminalSymbols(in: "make build ampersand make test")
        XCTAssertEqual(result, "make build & make test")
    }

    func testDollarReplaced() {
        // Dollar is a shell metacharacter; spaces preserved (not compacted like path separators).
        let result = pipeline.expandTerminalSymbols(in: "echo dollar HOME")
        XCTAssertEqual(result, "echo $ HOME")
    }

    func testAtReplaced() {
        // @ between word chars → compacted (user@host pattern).
        let result = pipeline.expandTerminalSymbols(in: "user at host")
        XCTAssertEqual(result, "user@host")
    }

    func testHashReplaced() {
        // Hash is a shell metacharacter (shebang/comment); spaces preserved.
        let result = pipeline.expandTerminalSymbols(in: "hash bin bash")
        XCTAssertEqual(result, "# bin bash")
    }

    func testAsteriskReplaced() {
        // Asterisk is a glob metacharacter; space before it preserved.
        let result = pipeline.expandTerminalSymbols(in: "rm asterisk")
        XCTAssertEqual(result, "rm *")
    }

    func testStarAliasReplaced() {
        // Star alias for asterisk; space before it preserved.
        let result = pipeline.expandTerminalSymbols(in: "rm star")
        XCTAssertEqual(result, "rm *")
    }

    func testPercentReplaced() {
        let result = pipeline.expandTerminalSymbols(in: "50 percent done")
        XCTAssertEqual(result, "50%done")
    }

    // MARK: - Path compaction

    func testPathCompactionSlash() {
        let result = pipeline.expandTerminalSymbols(in: "cd slash users slash jensen slash dev")
        XCTAssertTrue(result.contains("/users/jensen/dev"), "Expected path compaction, got: \(result)")
    }

    func testExtensionCompaction() {
        let result = pipeline.expandTerminalSymbols(in: "readme dot md")
        XCTAssertEqual(result, "readme.md")
    }

    // MARK: - Full pipeline integration (isTerminalProfile: true)

    func testTerminalProfileNoCapitalize() {
        let result = pipeline.process(
            text: "git status",
            customWords: [],
            snippets: [],
            isTerminalProfile: true
        )
        XCTAssertEqual(result.text, "git status", "Terminal profile must not capitalize first letter")
    }

    func testTerminalProfileSymbolExpansion() {
        let result = pipeline.process(
            text: "cd slash tmp",
            customWords: [],
            snippets: [],
            isTerminalProfile: true
        )
        XCTAssertTrue(result.text.contains("/tmp"), "Expected /tmp, got: \(result.text)")
    }

    func testNonTerminalProfileNoSymbolExpansion() {
        let result = pipeline.process(
            text: "type slash to separate",
            customWords: [],
            snippets: [],
            isTerminalProfile: false
        )
        XCTAssertTrue(result.text.contains("slash"), "Non-terminal profile must preserve word 'slash'")
    }

    func testCaseInsensitiveSymbolExpansion() {
        let result = pipeline.expandTerminalSymbols(in: "foo SLASH bar")
        XCTAssertEqual(result, "foo/bar")
    }
}
