import Foundation
import OSLog

// MARK: - Protocol

public protocol TelemetryServiceProtocol: Sendable {
    func send(_ event: String, props: [String: String]?)
    func flush() async
}

extension TelemetryServiceProtocol {
    public func send(_ event: String) {
        send(event, props: nil)
    }
}

// MARK: - Implementation

public final class TelemetryService: TelemetryServiceProtocol, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "Telemetry")
    private let lock = NSLock()
    private var queue: [TelemetryEvent] = []
    private var flushTimer: Timer?

    private let baseURL: URL
    private let session: URLSession
    private let sessionId: String
    private let appVer: String
    private let osVer: String
    private let locale: String?
    private let chip: String
    private let isEnabled: () -> Bool

    static let maxQueueSize = 200
    static let flushThreshold = 50
    static let flushInterval: TimeInterval = 60

    /// Events that must be flushed immediately (not batched).
    private static let immediateEvents: Set<String> = [
        "telemetry_opted_out",
        "onboarding_completed",
        "license_activated",
        "trial_started",
        "trial_expired",
        "purchase_started",
        "restore_attempted",
        "restore_succeeded",
        "restore_failed",
    ]

    public init(
        baseURL: URL? = nil,
        session: URLSession = .shared,
        isEnabled: @escaping () -> Bool = {
            UserDefaults.standard.object(forKey: "telemetryEnabled") as? Bool ?? true
        }
    ) {
        if let baseURL {
            self.baseURL = baseURL
        } else if let envURL = ProcessInfo.processInfo.environment["MACPARAKEET_TELEMETRY_URL"],
                  let url = URL(string: envURL) {
            self.baseURL = url
        } else {
            self.baseURL = URL(string: "https://macparakeet.com/api")!
        }
        self.session = session
        self.isEnabled = isEnabled
        self.sessionId = UUID().uuidString

        // Collect device context once at init
        let info = SystemInfo.current
        self.appVer = info.appVersion
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        self.osVer = "\(osVersion.majorVersion).\(osVersion.minorVersion)"
        self.locale = Locale.current.identifier
        self.chip = info.chipType

        startTimer()
        registerLifecycleObservers()
    }

    deinit {
        flushTimer?.invalidate()
    }

    public func send(_ event: String, props: [String: String]? = nil) {
        guard isEnabled() || event == "telemetry_opted_out" else { return }

        let telemetryEvent = TelemetryEvent(
            event: event,
            props: props,
            appVer: appVer,
            osVer: osVer,
            locale: locale,
            chip: chip,
            session: sessionId
        )

        var shouldFlush = false
        lock.lock()
        queue.append(telemetryEvent)
        if queue.count > Self.maxQueueSize {
            queue.removeFirst()
        }
        shouldFlush = queue.count >= Self.flushThreshold || Self.immediateEvents.contains(event)
        lock.unlock()

        if shouldFlush {
            Task { await flush() }
        }
    }

    /// Maximum events per HTTP request (must match server's MAX_BATCH_SIZE).
    static let maxBatchSize = 100

    public func flush() async {
        let events: [TelemetryEvent]
        lock.lock()
        events = queue
        queue.removeAll()
        lock.unlock()

        guard !events.isEmpty else { return }

        // Chunk into batches of maxBatchSize to stay within server limits.
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let url = baseURL.appendingPathComponent("telemetry")

        for batchStart in stride(from: 0, to: events.count, by: Self.maxBatchSize) {
            let batchEnd = min(batchStart + Self.maxBatchSize, events.count)
            let batch = Array(events[batchStart..<batchEnd])
            let payload = TelemetryPayload(events: batch)

            guard let body = try? encoder.encode(payload) else {
                logger.error("Failed to encode telemetry payload")
                continue
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            request.timeoutInterval = 10

            do {
                let (_, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    logger.warning("Telemetry server returned \(http.statusCode)")
                }
            } catch {
                // Fire-and-forget: silently drop on network failure
                logger.debug("Telemetry flush failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Internal (for testing)

    var pendingEventCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return queue.count
    }

    // MARK: - Private

    private func startTimer() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let timer = Timer(timeInterval: Self.flushInterval, repeats: true) { [weak self] _ in
                guard let self else { return }
                Task { await self.flush() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.flushTimer = timer
        }
    }

    private func registerLifecycleObservers() {
        let nc = NotificationCenter.default

        nc.addObserver(forName: NSNotification.Name("NSApplicationWillTerminateNotification"),
                      object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            // Synchronous flush on termination — best effort
            self.flushSync()
        }

        // Note: NSWorkspace.willSleepNotification requires NSWorkspace.shared.notificationCenter
        // which is AppKit-only. The termination observer above handles the primary flush-on-quit
        // path. Sleep flush can be wired from the GUI layer if needed.
    }

    /// Best-effort synchronous flush for app termination.
    private func flushSync() {
        let events: [TelemetryEvent]
        lock.lock()
        events = queue
        queue.removeAll()
        lock.unlock()

        guard !events.isEmpty else { return }

        let payload = TelemetryPayload(events: events)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let body = try? encoder.encode(payload) else { return }

        let url = baseURL.appendingPathComponent("telemetry")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 5

        // Synchronous send on a background queue to avoid main thread deadlock.
        let bgSession = URLSession(configuration: .ephemeral,
                                   delegate: nil,
                                   delegateQueue: OperationQueue())
        let semaphore = DispatchSemaphore(value: 0)
        let task = bgSession.dataTask(with: request) { _, _, _ in
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 3)
    }
}

// MARK: - Static Convenience

/// Ergonomic static wrapper for fire-and-forget telemetry.
///
/// Usage:
/// ```swift
/// Telemetry.send("dictation_completed", ["duration_seconds": "12.5"])
/// Telemetry.send("app_launched")
/// ```
public enum Telemetry {
    private static let lock = NSLock()
    private static var _service: TelemetryServiceProtocol?

    /// Configure the shared telemetry instance. Call once at app startup.
    public static func configure(_ service: TelemetryServiceProtocol) {
        lock.lock()
        _service = service
        lock.unlock()
    }

    /// Send a telemetry event. No-op if not configured.
    public static func send(_ event: String, _ props: [String: String]? = nil) {
        lock.lock()
        let service = _service
        lock.unlock()
        service?.send(event, props: props)
    }

    /// Flush pending events. No-op if not configured.
    public static func flush() async {
        lock.lock()
        let service = _service
        lock.unlock()
        await service?.flush()
    }
}

// MARK: - No-Op Implementation (for tests and CLI)

public final class NoOpTelemetryService: TelemetryServiceProtocol {
    public init() {}
    public func send(_ event: String, props: [String: String]?) {}
    public func flush() async {}
}
