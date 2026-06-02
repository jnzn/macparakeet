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
