# Spoken-Text Smart Formatting — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Always-applied deterministic formatting for dictation — years, ordinals, currency, units, dates (owner's rules), times, phone runs, email/URL, symbols, guarded punctuation — behind one "Smart formatting" toggle, plus AI Formatter prompt cleanup so the LLM preserves (not undoes) the chain's output.

**Architecture:** A chain of pure normalizers (`Sources/MacParakeetCore/TextProcessing/Normalizers/`), each mirroring `NumberNormalizer` (public enum, static `normalize(_:) -> String`, no deps). `SpokenTextFormatter` runs the chain in dependency order. `TextProcessingPipeline` Step 2.4 calls it when smart formatting is on.

**Tech Stack:** Swift 6, XCTest. Repo: `~/Developer/macparakeet`, branch `feature/pdx-next`.

**Spec:** `plans/active/2026-06-spoken-text-smart-formatting.md` — every spec table row is a required test.

**Chain order (locked):**
```
YearNormalizer → OrdinalNormalizer → NumberNormalizer (existing) →
CurrencyNormalizer → UnitNormalizer → DateNormalizer → TimeNormalizer →
PhoneRunNormalizer → EmailURLNormalizer → SymbolNormalizer → PunctuationNormalizer
```

---

## The TDD loop (applies to every task)

Each task below lists **Files / Tests / Implementation / Commit**. For every task, execute these steps in order:

