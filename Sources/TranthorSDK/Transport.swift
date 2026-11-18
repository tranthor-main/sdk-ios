import Foundation

final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

protocol SDKTransport: Sendable {
    func send(_ batch: [[String: JSONValue]]) async throws
    func shutdown()
}

final class Transport: SDKTransport, @unchecked Sendable {
    let session: URLSession
    let endpoint: URL
    let writeKey: String
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
    private func response(for request: URLRequest) async throws -> URLResponse {
        let running = Running()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URLResponse, any Error>) in
                let task = startTask(request) { _, response, error in
                    if let response { continuation.resume(returning: response) }
                    else { continuation.resume(throwing: error ?? URLError(.badServerResponse)) }
                }
                if let task { running.set(task) }
                else { continuation.resume(throwing: DeliveryFailure(status: nil, message: "Transport shut down", retryAfterMs: 0)) }
            }
        } onCancel: { running.cancel() }
    }
    func send(_ batch: [[String: JSONValue]]) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(writeKey, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(JSONValue.object(["batch": .array(batch.map(JSONValue.object))]))
        do {
            let response = try await response(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw DeliveryFailure(status: nil, message: "No HTTP response", retryAfterMs: 0)
            }
            guard (200...299).contains(http.statusCode) else {
                throw DeliveryFailure(status: http.statusCode, message: "HTTP delivery failure",
                                      retryAfterMs: retryAfter(http.value(forHTTPHeaderField: "Retry-After")))
            }
        } catch let error as DeliveryFailure { throw error }
        catch { throw DeliveryFailure(status: nil, message: "Network delivery failure", retryAfterMs: 0) }
    }
}
