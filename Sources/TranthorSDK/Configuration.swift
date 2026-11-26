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
    /// Supplies a fresh identity token for a user, or nil when there is none. Called with the user ID when the current
    /// user's cached token is missing or has less than 60 seconds left, and again after the server refuses a token.
    /// The token is a JWT your own backend signs for that user ID; the SDK never verifies it and never logs it. Throwing
    /// or returning nil means "no token for this user": the batch is still sent with the tokens the SDK has, and the
    /// provider is not called again for 60 seconds, and a batch held for lack of a token waits that long. Optional.
    public let identityTokenProvider: (@Sendable (String) async throws -> String?)?
    /// The app ID sent as `x-tranthor-app-id` on every request. Default: the app's bundle identifier. An empty value
    /// uses the default. Nil when the app has no bundle identifier and none was given, and then no header is sent.
    public let appId: String?
    /// Milliseconds a batch waits for `identityTokenProvider` before it is sent anyway. Default 20,000. Not public API:
    /// tests set it. Anything that is not a number above 0 keeps the previous value.
    @_spi(Testing) public var identityProviderTimeoutMs: Double = 20_000 { didSet { if !(identityProviderTimeoutMs.isFinite && identityProviderTimeoutMs > 0) { identityProviderTimeoutMs = oldValue } } }
    /// Milliseconds after a provider failure before it is called again, and how long a batch held for lack of a token
    /// waits. Default 60,000. Test-only (SPI "Testing"), not public API.
    @_spi(Testing) public var identityProviderBackoffMs: Double = 60_000 { didSet { if !(identityProviderBackoffMs.isFinite && identityProviderBackoffMs > 0) { identityProviderBackoffMs = oldValue } } }
    /// Called with a diagnostic that is not an error: events the server dropped or could not verify, an identity token
    /// it refused, or identity settings it could not read. Nothing it carries is a token or a user ID. Optional.
    public let onNotice: (@Sendable (Notice) -> Void)?

    /// Creates a configuration. The numeric options take a `Double` so a value from JSON or a remote setting needs no
    /// conversion; see each property for how an unusable value is handled.
    public init(writeKey: String, host: String = "https://api.tranthor.com",
                batchSize: Double? = nil, flushIntervalMs: Double? = nil,
                retries: Double? = nil, baseDelay: Double? = nil,
                automaticContext: Bool = true, storageNamespace: String = "default",
                storageDirectory: URL? = nil, maxQueueSize: Int = 10_000,
                onError: (@Sendable (BatchFailure) -> Void)? = nil,
                identityTokenProvider: (@Sendable (String) async throws -> String?)? = nil,
                appId: String? = nil,
                onNotice: (@Sendable (Notice) -> Void)? = nil) {
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
        self.identityTokenProvider = identityTokenProvider
        self.appId = appId.flatMap { $0.isEmpty ? nil : $0 } ?? Bundle.main.bundleIdentifier
        self.onNotice = onNotice
    }

    /// The same options, taking integer values. A call with no numeric option uses the `Double` initializer.
    public init<N: BinaryInteger & Sendable>(writeKey: String, host: String = "https://api.tranthor.com",
                batchSize: N? = nil, flushIntervalMs: N? = nil,
                retries: N? = nil, baseDelay: N? = nil,
                automaticContext: Bool = true, storageNamespace: String = "default",
                storageDirectory: URL? = nil, maxQueueSize: Int = 10_000,
                onError: (@Sendable (BatchFailure) -> Void)? = nil,
                identityTokenProvider: (@Sendable (String) async throws -> String?)? = nil,
                appId: String? = nil,
                onNotice: (@Sendable (Notice) -> Void)? = nil) {
        self.init(writeKey: writeKey, host: host,
                  batchSize: batchSize.map { Double($0) }, flushIntervalMs: flushIntervalMs.map { Double($0) },
                  retries: retries.map { Double($0) }, baseDelay: baseDelay.map { Double($0) },
                  automaticContext: automaticContext, storageNamespace: storageNamespace,
                  storageDirectory: storageDirectory, maxQueueSize: maxQueueSize, onError: onError,
                  identityTokenProvider: identityTokenProvider, appId: appId,
                  onNotice: onNotice)
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
    /// The machine-readable `code` of the server's JSON error body, for example `identity_not_verified`; nil when
    /// the response had none.
    public let code: String?
    /// The user IDs a `403 identity_not_verified` named, when it named any.
    public let userIds: [String]?
    /// Why the server refused an identity token (`missing`, `signature`, `expired`, `lifetime`, `audience`...), when it
    /// said. The list is open: `missing`, `malformed`, `unknown_key`, `signature`, `expired`, `not_yet_valid`, `lifetime`,
    /// `audience`, `workspace`. Renewing cannot fix `lifetime`, `malformed`, `audience`, `workspace`, `unknown_key` or
    /// `signature`: those are a fault in the code that signs tokens.
    public let reason: String?
    /// Creates a failure, for example to test an `onError` handler.
    public init(status: Int?, message: String, retryAfterMs: Double = 0, code: String? = nil, userIds: [String]? = nil,
                reason: String? = nil) {
        self.reason = reason
        self.status = status
        self.message = message
        self.retryAfterMs = retryAfterMs
        self.code = code
        self.userIds = userIds
    }
    var retryable: Bool { status == nil || status == 408 || status == 425 || status == 429 || (500...599).contains(status ?? 0) }
}

/// A diagnostic from the SDK that is not an error: nothing failed for good. It never contains a token or a user ID.
public struct Notice: Sendable, Equatable {
    /// What happened.
    public enum Kind: String, Sendable {
        /// The server answered 2xx but dropped events. `count` says how many. In Required mode this includes anonymous
        /// events that could change a customer: register push and send traits after sign-in.
        case eventsDropped = "events-dropped"
        /// The server accepted events that had no valid identity token (monitor mode). `count` says how many.
        case eventsUnverified = "events-unverified"
        /// The server refused an identity token and the SDK holds the batch, or could not renew. `reason` is the
        /// server's word for it. `lifetime`, `malformed`, `audience`, `workspace`, `unknown_key` and `signature` are a
        /// fault in the code that signs tokens; renewing cannot fix them.
        case identityRefused = "identity-refused"
        /// The server could not read its identity settings. The batch is kept and sent again later.
        case identityUnavailable = "identity-unavailable"
    }
    public let kind: Kind
    /// How many events, for the two `events-` kinds.
    public let count: Int?
    /// The server's reason for refusing a token, for `identityRefused`, when it gave one.
    public let reason: String?
    /// A short description for a developer.
    public let message: String
    /// Creates a notice, for example to test an `onNotice` handler.
    public init(kind: Kind, count: Int? = nil, reason: String? = nil, message: String) {
        self.kind = kind
        self.count = count
        self.reason = reason
        self.message = message
    }
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
func retryAfter(_ value: String?, capSeconds: Double = 30) -> Double {
    guard let value, value.isASCIIDigits else { return 0 }
    var seconds = 0.0
    for digit in value.utf8 { seconds = min(capSeconds, seconds * 10 + Double(digit - 48)) }
    return seconds * 1000
}
func retryDelay(base: Double, attempt: Int, requested: Double) -> Double {
    min(30000, max(base == 0 ? 0 : base * pow(2, Double(attempt)), requested))
}

extension String {
    /// Non-empty and only ASCII digits: the form of an HTTP delay in seconds and of a count in a header.
    var isASCIIDigits: Bool { !isEmpty && utf8.allSatisfy { (48...57).contains($0) } }
}
