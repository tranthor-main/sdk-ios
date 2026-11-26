import Foundation

final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// What a successful response says besides success: how many events the server dropped, and how many it accepted
/// without a valid identity token.
struct ResponseNotes: Sendable, Equatable {
    var status = 200
    var dropped = 0
    var unverified = 0
}

protocol SDKTransport: Sendable {
    func send(_ batch: [[String: JSONValue]]) async throws
    /// Sends the batch with the identity tokens of its users in the body. A transport that has no use for them (a test
    /// double) needs only the plain `send`.
    func send(_ batch: [[String: JSONValue]], identityTokens: [String]) async throws -> ResponseNotes
    func shutdown()
}
extension SDKTransport {
    func send(_ batch: [[String: JSONValue]], identityTokens: [String]) async throws -> ResponseNotes {
        try await send(batch)
        return ResponseNotes()
    }
}

/// The parts of a JSON error body the SDK reads.
struct ErrorDetail: Sendable, Equatable {
    var code: String?
    var userIds: [String]?
    var reason: String?
}

final class Transport: SDKTransport, @unchecked Sendable {
    let session: URLSession
    let endpoint: URL
    let writeKey: String
    let appId: String?
    /// Guards `closed` together with every task creation and the invalidation. URLSession raises an
    /// NSGenericException ("Task created in a session that has been invalidated") that Swift cannot catch when a
    /// task is created after `invalidateAndCancel()`, so "check, then create" and "close, then invalidate"
    /// must not interleave.
    private let lock = NSLock()
    private var closed = false
    init(configuration: Configuration) throws {
        var host = configuration.host
        while host.hasSuffix("/") { host.removeLast() }
        guard let url = URL(string: host + "/api/public/apps/batch"),
              ["https", "http"].contains(url.scheme), url.host != nil else {
            throw TranthorError.invalidHost
        }
        endpoint = url
        writeKey = configuration.writeKey
        appId = configuration.appId
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.urlCache = nil
        config.httpCookieStorage = nil
        session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    /// Cancels what is in flight and refuses every later `send` with a `DeliveryFailure`.
    func shutdown() {
        lock.withLock {
            closed = true
            session.invalidateAndCancel()
        }
    }
    /// The request's task, created and started unless the transport is shut down. Nil when it is.
    private func startTask(_ request: URLRequest, _ completion: @escaping @Sendable (Data?, URLResponse?, (any Error)?) -> Void) -> URLSessionDataTask? {
        lock.withLock {
            guard !closed else { return nil }
            let task = session.dataTask(with: request, completionHandler: completion)
            task.resume()
            return task
        }
    }
    /// The running task, so cancelling the calling Task cancels the request. Cancelled before the task exists,
    /// it cancels the task as soon as it is set.
    private final class Running: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionDataTask?
        private var cancelled = false
        func set(_ task: URLSessionDataTask) { lock.withLock { self.task = task; if cancelled { task.cancel() } } }
        func cancel() { lock.withLock { cancelled = true; task?.cancel() } }
    }
    private func exchange(for request: URLRequest) async throws -> (Data, URLResponse) {
        let running = Running()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), any Error>) in
                let task = startTask(request) { data, response, error in
                    if let response { continuation.resume(returning: (data ?? Data(), response)) }
                    else { continuation.resume(throwing: error ?? URLError(.badServerResponse)) }
                }
                if let task { running.set(task) }
                else { continuation.resume(throwing: DeliveryFailure(status: nil, message: "Transport shut down", retryAfterMs: 0)) }
            }
        } onCancel: { running.cancel() }
    }
    func send(_ batch: [[String: JSONValue]]) async throws { _ = try await send(batch, identityTokens: []) }
    func send(_ batch: [[String: JSONValue]], identityTokens: [String]) async throws -> ResponseNotes {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(writeKey, forHTTPHeaderField: "Authorization")
        if let appId { request.setValue(appId, forHTTPHeaderField: "x-tranthor-app-id") }
        // Tokens travel in the body, beside the events and never inside one; the field is left out when there are none.
        var body: [String: JSONValue] = ["batch": .array(batch.map(JSONValue.object))]
        if !identityTokens.isEmpty { body["identityTokens"] = .array(identityTokens.map(JSONValue.string)) }
        request.httpBody = try JSONEncoder().encode(JSONValue.object(body))
        do {
            let (data, response) = try await exchange(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw DeliveryFailure(status: nil, message: "No HTTP response", retryAfterMs: 0)
            }
            guard (200...299).contains(http.statusCode) else {
                let detail = Self.errorDetail(data, status: http.statusCode)
                // An identity 503 is held for the server's Retry-After, up to five minutes; the rest keep the 30 s cap.
                let identityUnavailable = detail.code.map { unavailableCodes.contains($0) } == true
                let wait = Self.retryAfterMs(http.value(forHTTPHeaderField: "Retry-After"), identityUnavailable: identityUnavailable)
                throw DeliveryFailure(status: http.statusCode, message: "HTTP delivery failure", retryAfterMs: wait,
                                      code: detail.code, userIds: detail.userIds, reason: detail.reason)
            }
            return ResponseNotes(status: http.statusCode, dropped: Self.count(http, "x-tranthor-dropped-events"),
                                 unverified: Self.count(http, "x-tranthor-unverified-events"))
        } catch let error as DeliveryFailure { throw error }
        catch { throw DeliveryFailure(status: nil, message: "Network delivery failure", retryAfterMs: 0) }
    }
    /// The machine-readable `code` and the named `userIds` of a JSON error body, and nothing else from it: the body is
    /// never kept, so it cannot carry a token or user data into a report. Only the two refusals the SDK acts on are read.
    static func errorDetail(_ data: Data, status: Int) -> ErrorDetail {
        guard status == 403 || status == 503, data.count <= 64 * 1024,
              let body = try? JSONDecoder().decode(JSONValue.self, from: data), body.object != nil,
              let code = body["code"]?.string, code.utf8.count <= 100 else { return ErrorDetail() }
        let ids = body["userIds"]?.array?.compactMap(\.string)
        // The reason list is open: any short word is kept, nothing is branched on it.
        let reason = body["reason"]?.string.flatMap { $0.utf8.count <= 40 ? $0 : nil }
        return ErrorDetail(code: code, userIds: ids.map { Array($0.prefix(50)) }, reason: reason)
    }
    /// How long the server asked to wait. For identity settings it could not read the wait is honoured up to five
    /// minutes, and is at least a second when the server named 0; every other failure keeps the ordinary cap.
    static func retryAfterMs(_ header: String?, identityUnavailable: Bool) -> Double {
        let wait = retryAfter(header, capSeconds: identityUnavailable ? 300 : 30)
        if identityUnavailable, wait == 0, header?.isASCIIDigits == true { return unavailableHoldMinMs }
        return wait
    }
    /// A non-negative whole number in a response header, or 0.
    static func count(_ response: HTTPURLResponse, _ name: String) -> Int {
        guard let value = response.value(forHTTPHeaderField: name), value.count < 10, value.isASCIIDigits else { return 0 }
        return Int(value) ?? 0
    }
}
