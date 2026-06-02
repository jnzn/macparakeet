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
            pattern: "\\b([\\w.]+) at ([\\w]+) dot (" + tlds + ")\\b"
        ) { g in "\(g[1])@\(g[2]).\(g[3])" }
        // URL with path: "(host) dot (tld) slash (path)" → host.tld/path
        result = NormalizerRegex.replace(
            result,
            pattern: "\\b([\\w]+) dot (" + tlds + ") slash ([\\w]+)\\b"
        ) { g in "\(g[1]).\(g[2])/\(g[3])" }
        // Bare domain: "(host) dot (tld)" → host.tld
        result = NormalizerRegex.replace(
            result,
            pattern: "\\b([\\w]+) dot (" + tlds + ")\\b"
        ) { g in "\(g[1]).\(g[2])" }
        return result
    }
}
