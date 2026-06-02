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
