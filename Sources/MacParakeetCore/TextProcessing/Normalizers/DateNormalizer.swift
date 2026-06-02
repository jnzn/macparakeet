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
    private static let monthAlternation = months.keys.sorted().joined(separator: "|")

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
            pattern: "([0-9]{4}) (?:hyphen|dash) (" + monthAlternation + ") (?:hyphen|dash) ([a-zA-Z0-9]+)"
        ) { groups in
            guard let month = months[groups[2].lowercased()],
                  let day = Self.dayValue(groups[3]) else { return groups[0] }
            return String(format: "%@-%02d-%02d", groups[1], month.number, day)
        }

        // 2. "the (day) of (month)" → "Month Day"
        result = NormalizerRegex.replace(
            result,
            pattern: "\\bthe ([a-zA-Z0-9]+(?:st|nd|rd|th)?) of (" + monthAlternation + ")\\b"
        ) { groups in
            guard let month = months[groups[2].lowercased()],
                  let day = Self.dayValue(groups[1]) else { return groups[0] }
            return "\(month.display) \(formatDay(day))"
        }

        // 3. "(month) (day)[ (year)]" → "Month Day[, Year]"
        //    Day must be a word ordinal, digits+suffix, or 1–2 bare digits.
        result = NormalizerRegex.replace(
            result,
            pattern: "\\b(" + monthAlternation + ") ([0-9]{1,2}(?:st|nd|rd|th)?|first|second|third|fourth|fifth|sixth|seventh|eighth|ninth)( [0-9]{4})?\\b"
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
        let digits = lower.replacingOccurrences(of: "(st|nd|rd|th)$", with: "", options: .regularExpression)
        guard let n = Int(digits), (1...31).contains(n) else { return nil }
        return n
    }
}
