import Foundation

/// Deterministic spoken-number → digit normalizer for the dictation text
/// pipeline. Converts cardinal number words (and "point" decimals) to digits —
/// `"twenty five"` → `"25"`, `"three hundred forty two"` → `"342"`,
/// `"three point five"` → `"3.5"` — while keeping non-composable adjacent
/// numbers separate (`"one two three"` → `"1 2 3"`). Pure function, no deps.
///
/// Grouping rule: a sub-1000 value may extend the number under construction only
/// when its highest decimal place sits *below* the current number's lowest
/// occupied place (so "twenty"(20)+"five"(5) merges to 25, but "five"+"five"
/// does not). "hundred" multiplies a <100 head; thousand/million/billion fold the
/// head into the running total.
public enum NumberNormalizer {

    public static func normalize(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let tokens = tokenize(text)
        var output = ""
        var i = 0
        while i < tokens.count {
            switch tokens[i] {
            case .sep(let s):
                output += s
                i += 1
            case .word(let w):
                if let (digits, next) = parseNumberRun(tokens, from: i) {
                    output += digits
                    i = next
                } else {
                    output += w
                    i += 1
                }
            }
        }
        return output
    }

    // MARK: - Tokenizing

    private enum Token {
        case word(String)
        case sep(String)
    }

    /// Split into maximal runs of letters (`.word`) vs non-letters (`.sep`),
    /// preserving every character so non-number text round-trips exactly.
    private static func tokenize(_ s: String) -> [Token] {
        var tokens: [Token] = []
        var buffer = ""
        var bufferIsLetters: Bool?
        for ch in s {
            let isLetter = ch.isLetter
            if bufferIsLetters == nil {
                bufferIsLetters = isLetter
                buffer = String(ch)
            } else if bufferIsLetters == isLetter {
                buffer.append(ch)
            } else {
                tokens.append(bufferIsLetters! ? .word(buffer) : .sep(buffer))
                buffer = String(ch)
                bufferIsLetters = isLetter
            }
        }
        if let isLetters = bufferIsLetters, !buffer.isEmpty {
            tokens.append(isLetters ? .word(buffer) : .sep(buffer))
        }
        return tokens
    }

    // MARK: - Parsing a single number run

    /// Parse the maximal number starting at `start` (a `.word`). Returns the
    /// digit string and the index of the token immediately after the last
    /// consumed number word, or `nil` when `start` isn't a number word.
    private static func parseNumberRun(_ tokens: [Token], from start: Int) -> (String, Int)? {
        var result = 0          // folded total (thousands and up)
        var current = 0         // head under construction (< 1000)
        var consumed = false
        var lastConsumed = start - 1
        var decimal: String?
        var i = start

        while i < tokens.count, case .word(let raw) = tokens[i] {
            let w = raw.lowercased()

            if decimal != nil {
                guard let u = unitValue(w), u <= 9 else { break }
                decimal!.append(String(u))
                consumed = true
                lastConsumed = i
            } else if let v = subHundredValue(w) {
                if current == 0 {
                    current = v
                } else if lowestPlace(current) > highestPlace(v) {
                    current += v
                } else {
                    break  // can't extend (e.g. "five five") → end this run
                }
                consumed = true
                lastConsumed = i
            } else if w == "hundred" {
                guard current < 100 else { break }
                current = (current == 0 ? 1 : current) * 100
                consumed = true
                lastConsumed = i
            } else if let scale = scaleValue(w) {
                result += (current == 0 ? 1 : current) * scale
                current = 0
                consumed = true
                lastConsumed = i
            } else if (w == "a" || w == "an"), !consumed,
                      let nw = nextWord(tokens, after: i), isScaleWord(nw) {
                current = 1
                consumed = true
                lastConsumed = i
            } else if w == "and", consumed,
                      let nw = nextWord(tokens, after: i), isNumberWord(nw) {
                // connective inside a number ("three hundred and five") — skip it
            } else if w == "point", consumed, decimal == nil,
                      let nw = nextWord(tokens, after: i), let u = unitValue(nw), u <= 9 {
                decimal = ""
            } else {
                break
            }

            i = nextWordIndex(tokens, after: i) ?? tokens.count
        }

        guard consumed else { return nil }
        var digits = String(result + current)
        if let decimal, !decimal.isEmpty {
            digits += "." + decimal
        }
        return (digits, lastConsumed + 1)
    }

    // MARK: - Word values

    private static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4,
        "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
    ]
    private static let teens: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    private static let scales: [String: Int] = [
        "thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000,
    ]

    private static func unitValue(_ w: String) -> Int? { units[w] }
    private static func subHundredValue(_ w: String) -> Int? { units[w] ?? teens[w] ?? tens[w] }
    private static func scaleValue(_ w: String) -> Int? { scales[w] }
    private static func isScaleWord(_ w: String) -> Bool { w == "hundred" || scales[w] != nil }
    private static func isNumberWord(_ w: String) -> Bool {
        subHundredValue(w) != nil || w == "hundred" || scales[w] != nil
    }

    // MARK: - Place helpers

    /// Lowest power of ten holding a non-zero digit (20→10, 25→1, 300→100).
    private static func lowestPlace(_ n: Int) -> Int {
        guard n != 0 else { return .max }
        var place = 1
        var x = n
        while x % 10 == 0 { x /= 10; place *= 10 }
        return place
    }

    /// Highest power of ten in the value (5→1, 40→10, 15→10).
    private static func highestPlace(_ v: Int) -> Int {
        guard v != 0 else { return 1 }
        var place = 1
        var x = v
        while x >= 10 { x /= 10; place *= 10 }
        return place
    }

    // MARK: - Token lookahead

    private static func nextWordIndex(_ tokens: [Token], after i: Int) -> Int? {
        var j = i + 1
        while j < tokens.count {
            if case .word = tokens[j] { return j }
            j += 1
        }
        return nil
    }

    private static func nextWord(_ tokens: [Token], after i: Int) -> String? {
        guard let j = nextWordIndex(tokens, after: i), case .word(let w) = tokens[j] else { return nil }
        return w.lowercased()
    }
}
