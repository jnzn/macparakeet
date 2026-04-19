import Foundation

/// Single-source-of-truth rule for accepting an HTTP override URL pointed at
/// an Ollama daemon. Both `LLMSettingsDraft` (formatter / live-cleanup
/// provider) and the onboarding AI Assistant step consult this validator so
/// the two surfaces never diverge on which hosts a user can target.
///
/// Allowed:
/// - Any `https://` URL.
/// - `http://` to loopback (`localhost`, `127.0.0.1`, `::1`).
/// - `http://` to Tailscale MagicDNS (`*.ts.net`).
/// - `http://` to Tailscale CGNAT range `100.64.0.0/10`.
/// - `http://` to RFC 1918 private LAN ranges.
/// - `http://` to mDNS `*.local` Bonjour hostnames.
public enum OllamaURLValidator {
    public static func isAllowedBaseURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else {
            return false
        }
        if scheme == "https" {
            return true
        }
        guard scheme == "http" else {
            return false
        }
        if host == "localhost" || host == "127.0.0.1" || host == "::1" {
            return true
        }
        if host.hasSuffix(".ts.net") {
            return true
        }
        if let ip = parseIPv4(host), ip.a == 100, ip.b >= 64, ip.b <= 127 {
            return true
        }
        if let ip = parseIPv4(host) {
            if ip.a == 10 { return true }
            if ip.a == 172, ip.b >= 16, ip.b <= 31 { return true }
            if ip.a == 192, ip.b == 168 { return true }
        }
        if host.hasSuffix(".local") {
            return true
        }
        return false
    }

    private static func parseIPv4(_ host: String) -> (a: Int, b: Int, c: Int, d: Int)? {
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return nil }
        let ints = parts.compactMap { Int($0) }
        guard ints.count == 4,
              ints.allSatisfy({ $0 >= 0 && $0 <= 255 }) else { return nil }
        return (ints[0], ints[1], ints[2], ints[3])
    }
}