1. Create the test file with the code shown. Run `swift test --filter <TestClassName> 2>&1 | tail -20` → expect **compile failure** (type doesn't exist yet).
2. Create the implementation file with the code shown. **The tests are the contract; the implementation shown is the starting point — adjust it until every test passes.** Do not weaken a test to make it pass; tests encode the approved spec.
3. Run `swift test --filter <TestClassName> 2>&1 | tail -20` → expect **0 failures**.
4. Run `swift build 2>&1 | tail -3` → expect `Build complete!`.
5. Commit with the message shown (test + implementation together).

Word-level normalizers must preserve non-matching text exactly, including punctuation and casing. When a guard is not met, the input passes through byte-for-byte unchanged.

---

### Task 1: YearNormalizer

**Files:**
- Create: `Sources/MacParakeetCore/TextProcessing/Normalizers/YearNormalizer.swift`
- Test: `Tests/MacParakeetTests/TextProcessing/YearNormalizerTests.swift`

**Tests:**

```swift
import XCTest
@testable import MacParakeetCore

final class YearNormalizerTests: XCTestCase {
    func testTwoPartYears() {
        XCTAssertEqual(YearNormalizer.normalize("twenty twenty six"), "2026")
        XCTAssertEqual(YearNormalizer.normalize("nineteen ninety nine"), "1999")
        XCTAssertEqual(YearNormalizer.normalize("twenty twenty"), "2020")
    }
    func testYearInSentence() {
        XCTAssertEqual(YearNormalizer.normalize("back in twenty twenty four"), "back in 2024")
    }
    func testNonYearsPassThrough() {
        XCTAssertEqual(YearNormalizer.normalize("nineteen people"), "nineteen people")
        XCTAssertEqual(YearNormalizer.normalize("twenty cats"), "twenty cats")
        XCTAssertEqual(YearNormalizer.normalize("hello world"), "hello world")
    }
}
```

**Implementation:**

```swift
import Foundation

/// Spoken two-part years → digits ("twenty twenty six" → 2026). Must run
/// BEFORE NumberNormalizer, which would otherwise merge-mangle these into
/// "20 20 6". Guard: result must land in 1900–2099.
public enum YearNormalizer {
    private static let centuries: [String: Int] = ["nineteen": 19, "twenty": 20]
    private static let tens: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
        "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    private static let units: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9,
    ]

    public static func normalize(_ text: String) -> String {
        let words = text.components(separatedBy: " ")
        var out: [String] = []
        var i = 0
        while i < words.count {
            if let century = centuries[words[i].lowercased()],
               i + 1 < words.count,
               let tensVal = tens[words[i + 1].lowercased()] {
                var year = century * 100 + tensVal
                var consumed = 2
                // A trailing unit only composes onto a whole-tens value ≥ 20
                // ("twenty twenty six" → 2026, but "twenty fifteen six" stays 2015 + "six").
                if tensVal >= 20, tensVal % 10 == 0, i + 2 < words.count,
                   let unitVal = units[words[i + 2].lowercased()] {
                    year += unitVal
                    consumed = 3
                }
                if (1900...2099).contains(year) {
                    out.append(String(year))
                    i += consumed
                    continue
                }
            }
            out.append(words[i])
            i += 1
        }
        return out.joined(separator: " ")
    }
}
```

**Commit:** `feat(pdx): YearNormalizer — spoken two-part years to digits`

---

### Task 2: OrdinalNormalizer

**Files:**
- Create: `Sources/MacParakeetCore/TextProcessing/Normalizers/OrdinalNormalizer.swift`
- Test: `Tests/MacParakeetTests/TextProcessing/OrdinalNormalizerTests.swift`

**Tests:**

```swift
import XCTest
@testable import MacParakeetCore

final class OrdinalNormalizerTests: XCTestCase {
    func testCompoundOrdinalsConvert() {
        XCTAssertEqual(OrdinalNormalizer.normalize("the twenty fifth item"), "the 25th item")
        XCTAssertEqual(OrdinalNormalizer.normalize("their thirty third anniversary"), "their 33rd anniversary")
        XCTAssertEqual(OrdinalNormalizer.normalize("twenty first"), "21st")
    }
    func testTeensAndTensOrdinalsConvert() {
        XCTAssertEqual(OrdinalNormalizer.normalize("the twelfth floor"), "the 12th floor")
        XCTAssertEqual(OrdinalNormalizer.normalize("the twentieth century"), "the 20th century")
    }
    func testStandaloneSimpleOrdinalsAreGuarded() {
        XCTAssertEqual(OrdinalNormalizer.normalize("first of all"), "first of all")
        XCTAssertEqual(OrdinalNormalizer.normalize("wait a second"), "wait a second")
        XCTAssertEqual(OrdinalNormalizer.normalize("the third option"), "the third option")
    }
    func testSuffixes() {
        XCTAssertEqual(OrdinalNormalizer.suffix(for: 21), "st")
        XCTAssertEqual(OrdinalNormalizer.suffix(for: 22), "nd")
        XCTAssertEqual(OrdinalNormalizer.suffix(for: 23), "rd")
        XCTAssertEqual(OrdinalNormalizer.suffix(for: 25), "th")
        XCTAssertEqual(OrdinalNormalizer.suffix(for: 11), "th")
        XCTAssertEqual(OrdinalNormalizer.suffix(for: 12), "th")
        XCTAssertEqual(OrdinalNormalizer.suffix(for: 13), "th")
    }
}
```

**Implementation:**

```swift
import Foundation

/// Spoken ordinals → digits+suffix. Compound ordinals ("twenty fifth" → 25th)
/// and tenth+ always convert. Standalone first–ninth are guarded (left as
/// words) so "first of all" / "wait a second" never break. Date contexts for
/// first–ninth are handled later by DateNormalizer. Runs BEFORE
/// NumberNormalizer so "twenty fifth" isn't split into "20 fifth".
public enum OrdinalNormalizer {
    static let simpleOrdinals: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5,
        "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9,
    ]
    private static let teensOrdinals: [String: Int] = [
        "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14,
        "fifteenth": 15, "sixteenth": 16, "seventeenth": 17, "eighteenth": 18, "nineteenth": 19,
    ]
    private static let tensOrdinals: [String: Int] = [
        "twentieth": 20, "thirtieth": 30, "fortieth": 40, "fiftieth": 50,
        "sixtieth": 60, "seventieth": 70, "eightieth": 80, "ninetieth": 90,
    ]
    private static let tensCardinals: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    /// Standard English ordinal suffix (1st, 2nd, 3rd, 4th…, 11th–13th → th).
    public static func suffix(for n: Int) -> String {
        switch (n % 100, n % 10) {
        case (11...13, _): return "th"
        case (_, 1): return "st"
        case (_, 2): return "nd"
        case (_, 3): return "rd"
        default: return "th"
        }
    }

    public static func normalize(_ text: String) -> String {
        let words = text.components(separatedBy: " ")
        var out: [String] = []
        var i = 0
        while i < words.count {
            let lower = words[i].lowercased()
            // Compound: tens cardinal + simple ordinal → one ordinal number.
            if let tensVal = tensCardinals[lower], i + 1 < words.count,
               let unitVal = simpleOrdinals[words[i + 1].lowercased()] {
                let n = tensVal + unitVal
                out.append("\(n)\(suffix(for: n))")
                i += 2
                continue
            }
            // Teens / whole-tens ordinals: always safe to convert.
            if let n = teensOrdinals[lower] ?? tensOrdinals[lower] {
                out.append("\(n)\(suffix(for: n))")
                i += 1
                continue
            }
            // Standalone first–ninth: guarded — pass through.
            out.append(words[i])
            i += 1
        }
        return out.joined(separator: " ")
    }
}
```

**Commit:** `feat(pdx): OrdinalNormalizer — compound/tenth+ ordinals to digits, guarded simples`

---

### Task 3: CurrencyNormalizer

**Files:**
- Create: `Sources/MacParakeetCore/TextProcessing/Normalizers/CurrencyNormalizer.swift`
- Test: `Tests/MacParakeetTests/TextProcessing/CurrencyNormalizerTests.swift`

**Note:** runs after NumberNormalizer, so inputs already have digits ("25 dollars", not "twenty five dollars"). Tests feed digit-form input.

**Tests:**

```swift
import XCTest
@testable import MacParakeetCore

final class CurrencyNormalizerTests: XCTestCase {
    func testDollars() {
        XCTAssertEqual(CurrencyNormalizer.normalize("25 dollars"), "$25")
        XCTAssertEqual(CurrencyNormalizer.normalize("fifty bucks"), "fifty bucks") // words → untouched (digits required)
        XCTAssertEqual(CurrencyNormalizer.normalize("50 bucks"), "$50")
    }
    func testDollarsAndCents() {
        XCTAssertEqual(CurrencyNormalizer.normalize("3 dollars and 50 cents"), "$3.50")
        XCTAssertEqual(CurrencyNormalizer.normalize("3 dollars and 5 cents"), "$3.05")
    }
    func testScaleWords() {
        XCTAssertEqual(CurrencyNormalizer.normalize("1.5 million dollars"), "$1.5 million")
    }
    func testOtherCurrencies() {
        XCTAssertEqual(CurrencyNormalizer.normalize("20 euros"), "€20")
        XCTAssertEqual(CurrencyNormalizer.normalize("5000 won"), "₩5,000")
        XCTAssertEqual(CurrencyNormalizer.normalize("500 yen"), "¥500")
    }
    func testPoundsExcluded() {
        XCTAssertEqual(CurrencyNormalizer.normalize("ten pounds"), "ten pounds")
        XCTAssertEqual(CurrencyNormalizer.normalize("10 pounds"), "10 pounds")
    }
    func testInSentence() {
        XCTAssertEqual(CurrencyNormalizer.normalize("send 25 dollars to John"), "send $25 to John")
    }
}
```

**Implementation:**

```swift
import Foundation

/// Digit-form currency phrases → symbols ("25 dollars" → "$25"). Runs after
/// NumberNormalizer so amounts are already digits. "pounds" is deliberately
/// excluded (£ vs weight is ambiguous for a US-based owner).
public enum CurrencyNormalizer {
    public static func normalize(_ text: String) -> String {
        var result = text

        // "X dollars and Y cents" → $X.YY (cents zero-padded to 2 digits)
        result = replace(result, pattern: #"(\d+) dollars and (\d{1,2}) cents"#) { groups in
            let cents = String(format: "%02d", Int(groups[2]) ?? 0)
            return "$\(groups[1]).\(cents)"
        }
        // "X million/billion/thousand dollars|bucks" → $X million
        result = replace(result, pattern: #"(\d+(?:\.\d+)?) (million|billion|thousand) (?:dollars|bucks)"#) { groups in
            "$\(groups[1]) \(groups[2])"
        }
        // "X dollars|bucks" → $X
        result = replace(result, pattern: #"(\d+(?:,\d{3})*(?:\.\d+)?) (?:dollars|bucks)"#) { groups in
            "$\(groups[1])"
        }
        // euros / won / yen — won gets thousands separators (₩5,000)
        result = replace(result, pattern: #"(\d+(?:,\d{3})*(?:\.\d+)?) euros?"#) { "€\($0[1])" }
        result = replace(result, pattern: #"(\d+) won"#) { groups in
            "₩\(Self.grouped(groups[1]))"
        }
        result = replace(result, pattern: #"(\d+(?:,\d{3})*) yen"#) { "¥\($0[1])" }
        return result
    }

    /// NSRegularExpression-based replace with capture-group access.
    /// Shared helper — extract into `NormalizerRegex.swift` if a second
    /// normalizer needs it (UnitNormalizer and later tasks do).
    static func replace(_ text: String, pattern: String, _ transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var result = text
        // Iterate matches in reverse so earlier ranges stay valid after replacement.
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            var groups: [String] = []
            for g in 0..<match.numberOfRanges {
                let r = match.range(at: g)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            let replacement = transform(groups)
            result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
        }
        return result
    }

    static func grouped(_ digits: String) -> String {
        guard let value = Int(digits) else { return digits }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: value)) ?? digits
    }
}
```

> **Refactor note (do in this task):** move `replace(_:pattern:_:)` and `grouped(_:)` into a new file `Sources/MacParakeetCore/TextProcessing/Normalizers/NormalizerRegex.swift` as `enum NormalizerRegex` — Tasks 4–10 reuse both helpers. Reference them as `NormalizerRegex.replace(...)` / `NormalizerRegex.grouped(...)` everywhere (including here).

**Commit:** `feat(pdx): CurrencyNormalizer + shared NormalizerRegex helper`

---

### Task 4: UnitNormalizer

**Files:**
- Create: `Sources/MacParakeetCore/TextProcessing/Normalizers/UnitNormalizer.swift`
- Test: `Tests/MacParakeetTests/TextProcessing/UnitNormalizerTests.swift`

**Tests:**

```swift
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
```

**Implementation:**

```swift
import Foundation

/// Digit + unit-word → digit + abbreviation ("50 percent" → "50%"). Table-driven;
/// longest patterns first so "degrees celsius" wins over bare "degrees".
public enum UnitNormalizer {
    /// (spoken unit, replacement, attachDirectly) — attachDirectly drops the space.
    private static let units: [(String, String, Bool)] = [
        ("degrees celsius", "°C", true),
        ("degrees fahrenheit", "°F", true),
        ("degrees", "°", true),
        ("percent", "%", true),
        ("kilometers", "km", false), ("kilometer", "km", false),
        ("megabytes", "MB", false), ("gigabytes", "GB", false), ("terabytes", "TB", false),
        ("miles", "mi", false), ("mile", "mi", false),
        ("feet", "ft", false),
    ]

    public static func normalize(_ text: String) -> String {
        var result = text
        for (spoken, abbrev, attach) in units {
            result = NormalizerRegex.replace(result, pattern: #"(\d+(?:\.\d+)?) \#(spoken)\b"#) { groups in
                attach ? "\(groups[1])\(abbrev)" : "\(groups[1]) \(abbrev)"
            }
        }
        result = NormalizerRegex.replace(result, pattern: #"\b1 half\b"#) { _ in "1/2" }
        result = NormalizerRegex.replace(result, pattern: #"\b3 quarters\b"#) { _ in "3/4" }
        return result
    }
}
```

**Commit:** `feat(pdx): UnitNormalizer — percent, degrees, measurements, data sizes, fractions`

---

### Task 5: DateNormalizer (owner's rules)

**Files:**
- Create: `Sources/MacParakeetCore/TextProcessing/Normalizers/DateNormalizer.swift`
- Test: `Tests/MacParakeetTests/TextProcessing/DateNormalizerTests.swift`

**Note:** runs after Year/Ordinal/Number normalizers — input has digit years ("2026"), digit compound days ("25th"), and word simple days ("second").

**Tests:**

```swift
import XCTest
@testable import MacParakeetCore

final class DateNormalizerTests: XCTestCase {
    func testOwnerSuffixRule_StNdRdKept_ThDropped() {
        XCTAssertEqual(DateNormalizer.normalize("june first"), "June 1st")
        XCTAssertEqual(DateNormalizer.normalize("june second"), "June 2nd")
        XCTAssertEqual(DateNormalizer.normalize("june third"), "June 3rd")
        XCTAssertEqual(DateNormalizer.normalize("june fourth"), "June 4")
        XCTAssertEqual(DateNormalizer.normalize("june fifth"), "June 5")
    }
    func testCompoundDays() {
        // Input has digits already (OrdinalNormalizer ran first).
        XCTAssertEqual(DateNormalizer.normalize("june 21st"), "June 21st")
        XCTAssertEqual(DateNormalizer.normalize("june 25th"), "June 25")
    }
    func testCardinalDay() {
        XCTAssertEqual(DateNormalizer.normalize("june 2"), "June 2nd")
    }
    func testWithYear() {
        XCTAssertEqual(DateNormalizer.normalize("june second 2026"), "June 2nd, 2026")
    }
    func testTheXOfMonth() {
        XCTAssertEqual(DateNormalizer.normalize("the fifth of may"), "May 5")
        XCTAssertEqual(DateNormalizer.normalize("the third of may"), "May 3rd")
    }
    func testISOTrigger() {
        XCTAssertEqual(DateNormalizer.normalize("2026 hyphen june hyphen second"), "2026-06-02")
        XCTAssertEqual(DateNormalizer.normalize("2026 dash june dash second"), "2026-06-02")
        XCTAssertEqual(DateNormalizer.normalize("2026 dash december dash 31st"), "2026-12-31")
    }
    func testMonthAloneUntouched() {
        XCTAssertEqual(DateNormalizer.normalize("june is busy"), "june is busy")
        XCTAssertEqual(DateNormalizer.normalize("may I help you"), "may I help you")
    }
}
```

**Implementation:**

```swift
import Foundation

/// Spoken dates → owner's format. Suffix rule (dates only): keep st/nd/rd,
/// drop th ("june second" → "June 2nd", "june fourth" → "June 4").
/// ISO trigger: year-first with spoken "hyphen"/"dash" separators → YYYY-MM-DD.
/// Months are only treated as dates when adjacent to a day — "may I help you"
/// must pass through untouched.
public enum DateNormalizer {
    static let months: [String: (number: Int, display: String)] = [
        "january": (1, "January"), "february": (2, "February"), "march": (3, "March"),
        "april": (4, "April"), "may": (5, "May"), "june": (6, "June"),
        "july": (7, "July"), "august": (8, "August"), "september": (9, "September"),
        "october": (10, "October"), "november": (11, "November"), "december": (12, "December"),
    ]
    private static let monthAlternation = months.keys.joined(separator: "|")

    /// Owner's date-day rule: st/nd/rd kept, th dropped (11–13 are th → bare).
    static func formatDay(_ day: Int) -> String {
        let suffix = OrdinalNormalizer.suffix(for: day)
        return suffix == "th" ? "\(day)" : "\(day)\(suffix)"
    }

    public static func normalize(_ text: String) -> String {
        var result = text

        // 1. ISO trigger: "(year) hyphen|dash (month) hyphen|dash (day)"
        //    day = word ordinal ("second"), digits+suffix ("31st"), or digits.
        result = NormalizerRegex.replace(
            result,
            pattern: #"(\d{4}) (?:hyphen|dash) (\#(monthAlternation)) (?:hyphen|dash) (\w+)"#
        ) { groups in
            guard let month = months[groups[2].lowercased()],
                  let day = Self.dayValue(groups[3]) else { return groups[0] }
            return String(format: "%@-%02d-%02d", groups[1], month.number, day)
        }

        // 2. "the (day) of (month)" → "Month Day"
        result = NormalizerRegex.replace(
            result,
            pattern: #"the (\w+) of (\#(monthAlternation))\b"#
        ) { groups in
            guard let month = months[groups[2].lowercased()],
                  let day = Self.dayValue(groups[1]) else { return groups[0] }
            return "\(month.display) \(formatDay(day))"
        }

        // 3. "(month) (day)[ (year)]" → "Month Day[, Year]"
        //    Day must be a word ordinal, digits+suffix, or 1–2 bare digits.
        result = NormalizerRegex.replace(
            result,
            pattern: #"\b(\#(monthAlternation)) (\d{1,2}(?:st|nd|rd|th)?|first|second|third|fourth|fifth|sixth|seventh|eighth|ninth)( \d{4})?\b"#
        ) { groups in
            guard let month = months[groups[1].lowercased()],
                  let day = Self.dayValue(groups[2]) else { return groups[0] }
            let year = groups[3].trimmingCharacters(in: .whitespaces)
            let dayText = formatDay(day)
            return year.isEmpty ? "\(month.display) \(dayText)" : "\(month.display) \(dayText), \(year)"
        }

        return result
    }

    /// Parse a day from: word ordinal ("second" → 2), digits+suffix ("25th" → 25),
    /// or bare digits ("2" → 2). Returns nil (→ no conversion) outside 1–31.
    static func dayValue(_ raw: String) -> Int? {
        let lower = raw.lowercased()
        if let n = OrdinalNormalizer.simpleOrdinals[lower] { return n }
        let digits = lower.replacingOccurrences(of: #"(st|nd|rd|th)$"#, with: "", options: .regularExpression)
        guard let n = Int(digits), (1...31).contains(n) else { return nil }
        return n
    }
}
```

**Commit:** `feat(pdx): DateNormalizer — owner date rules + hyphen/dash ISO trigger`

---

### Task 6: TimeNormalizer

**Files:**
- Create: `Sources/MacParakeetCore/TextProcessing/Normalizers/TimeNormalizer.swift`
- Test: `Tests/MacParakeetTests/TextProcessing/TimeNormalizerTests.swift`

**Tests:**

```swift
import XCTest
@testable import MacParakeetCore

final class TimeNormalizerTests: XCTestCase {
    func testTimesWithAnchor() {
        XCTAssertEqual(TimeNormalizer.normalize("3 30 pm"), "3:30 PM")
        XCTAssertEqual(TimeNormalizer.normalize("9 am"), "9:00 AM")
        XCTAssertEqual(TimeNormalizer.normalize("9 a m"), "9:00 AM")
        XCTAssertEqual(TimeNormalizer.normalize("12 15 pm"), "12:15 PM")
        XCTAssertEqual(TimeNormalizer.normalize("3 o'clock"), "3:00")
        XCTAssertEqual(TimeNormalizer.normalize("3 oclock"), "3:00")
    }
    func testNoAnchorNoConversion() {
        XCTAssertEqual(TimeNormalizer.normalize("there were 3 30 year olds"), "there were 3 30 year olds")
        XCTAssertEqual(TimeNormalizer.normalize("3 30"), "3 30")
    }
}
```

**Implementation:**

```swift
import Foundation

/// Digit times with an am/pm/o'clock anchor → clock format ("3 30 pm" → "3:30 PM").
/// Bare digit pairs without an anchor are never touched.
public enum TimeNormalizer {
    public static func normalize(_ text: String) -> String {
        var result = text
        // "H MM am|pm" → H:MM AM/PM
        result = NormalizerRegex.replace(result, pattern: #"\b(\d{1,2}) (\d{2}) ([ap])\.? ?m\b\.?"#) { groups in
            "\(groups[1]):\(groups[2]) \(groups[3].uppercased())M"
        }
        // "H am|pm" → H:00 AM/PM
        result = NormalizerRegex.replace(result, pattern: #"\b(\d{1,2}) ([ap])\.? ?m\b\.?"#) { groups in
            "\(groups[1]):00 \(groups[2].uppercased())M"
        }
        // "H o'clock" → H:00
        result = NormalizerRegex.replace(result, pattern: #"\b(\d{1,2}) o'?clock\b"#) { groups in
            "\(groups[1]):00"
        }
        return result
    }
}
```

**Commit:** `feat(pdx): TimeNormalizer — anchored clock times`

---

### Task 7: PhoneRunNormalizer

**Files:**
- Create: `Sources/MacParakeetCore/TextProcessing/Normalizers/PhoneRunNormalizer.swift`
- Test: `Tests/MacParakeetTests/TextProcessing/PhoneRunNormalizerTests.swift`

**Tests:**

```swift
import XCTest
@testable import MacParakeetCore

final class PhoneRunNormalizerTests: XCTestCase {
    func testSevenDigitRun() {
        XCTAssertEqual(PhoneRunNormalizer.normalize("5 5 5 1 2 1 2"), "555-1212")
    }
    func testTenDigitRun() {
        XCTAssertEqual(PhoneRunNormalizer.normalize("6 1 7 5 5 5 1 2 1 2"), "617-555-1212")
    }
    func testShortRunsUntouched() {
        XCTAssertEqual(PhoneRunNormalizer.normalize("1 2 3"), "1 2 3")
        XCTAssertEqual(PhoneRunNormalizer.normalize("4 5 6 7"), "4 5 6 7")
    }
    func testInSentence() {
        XCTAssertEqual(PhoneRunNormalizer.normalize("call me at 5 5 5 1 2 1 2 tomorrow"),
                       "call me at 555-1212 tomorrow")
    }
}
```

**Implementation:**

```swift
import Foundation

/// Runs of exactly 7 or 10 single spoken digits → phone format. Any other run
/// length passes through (the cardinal normalizer already spaced them).
public enum PhoneRunNormalizer {
    public static func normalize(_ text: String) -> String {
        var result = text
        // 10 digits first (longest match wins): XXX-XXX-XXXX
        result = NormalizerRegex.replace(
            result,
            pattern: #"\b(\d) (\d) (\d) (\d) (\d) (\d) (\d) (\d) (\d) (\d)\b"#
        ) { g in
            "\(g[1])\(g[2])\(g[3])-\(g[4])\(g[5])\(g[6])-\(g[7])\(g[8])\(g[9])\(g[10])"
        }
        // 7 digits: XXX-XXXX
        result = NormalizerRegex.replace(
            result,
            pattern: #"\b(\d) (\d) (\d) (\d) (\d) (\d) (\d)\b"#
        ) { g in
            "\(g[1])\(g[2])\(g[3])-\(g[4])\(g[5])\(g[6])\(g[7])"
        }
        return result
    }
}
```

**Commit:** `feat(pdx): PhoneRunNormalizer — 7/10-digit spoken runs`

---

### Task 8: EmailURLNormalizer

**Files:**
- Create: `Sources/MacParakeetCore/TextProcessing/Normalizers/EmailURLNormalizer.swift`
- Test: `Tests/MacParakeetTests/TextProcessing/EmailURLNormalizerTests.swift`

**Tests:**

```swift
import XCTest
@testable import MacParakeetCore

final class EmailURLNormalizerTests: XCTestCase {
    func testEmail() {
        XCTAssertEqual(EmailURLNormalizer.normalize("john at gmail dot com"), "john@gmail.com")
        XCTAssertEqual(EmailURLNormalizer.normalize("support at macparakeet dot com"), "support@macparakeet.com")
    }
    func testURL() {
        XCTAssertEqual(EmailURLNormalizer.normalize("example dot com"), "example.com")
        XCTAssertEqual(EmailURLNormalizer.normalize("example dot com slash docs"), "example.com/docs")
    }
    func testBareAtIsNeverConverted() {
        XCTAssertEqual(EmailURLNormalizer.normalize("I'm at home"), "I'm at home")
        XCTAssertEqual(EmailURLNormalizer.normalize("meet me at noon"), "meet me at noon")
    }
}
```

**Implementation:**

```swift
import Foundation

/// Spoken emails/URLs → text form, only when a dot-TLD tail anchors the
/// pattern. Bare "at" without "dot <tld>" downstream is never converted.
public enum EmailURLNormalizer {
    private static let tlds = "com|net|org|io|gov|edu"

    public static func normalize(_ text: String) -> String {
        var result = text
        // Email: "(user) at (host) dot (tld)" → user@host.tld
        result = NormalizerRegex.replace(
            result,
            pattern: #"\b([\w.]+) at ([\w]+) dot (\#(tlds))\b"#
        ) { g in "\(g[1])@\(g[2]).\(g[3])" }
        // URL with path: "(host) dot (tld) slash (path)" → host.tld/path
        result = NormalizerRegex.replace(
            result,
            pattern: #"\b([\w]+) dot (\#(tlds)) slash ([\w]+)\b"#
        ) { g in "\(g[1]).\(g[2])/\(g[3])" }
        // Bare domain: "(host) dot (tld)" → host.tld
        result = NormalizerRegex.replace(
            result,
            pattern: #"\b([\w]+) dot (\#(tlds))\b"#
        ) { g in "\(g[1]).\(g[2])" }
        return result
    }
}
```

**Commit:** `feat(pdx): EmailURLNormalizer — TLD-anchored emails and URLs`

---

### Task 9: SymbolNormalizer

**Files:**
- Create: `Sources/MacParakeetCore/TextProcessing/Normalizers/SymbolNormalizer.swift`
- Test: `Tests/MacParakeetTests/TextProcessing/SymbolNormalizerTests.swift`

**Tests:**

```swift
import XCTest
@testable import MacParakeetCore

final class SymbolNormalizerTests: XCTestCase {
    func testPrefixSymbolsAttachToNextWord() {
        XCTAssertEqual(SymbolNormalizer.normalize("hashtag standup"), "#standup")
        XCTAssertEqual(SymbolNormalizer.normalize("pound sign one"), "#one")
    }
    func testStandaloneSymbols() {
        XCTAssertEqual(SymbolNormalizer.normalize("at sign"), "@")
        XCTAssertEqual(SymbolNormalizer.normalize("ampersand"), "&")
        XCTAssertEqual(SymbolNormalizer.normalize("asterisk"), "*")
        XCTAssertEqual(SymbolNormalizer.normalize("underscore"), "_")
        XCTAssertEqual(SymbolNormalizer.normalize("tilde"), "~")
        XCTAssertEqual(SymbolNormalizer.normalize("backslash"), "\\")
        XCTAssertEqual(SymbolNormalizer.normalize("dollar sign"), "$")
        XCTAssertEqual(SymbolNormalizer.normalize("percent sign"), "%")
    }
    func testHyphenJoinsWords() {
        XCTAssertEqual(SymbolNormalizer.normalize("self hyphen aware"), "self-aware")
    }
    func testAmbiguousWordsAreNotConverted() {
        XCTAssertEqual(SymbolNormalizer.normalize("a dash of salt"), "a dash of salt")
        XCTAssertEqual(SymbolNormalizer.normalize("that's a plus"), "that's a plus")
        XCTAssertEqual(SymbolNormalizer.normalize("the pipe burst"), "the pipe burst")
    }
}
```

**Implementation:**

```swift
import Foundation

/// Unambiguous spoken symbol words → symbols. "hashtag"/"pound sign" prefix
/// the next word; "hyphen" joins its neighbors; the rest stand alone.
/// Ambiguous words (dash, plus, pipe, slash, equals) are deliberately NOT
/// here — users opt into those via Custom Words.
public enum SymbolNormalizer {
    public static func normalize(_ text: String) -> String {
        var result = text
        // Prefix symbols: attach to the following word.
        result = NormalizerRegex.replace(result, pattern: #"\b(?:hashtag|pound sign) (\w+)"#) { g in "#\(g[1])" }
        // Hyphen joins adjacent words: "self hyphen aware" → "self-aware"
        result = NormalizerRegex.replace(result, pattern: #"(\w+) hyphen (\w+)"#) { g in "\(g[1])-\(g[2])" }
        // Two-word standalone symbols.
        let twoWord: [(String, String)] = [
            ("at sign", "@"), ("pound sign", "#"), ("dollar sign", "$"), ("percent sign", "%"),
        ]
        for (spoken, symbol) in twoWord {
            result = result.replacingOccurrences(of: spoken, with: symbol)
        }
        // One-word unambiguous symbols.
        let oneWord: [(String, String)] = [
            ("hashtag", "#"), ("ampersand", "&"), ("asterisk", "*"),
            ("underscore", "_"), ("tilde", "~"), ("backslash", "\\"),
        ]
        for (spoken, symbol) in oneWord {
            result = NormalizerRegex.replace(result, pattern: #"\b\#(spoken)\b"#) { _ in symbol }
        }
        return result
    }
}
```

**Commit:** `feat(pdx): SymbolNormalizer — unambiguous spoken symbols`

---

### Task 10: PunctuationNormalizer

**Files:**
- Create: `Sources/MacParakeetCore/TextProcessing/Normalizers/PunctuationNormalizer.swift`
- Test: `Tests/MacParakeetTests/TextProcessing/PunctuationNormalizerTests.swift`

**Tests:**

```swift
import XCTest
@testable import MacParakeetCore

final class PunctuationNormalizerTests: XCTestCase {
    func testAlwaysConvertedCommands() {
        XCTAssertEqual(PunctuationNormalizer.normalize("is this right question mark"), "is this right?")
        XCTAssertEqual(PunctuationNormalizer.normalize("wow exclamation point"), "wow!")
        XCTAssertEqual(PunctuationNormalizer.normalize("wow exclamation mark"), "wow!")
        XCTAssertEqual(PunctuationNormalizer.normalize("one semicolon two"), "one; two")
    }
    func testPeriodAndCommaOnlyAtEnd() {
        XCTAssertEqual(PunctuationNormalizer.normalize("ship it today period"), "ship it today.")
        XCTAssertEqual(PunctuationNormalizer.normalize("add milk comma"), "add milk,")
        // Mid-text: untouched.
        XCTAssertEqual(PunctuationNormalizer.normalize("the trial period ended"), "the trial period ended")
        XCTAssertEqual(PunctuationNormalizer.normalize("comma separated values"), "comma separated values")
    }
    func testGuardedWordsStayWords() {
        XCTAssertEqual(PunctuationNormalizer.normalize("use a colon here"), "use a colon here")
        XCTAssertEqual(PunctuationNormalizer.normalize("start a new line"), "start a new line")
    }
    func testQuotes() {
        XCTAssertEqual(PunctuationNormalizer.normalize("she said open quote hello close quote"),
                       "she said \"hello\"")
    }
}
```

**Implementation:**

```swift
import Foundation

/// Spoken punctuation commands. Multi-word/unambiguous commands always
/// convert and attach to the preceding word. "period"/"comma" convert ONLY
/// as the final word of the text (the classic "…send it today period"
/// pattern) — mid-text occurrences are real words and stay untouched.
public enum PunctuationNormalizer {
    public static func normalize(_ text: String) -> String {
        var result = text

        // Always-safe commands: attach to the preceding word.
        let always: [(String, String)] = [
            ("question mark", "?"), ("exclamation point", "!"), ("exclamation mark", "!"),
            ("semicolon", ";"),
        ]
        for (spoken, mark) in always {
            result = NormalizerRegex.replace(result, pattern: #"(\S) \#(spoken)\b"#) { g in "\(g[1])\(mark)" }
        }

        // Quotes: open quote X close quote → "X"
        result = NormalizerRegex.replace(result, pattern: #"open quote (.+?) close quote"#) { g in "\"\(g[1])\"" }

        // End-of-text-only commands.
        let trimmed = result.trimmingCharacters(in: .whitespaces)
        for (spoken, mark) in [("period", "."), ("comma", ",")] {
            if trimmed.lowercased().hasSuffix(" \(spoken)") {
                let head = String(trimmed.dropLast(spoken.count + 1))
                result = "\(head)\(mark)"
                break
            }
        }
        return result
    }
}
```

**Commit:** `feat(pdx): PunctuationNormalizer — guarded spoken punctuation`

---

### Task 11: SpokenTextFormatter chain + integration tests

**Files:**
- Create: `Sources/MacParakeetCore/TextProcessing/SpokenTextFormatter.swift`
- Test: `Tests/MacParakeetTests/TextProcessing/SpokenTextFormatterTests.swift`

**Tests:**

```swift
import XCTest
@testable import MacParakeetCore

final class SpokenTextFormatterTests: XCTestCase {
    func testCurrencyAndDateChain() {
        XCTAssertEqual(SpokenTextFormatter.format("twenty five dollars on june second"),
                       "$25 on June 2nd")
    }
    func testPercentTimeAndTrailingPeriod() {
        XCTAssertEqual(SpokenTextFormatter.format("fifty percent by three thirty pm period"),
                       "50% by 3:30 PM.")
    }
    func testISODateWithTime() {
        XCTAssertEqual(SpokenTextFormatter.format("twenty twenty six dash june dash second at nine a m"),
                       "2026-06-02 at 9:00 AM")
    }
    func testGuardsHoldThroughTheChain() {
        XCTAssertEqual(SpokenTextFormatter.format("first of all I'm at home"),
                       "first of all I'm at home")
        XCTAssertEqual(SpokenTextFormatter.format("the trial period ended"),
                       "the trial period ended")
    }
    func testYearBeforeCardinals() {
        XCTAssertEqual(SpokenTextFormatter.format("back in twenty twenty four"), "back in 2024")
    }
    func testCompoundOrdinalBeforeCardinals() {
        XCTAssertEqual(SpokenTextFormatter.format("the twenty fifth item"), "the 25th item")
    }
}
```

**Implementation:**

```swift
import Foundation

/// The smart-formatting chain (spec: 2026-06-spoken-text-smart-formatting.md).
/// Order is load-bearing — years and ordinals before cardinal merging; digits
/// before currency/units/dates/times; dates before symbols (so date
/// "hyphen"/"dash" separators are consumed by the ISO pattern); punctuation last.
public enum SpokenTextFormatter {
    public static func format(_ text: String) -> String {
        var result = text
        result = YearNormalizer.normalize(result)
        result = OrdinalNormalizer.normalize(result)
        result = NumberNormalizer.normalize(result)
        result = CurrencyNormalizer.normalize(result)
        result = UnitNormalizer.normalize(result)
        result = DateNormalizer.normalize(result)
        result = TimeNormalizer.normalize(result)
        result = PhoneRunNormalizer.normalize(result)
        result = EmailURLNormalizer.normalize(result)
        result = SymbolNormalizer.normalize(result)
        result = PunctuationNormalizer.normalize(result)
        return result
    }
}
```

**Note:** the chain integration tests exercise spoken→formatted end-to-end (e.g. "three thirty pm" must survive cardinal merging as "3 30 pm" before TimeNormalizer sees it). If a chain test fails while unit tests pass, the bug is an ordering/interaction issue — fix the interacting normalizer, never reorder the chain without updating the spec.

**Commit:** `feat(pdx): SpokenTextFormatter chain + cross-normalizer integration tests`

---

### Task 12: Pipeline + preferences integration

**Files:**
- Modify: `Sources/MacParakeetCore/TextProcessing/TextProcessingPipeline.swift` (param + Step 2.4)
- Modify: `Sources/MacParakeetCore/TextProcessing/TextRefinementService.swift` (param pass-through)
- Modify: `Sources/MacParakeetCore/AppRuntimePreferences.swift` (new key + migration)
- Modify: `Sources/MacParakeetCore/Services/Dictation/DictationService.swift` (~line 840: pass the new pref)
- Test: `Tests/MacParakeetTests/TextProcessing/SmartFormattingPreferenceTests.swift`

**Steps:**

1. `TextProcessingPipeline.process`: rename parameter `normalizeNumbers: Bool = false` → `smartFormatting: Bool = false`; Step 2.4 becomes:

```swift
        // Step 2.4: Smart formatting (opt-in). Runs after custom words so user
        // replacements aren't disturbed, before symbol expansion so digits are
        // present when terminal profiles format.
        if smartFormatting {
            result = SpokenTextFormatter.format(result)
        }
```

2. `TextRefinementService.refine`: rename `normalizeNumbers: Bool = false` → `smartFormatting: Bool = false`; pass through to the pipeline.

3. `AppRuntimePreferences.swift`:
   - Protocol: replace `var normalizeNumbers: Bool { get }` with `var smartFormattingEnabled: Bool { get }`.
   - Keys: add `public static let smartFormattingEnabledKey = "smartFormattingEnabled"` (keep `normalizeNumbersKey` for migration).
   - Implementation:

```swift
    public var smartFormattingEnabled: Bool {
        if let explicit = defaults.object(forKey: Self.smartFormattingEnabledKey) as? Bool {
            return explicit
        }
        // Migration: respect a prior explicit opt-out of the old numbers-only toggle.
        if let legacy = defaults.object(forKey: Self.normalizeNumbersKey) as? Bool, legacy == false {
            return false
        }
        return true
    }
```

4. `DictationService` (~line 840): the `normalizeNumbers?() ?? false` closure becomes `smartFormatting?() ?? false`. Follow the compiler: rename the stored closure property, its init parameter, and the AppEnvironment/coordinator callsite that constructs `DictationService` (grep `normalizeNumbers` across `Sources/` and rename every reference — the compiler lists them all after step 1).

**Tests:**

```swift
import XCTest
@testable import MacParakeetCore

final class SmartFormattingPreferenceTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "macparakeet.test.config.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDefaultsToTrue() {
        XCTAssertTrue(UserDefaultsAppRuntimePreferences(defaults: defaults).smartFormattingEnabled)
    }
    func testExplicitValueWins() {
        defaults.set(false, forKey: UserDefaultsAppRuntimePreferences.smartFormattingEnabledKey)
        XCTAssertFalse(UserDefaultsAppRuntimePreferences(defaults: defaults).smartFormattingEnabled)
    }
    func testLegacyOptOutMigrates() {
        defaults.set(false, forKey: UserDefaultsAppRuntimePreferences.normalizeNumbersKey)
        XCTAssertFalse(UserDefaultsAppRuntimePreferences(defaults: defaults).smartFormattingEnabled)
    }
    func testPipelineRunsChainWhenEnabled() async {
        let result = await TextRefinementService().refine(
            rawText: "twenty five dollars",
            mode: .clean,
            customWords: [],
            snippets: [],
            smartFormatting: true
        )
        XCTAssertEqual(result.text, "$25")
    }
    func testPipelineSkipsChainWhenDisabled() async {
        let result = await TextRefinementService().refine(
            rawText: "twenty five dollars",
            mode: .clean,
            customWords: [],
            snippets: [],
            smartFormatting: false
        )
        XCTAssertEqual(result.text, "Twenty five dollars")  // only whitespace/capitalization step
    }
}
```

**Run after:** `swift test 2>&1 | tail -10` (full suite — the rename touches existing tests that reference `normalizeNumbers`; update them to the new name).

**Commit:** `feat(pdx): wire SpokenTextFormatter into pipeline behind smartFormattingEnabled (with legacy migration)`

---

### Task 13: Vocabulary UI — "Smart formatting" toggle

**Files:**
- Modify: the Vocabulary view + ViewModel that currently expose "Normalize numbers" — find with `grep -rn "Normalize numbers\|normalizeNumbers" Sources/MacParakeet/Views/ Sources/MacParakeetViewModels/`

**Steps:**

1. Rename the toggle title to **"Smart formatting"**.
2. Update the description to: *"Convert spoken numbers, currency, dates, times, symbols, and punctuation commands to their written form — instantly, on every dictation. ($25, June 2nd, 3:30 PM, 50%, #standup)"*
3. Bind it to `smartFormattingEnabled` (ViewModel property reads/writes the new key — same didSet pattern as other settings).
4. Build + launch `scripts/dev/run_app.sh` → Vocabulary panel shows the renamed toggle; flipping it persists across relaunch.

**Commit:** `feat(pdx): Vocabulary "Smart formatting" toggle (replaces Normalize numbers)`

---

### Task 14: AI Formatter prompt cleanup

**Files:**
- Modify: `Sources/MacParakeetCore/TextProcessing/AIFormatter.swift`
- Modify: `Sources/MacParakeetCore/Models/AppProfile.swift` (sample prompts)
- Test: `Tests/MacParakeetTests/TextProcessing/AIFormatterTests.swift` (find existing test file; create if absent)

**Steps:**

1. In `AIFormatter.swift`: rename `defaultPromptTemplate` → `legacyDefaultPromptTemplateV2` (keep contents). Add the new default:

```swift
    public static let defaultPromptTemplate = """
        You are a transcription cleanup assistant.

        Convert the following raw transcript into polished, readable text.

        Instructions:
        1. Add punctuation and capitalization.
        2. Split the text into natural sentences.
        3. Break the text into readable paragraphs whenever the speaker moves into a new topic, example, action taken, or result.
        4. Prefer short paragraphs of 1 to 3 sentences.
        5. For medium-length monologues, favor multiple paragraphs over one dense block when the ideas naturally separate.
        6. Use real paragraph breaks in the cleaned text. If you need a new paragraph, put it in the text itself instead of writing the characters \\n.
        7. Fix obvious speech-to-text errors.
        8. Remove repeated words (e.g. "the the").
        9. Numbers, dates, times, currency, percentages, and symbols are already formatted correctly — preserve them exactly as written (e.g. $25, June 2nd, 3:30 PM, 50%, #standup). Do not spell them out or reformat them.
        10. Keep the original meaning, tone, and wording as close as possible.
        11. Do not summarize, shorten, or add content.
        12. Do not explain your edits.
        13. Output only the final cleaned text.

        Raw transcript:
        {{TRANSCRIPT}}
        """
```

2. In `normalizedPromptTemplate`, fold v2 onto the new default (mirror the existing v1 fold):

```swift
        if trimmed == legacyDefaultPromptTemplateV1 || trimmed == legacyDefaultPromptTemplateV2 {
            return defaultPromptTemplate
        }
```

3. In `AppProfile.defaults`, update the Email sample prompt — replace
   "Split into sentences, capitalize correctly, fix obvious homophones, remove filler words, and write spoken numbers as digits."
   with
   "Split into sentences, capitalize correctly, and fix obvious homophones. Numbers, dates, currency, and symbols are already formatted — preserve them exactly as written."
   Add the same preserve-formatting sentence to the Notes and Chat sample prompts.

4. Tests:

```swift
    func testV2DefaultFoldsToCurrentDefault() {
        XCTAssertEqual(
            AIFormatter.normalizedPromptTemplate(AIFormatter.legacyDefaultPromptTemplateV2),
            AIFormatter.defaultPromptTemplate
        )
    }
    func testCurrentDefaultMentionsPreservingFormatting() {
        XCTAssertTrue(AIFormatter.defaultPromptTemplate.contains("preserve them exactly as written"))
    }
    func testSampleProfilesDoNotInstructNumberConversion() {
        for profile in AppProfile.defaults {
            XCTAssertFalse(profile.promptOverride?.contains("write spoken numbers as digits") ?? false,
                           "\(profile.displayName) still instructs number conversion")
            XCTAssertFalse(profile.promptOverride?.contains("remove filler words") ?? false,
                           "\(profile.displayName) still instructs filler removal")
        }
    }
```

**Commit:** `feat(pdx): AI Formatter default prompt v3 — preserve deterministic formatting; clean sample profiles`

---

### Task 15: Docs, full suite, archive

**Files:**
- Modify: `Sources/MacParakeetCore/TextProcessing/README.md` (document the chain + ordering invariant)
- Modify: spec status headers; move both smart-formatting plan docs to `plans/completed/`

**Steps:**

1. Add a "Smart formatting chain" section to `TextProcessing/README.md`: list the chain order, state that order is load-bearing (years/ordinals before cardinals; dates before symbols), and that every rule must have a pass-through guard test.
2. Run the full suite: `swift test 2>&1 | tail -10` → all green.
3. **Owner rollout (requires the owner, in the dev app):**
   - Vocabulary → Processing mode → **Clean**
   - Vocabulary → **Smart formatting** → on
   - Settings → AI Formatter → off (or repoint to a small model); if kept on, update the custom prompt + seeded per-app profiles per spec §AI Formatter Prompt Cleanup
   - Dictate: "send john twenty five dollars by june second period" → must paste `Send john $25 by June 2nd.` in ~1 second
4. Update spec status to `**IMPLEMENTED**`; `git mv` both docs to `plans/completed/`.

**Commit:** `docs(pdx): smart formatting chain README + archive plans`

---

## Self-Review Notes

- **Spec coverage:** every spec table section maps to a task (years T1, ordinals T2, currency T3, units/fractions T4, dates T5, times T6, phones T7, email/URL T8, symbols T9, punctuation T10, chain T11, toggle/mode T12–13, prompt cleanup T14, docs/rollout T15). Out-of-scope items have no tasks (correct).
- **Type consistency:** `NormalizerRegex.replace(_:pattern:_:)` and `.grouped(_:)` introduced in Task 3, used in Tasks 4–10. `OrdinalNormalizer.suffix(for:)` and `.simpleOrdinals` (internal, not private) reused by `DateNormalizer` in Task 5. `SpokenTextFormatter.format(_:)` consumed by Task 12.
- **Known judgment calls for the executor:** Swift regex escaping inside `#"..."#` raw strings with interpolation (`\#(...)`) — adjust syntax until it compiles; the tests are the contract. If `NumberNormalizer` folds "1.5 million" into digits (breaking Task 3's scale-word test), add a guard in `NumberNormalizer` to not fold scale words after a decimal — with a regression test.
- **Placeholder scan:** all steps have concrete code or exact grep/rename instructions tied to compiler errors. No TBDs.
