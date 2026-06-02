import Foundation

/// Spoken two-part years → digits ("twenty twenty six" → 2026). Must run
/// BEFORE NumberNormalizer, which would otherwise merge-mangle these into
/// "20 20 6". Guard: result must land in 1900–2099.
///
/// Input contract: space-separated word tokens without inline punctuation
/// (raw ASR output). Punctuation-attached words ("six.") will not match.
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
