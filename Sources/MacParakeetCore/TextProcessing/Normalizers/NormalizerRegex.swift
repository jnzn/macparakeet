import Foundation

/// Shared regex utilities for the spoken-text normalizer chain.
public enum NormalizerRegex {
    /// NSRegularExpression-based replace with capture-group access.
    /// Iterates matches in REVERSE so earlier ranges stay valid after replacement.
    public static func replace(_ text: String, pattern: String, _ transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var result = text
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

    /// Format an integer string with thousands separators ("5000" → "5,000").
    public static func grouped(_ digits: String) -> String {
        guard let value = Int(digits) else { return digits }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: value)) ?? digits
    }
}
