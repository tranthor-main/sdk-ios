import Foundation

/// Settings for ``TranthorSDK``. Only `writeKey` is required. A numeric option that is not usable falls back to its
/// default, or is clamped where noted, so a bad value never stops the SDK.
public struct Configuration: Sendable {
    /// The workspace's write key, sent with every request.
    public let writeKey: String
    /// The Tranthor API origin, an `http` or `https` URL.
    public let host: String
    /// Events sent per request. Reaching it starts delivery at once. A whole number above 0; anything else, including a
    /// fractional value, uses the default 5.
    public let batchSize: Int
    /// Milliseconds from the first queued event until delivery starts, if the batch is not yet full. A whole number
    /// above 0; anything else uses the default 500.
    public let flushIntervalMs: Int
    /// Retries after the first failed attempt, for retryable failures only. A fractional value is rounded down, a
    /// negative one becomes 0 (no retries), and a non-finite or oversized one uses the default 5.
    public let retries: Int
    /// Milliseconds before the first retry; each retry doubles it, up to 30 seconds. A negative value becomes 0
    /// (retry at once) and a non-finite one uses the default 500. A fractional value is kept.
    public let baseDelay: Double
    /// Whether events carry library, OS, device, app, locale and time zone context. Default true.
    public let automaticContext: Bool
    /// Separates the stored queue and identity of several SDK instances in one app. Default "default".
    public let storageNamespace: String
    /// Where the queue and identity are stored. Default: the app's Application Support folder.
    public let storageDirectory: URL?
    /// Events kept on disk and in memory; beyond it the oldest are dropped. Zero or less uses the default 10,000.
    public let maxQueueSize: Int
    /// Called when the server rejects a batch, or when events are dropped for lack of room. Not called when retries run out: those events are kept and sent later. Optional.
    public let onError: (@Sendable (BatchFailure) -> Void)?

    /// Creates a configuration. The numeric options take a `Double` so a value from JSON or a remote setting needs no
    /// conversion; see each property for how an unusable value is handled.
    public init(writeKey: String, host: String = "https://api.tranthor.com",
                batchSize: Double? = nil, flushIntervalMs: Double? = nil,
                retries: Double? = nil, baseDelay: Double? = nil,
                automaticContext: Bool = true, storageNamespace: String = "default",
                storageDirectory: URL? = nil, maxQueueSize: Int = 10_000,
                onError: (@Sendable (BatchFailure) -> Void)? = nil) {
        self.writeKey = writeKey
        self.host = host
        self.batchSize = Self.positiveInteger(batchSize, fallback: 5)
        self.flushIntervalMs = Self.positiveInteger(flushIntervalMs, fallback: 500)
        self.retries = Self.nonnegativeInteger(retries, fallback: 5)
        self.baseDelay = baseDelay.flatMap { $0.isFinite ? max(0, $0) : nil } ?? 500
        self.automaticContext = automaticContext
        self.storageNamespace = storageNamespace
        self.storageDirectory = storageDirectory
        self.maxQueueSize = maxQueueSize > 0 ? maxQueueSize : 10_000
        self.onError = onError
    }

    /// The same options, taking integer values. A call with no numeric option uses the `Double` initializer.
    public init<N: BinaryInteger & Sendable>(writeKey: String, host: String = "https://api.tranthor.com",
                batchSize: N? = nil, flushIntervalMs: N? = nil,
                retries: N? = nil, baseDelay: N? = nil,
                automaticContext: Bool = true, storageNamespace: String = "default",
                storageDirectory: URL? = nil, maxQueueSize: Int = 10_000,
                onError: (@Sendable (BatchFailure) -> Void)? = nil) {
        self.init(writeKey: writeKey, host: host,
                  batchSize: batchSize.map { Double($0) }, flushIntervalMs: flushIntervalMs.map { Double($0) },
                  retries: retries.map { Double($0) }, baseDelay: baseDelay.map { Double($0) },
                  automaticContext: automaticContext, storageNamespace: storageNamespace,
                  storageDirectory: storageDirectory, maxQueueSize: maxQueueSize, onError: onError)
    }

    private static func positiveInteger(_ v: Double?, fallback: Int) -> Int {
        guard let v, v.isFinite, v > 0, v.rounded(.down) == v, v < Double(Int.max) else { return fallback }
        return Int(v)
    }
    private static func nonnegativeInteger(_ v: Double?, fallback: Int) -> Int {
        guard let v, v.isFinite, v < Double(Int.max) else { return fallback }
        return Int(max(0, v.rounded(.down)))
    }
}

/// Why a request to the Tranthor API failed.
public struct DeliveryFailure: Error, Sendable, Equatable {
    /// The HTTP status code, or nil when there was no response (a network failure).
    public let status: Int?
    /// A short description. It never contains the write key or event data.
    public let message: String
    /// How long the server asked to wait before retrying (`Retry-After`), in milliseconds; 0 if it did not.
    public let retryAfterMs: Double
    /// Creates a failure, for example to test an `onError` handler.
    public init(status: Int?, message: String, retryAfterMs: Double = 0) {
        self.status = status
        self.message = message
        self.retryAfterMs = retryAfterMs
    }
    var retryable: Bool { status == nil || status == 408 || status == 425 || status == 429 || (500...599).contains(status ?? 0) }
}

/// A batch of events that was not delivered, passed to `Configuration.onError`.
public struct BatchFailure: Sendable {
    /// The failure that ended delivery of the batch.
    public let error: DeliveryFailure
    /// The undelivered events as they were queued. Push tokens are replaced by `"<redacted>"`.
    public let events: [[String: JSONValue]]
    /// How many times delivery was attempted; 0 for events dropped for lack of room.
    public let attempts: Int
    /// Creates a failure, for example to test an `onError` handler.
    public init(error: DeliveryFailure, events: [[String: JSONValue]], attempts: Int) {
        self.error = error
        self.events = events
        self.attempts = attempts
    }
}

/// Only ASCII RFC 9110 delay-seconds; saturate huge values at the policy cap.
func retryAfter(_ value: String?) -> Double {
    guard let value, !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) else { return 0 }
    var seconds = 0.0
    for digit in value.utf8 { seconds = min(30, seconds * 10 + Double(digit - 48)) }
    return seconds * 1000
}
func retryDelay(base: Double, attempt: Int, requested: Double) -> Double {
    min(30000, max(base == 0 ? 0 : base * pow(2, Double(attempt)), requested))
}
