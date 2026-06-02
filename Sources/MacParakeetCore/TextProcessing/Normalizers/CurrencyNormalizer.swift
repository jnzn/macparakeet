import Foundation

/// Digit-form currency phrases → symbols ("25 dollars" → "$25"). Runs after
/// NumberNormalizer so amounts are already digits. "pounds" is deliberately
/// excluded (£ vs weight is ambiguous for a US-based owner).
public enum CurrencyNormalizer {
    public static func normalize(_ text: String) -> String {
        var result = text

        // "X dollars and Y cents" → $X.YY (cents zero-padded to 2 digits)
        result = NormalizerRegex.replace(result, pattern: #"(\d+) dollars and (\d{1,2}) cents"#) { groups in
            let cents = String(format: "%02d", Int(groups[2]) ?? 0)
            return "$\(groups[1]).\(cents)"
        }
        // "X million/billion/thousand dollars|bucks" → $X million
        result = NormalizerRegex.replace(result, pattern: #"(\d+(?:\.\d+)?) (million|billion|thousand) (?:dollars|bucks)"#) { groups in
            "$\(groups[1]) \(groups[2])"
        }
        // "X dollars|bucks" → $X
        result = NormalizerRegex.replace(result, pattern: #"(\d+(?:,\d{3})*(?:\.\d+)?) (?:dollars|bucks)"#) { groups in
            "$\(groups[1])"
        }
        // euros / won / yen — won gets thousands separators (₩5,000)
        result = NormalizerRegex.replace(result, pattern: #"(\d+(?:,\d{3})*(?:\.\d+)?) euros?"#) { g in "€\(g[1])" }
        result = NormalizerRegex.replace(result, pattern: #"(\d+) won"#) { groups in
            "₩\(NormalizerRegex.grouped(groups[1]))"
        }
        result = NormalizerRegex.replace(result, pattern: #"(\d+(?:,\d{3})*) yen"#) { g in "¥\(g[1])" }
        return result
    }
}
