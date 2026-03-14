import Foundation

/// A single telemetry event queued for batch submission.
public struct TelemetryEvent: Sendable, Encodable {
    public let eventId: String
    public let event: String
    public let props: [String: String]?
    public let appVer: String
    public let osVer: String
    public let locale: String?
    public let chip: String
    public let session: String
    public let ts: String

    public init(
        event: String,
        props: [String: String]? = nil,
        appVer: String,
        osVer: String,
        locale: String?,
        chip: String,
        session: String,
        ts: Date = Date()
    ) {
        self.eventId = UUID().uuidString
        self.event = event
        self.props = props
        self.appVer = appVer
        self.osVer = osVer
        self.locale = locale
        self.chip = chip
        self.session = session
        self.ts = Self.iso8601Formatter.string(from: ts)
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

/// Batch payload sent to the telemetry endpoint.
struct TelemetryPayload: Sendable, Encodable {
    let events: [TelemetryEvent]
}
