import Foundation

/// Digit times with an am/pm/o'clock anchor → clock format ("3 30 pm" → "3:30 PM").
/// Bare digit pairs without an anchor are never touched.
public enum TimeNormalizer {
    public static func normalize(_ text: String) -> String {
        var result = text
        // "H MM am|pm" (including "a m" / "p m" spaced variants) → H:MM AM/PM
        // Pattern: \b(\d{1,2}) (\d{2}) ([ap])\.? ?m\b
        result = NormalizerRegex.replace(
            result,
            pattern: "\\b([0-9]{1,2}) ([0-9]{2}) ([ap])\\.? ?m\\b"
        ) { groups in
            "\(groups[1]):\(groups[2]) \(groups[3].uppercased())M"
        }
        // "H am|pm" (including "a m" / "p m" spaced variants) → H:00 AM/PM
        // Pattern: \b(\d{1,2}) ([ap])\.? ?m\b
        result = NormalizerRegex.replace(
            result,
            pattern: "\\b([0-9]{1,2}) ([ap])\\.? ?m\\b"
        ) { groups in
            "\(groups[1]):00 \(groups[2].uppercased())M"
        }
        // "H o'clock" or "H oclock" → H:00
        result = NormalizerRegex.replace(
            result,
            pattern: "\\b([0-9]{1,2}) o'?clock\\b"
        ) { groups in
            "\(groups[1]):00"
        }
        return result
    }
}
