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
            let pattern = "(\\d+(?:\\.\\d+)?) " + NSRegularExpression.escapedPattern(for: spoken) + "\\b"
            result = NormalizerRegex.replace(result, pattern: pattern) { groups in
                attach ? "\(groups[1])\(abbrev)" : "\(groups[1]) \(abbrev)"
            }
        }
        result = NormalizerRegex.replace(result, pattern: "\\b1 half\\b") { _ in "1/2" }
        result = NormalizerRegex.replace(result, pattern: "\\b3 quarters\\b") { _ in "3/4" }
        return result
    }
}
