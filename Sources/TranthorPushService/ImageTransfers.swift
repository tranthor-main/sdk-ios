import Foundation

/// The URLSession delegate behind `RichImageDownloader`. It checks the response before the body arrives, writes
/// the body to a file chunk by chunk, cancels the transfer at the size cap, and refuses every redirect.
final class ImageTransfers: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private final class Transfer: @unchecked Sendable {
        let handle: FileHandle
        let configuration: RichImageConfiguration
        var continuation: CheckedContinuation<String, any Error>?
        var mime = ""
        var expectedLength: Int64 = -1
        var encoding: String?
        var received = 0
        var failure: (any Error)?
        var cancelledByCaller = false
        init(handle: FileHandle, configuration: RichImageConfiguration) { self.handle = handle; self.configuration = configuration }
    }
    private let lock = NSLock()
    private var transfers: [Int: Transfer] = [:]

    /// Downloads `request` into `file` and returns the response's MIME type once the whole body has been written.
    func download(_ request: URLRequest, using session: URLSession, into file: URL, configuration: RichImageConfiguration) async throws -> String {
        let transfer = Transfer(handle: try FileHandle(forWritingTo: file), configuration: configuration)
        defer { try? transfer.handle.close() }
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                transfer.continuation = continuation
                transfers[task.taskIdentifier] = transfer
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            lock.lock(); transfer.cancelledByCaller = true; lock.unlock()
            task.cancel()
        }
    }

    private func transfer(for task: URLSessionTask) -> Transfer? {
        lock.lock(); defer { lock.unlock() }
        return transfers[task.taskIdentifier]
    }
    private func fail(_ transfer: Transfer, _ error: any Error, cancelling task: URLSessionTask) {
        lock.lock()
        if transfer.failure == nil { transfer.failure = error }
        lock.unlock()
        task.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let transfer = transfer(for: dataTask) else { return completionHandler(.cancel) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url.map(transfer.configuration.accepts) == true,
              let mime = http.mimeType?.lowercased(), ["image/png", "image/jpeg", "image/gif"].contains(mime) else {
            lock.lock(); transfer.failure = RichImageError.invalidResponse; lock.unlock()
            return completionHandler(.cancel)
        }
        guard response.expectedContentLength <= Int64(transfer.configuration.maximumBytes) else {
            lock.lock(); transfer.failure = RichImageError.oversizedImage; lock.unlock()
            return completionHandler(.cancel)
        }
        transfer.mime = mime
        transfer.expectedLength = response.expectedContentLength
        transfer.encoding = http.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let transfer = transfer(for: dataTask), transfer.failure == nil else { return }
        transfer.received += data.count
        guard transfer.received <= transfer.configuration.maximumBytes else { return fail(transfer, RichImageError.oversizedImage, cancelling: dataTask) }
        do { try transfer.handle.write(contentsOf: data) } catch { fail(transfer, error, cancelling: dataTask) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock()
        guard let transfer = transfers.removeValue(forKey: task.taskIdentifier), let continuation = transfer.continuation else {
            lock.unlock(); return
        }
        transfer.continuation = nil
        let failure = transfer.failure, cancelled = transfer.cancelledByCaller
        lock.unlock()
        if let failure { return continuation.resume(throwing: failure) }
        if cancelled { return continuation.resume(throwing: CancellationError()) }
        if let error { return continuation.resume(throwing: error) }
        // The body is decoded, so a compressed response's Content-Length describes different bytes.
        if transfer.encoding == nil || transfer.encoding == "identity", transfer.expectedLength >= 0,
           Int64(transfer.received) != transfer.expectedLength {
            return continuation.resume(throwing: RichImageError.truncatedImage)
        }
        continuation.resume(returning: transfer.mime)
    }
}
