import Foundation
import ImageIO
import UserNotifications
import XCTest
@testable import TranthorPushService

@MainActor
final class RichImageTests: XCTestCase {
    private func configuration(limit: Int = 1024) throws -> RichImageConfiguration {
        try RichImageConfiguration(allowedHosts: ["images.example.test"], maximumBytes: limit)
    }
    private func png() throws -> Data {
        try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l9sAAAAASUVORK5CYII="))
    }
    func testExactHTTPSAllowlistAndConfigurationBounds() throws {
        let config = try configuration()
        for raw in ["https://images.example.test/a.png", "https://IMAGES.EXAMPLE.TEST:443/a.png?signature=test"] {
            XCTAssertTrue(config.accepts(try XCTUnwrap(URL(string: raw))))
        }
        for raw in ["http://images.example.test/a.png", "https://images.example.test.evil.test/a.png",
                    "https://evil.test/a.png", "https://images.example.test:444/a.png",
                    "https://user:password@images.example.test/a.png", "file:///tmp/a.png", "https://images.example.test/a.png#fragment"] {
            XCTAssertFalse(config.accepts(try XCTUnwrap(URL(string: raw))))
        }
        XCTAssertThrowsError(try RichImageConfiguration(allowedHosts: ["https://example.test"]))
        XCTAssertThrowsError(try RichImageConfiguration(allowedHosts: [], maximumBytes: 0))
        XCTAssertThrowsError(try RichImageConfiguration(allowedHosts: [], maximumBytes: 10 * 1024 * 1024 + 1))
        XCTAssertThrowsError(try RichImageConfiguration(allowedHosts: [], timeoutSeconds: .nan))
        XCTAssertThrowsError(try RichImageConfiguration(allowedHosts: [], timeoutSeconds: 21))
        XCTAssertFalse(try RichImageConfiguration(allowedHosts: []).accepts(try XCTUnwrap(URL(string: "https://images.example.test/a.png"))))
    }
    func testImageValidationAndMIMEMismatch() throws {
        XCTAssertEqual(try RichImageDownloader.validate(png(), mime: "image/png"), "png")
        XCTAssertThrowsError(try RichImageDownloader.validate(Data("not an image".utf8), mime: "image/png"))
        XCTAssertThrowsError(try RichImageDownloader.validate(png(), mime: "image/jpeg"))
    }
    private func downloader() throws -> RichImageDownloader {
        let transport = URLSessionConfiguration.ephemeral
        transport.protocolClasses = [ImageProtocol.self]
        return RichImageDownloader(configuration: try configuration(), transport: transport)
    }
    func testStreamingValidDownloadAndAttachmentOwnership() async throws {
        ImageProtocol.set(status: 200, mime: "image/png", data: try png())
        let loader = try downloader()
        let file = try await loader.download(XCTUnwrap(URL(string: "https://images.example.test/image")))
        XCTAssertEqual(try Data(contentsOf: file), try png())
        let probe = CompletionProbe()
        let content = UNMutableNotificationContent(); content.title = "Original title"; content.body = "Original body"
        let completion = ImageCompletion(content: content, handler: { probe.record($0) })
        completion.finish(image: file)
        XCTAssertEqual(probe.count, 1); XCTAssertEqual(probe.title, "Original title")
        let attachment = try XCTUnwrap(probe.attachment)
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachment.path), "Removing the download must not erase Apple's attachment")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        RichImageDownloader.remove(file) // No system delivery is pending in this host test.
        await loader.shutdown()
    }
    func testHTTPAndMIMEErrorsAndLyingContentLengthAreRejected() async throws {
        for (status, mime, data, expected) in [(302, "image/png", try png(), RichImageError.invalidResponse),
                                             (401, "image/png", try png(), .invalidResponse),
                                             (200, "text/html", try png(), .invalidResponse),
                                             (200, "image/png", Data(repeating: 65, count: 2048), .oversizedImage),
                                             (200, "image/png", Data("garbage".utf8), .truncatedImage)] {
            ImageProtocol.set(status: status, mime: mime, data: data)
            let loader = try downloader()
            do { _ = try await loader.download(XCTUnwrap(URL(string: "https://images.example.test/image"))); XCTFail("Accepted invalid response") }
            catch let error as RichImageError { XCTAssertEqual(error, expected) }
            await loader.shutdown()
        }
    }
    func testExpiryCompletionIsSynchronousExactlyOnceAndCancelsLateTask() {
        let probe = CompletionProbe()
        let content = UNMutableNotificationContent(); content.title = "Text fallback"
        let completion = ImageCompletion(content: content, handler: { probe.record($0) })
        DispatchQueue.concurrentPerform(iterations: 100) { _ in completion.finish() }
        completion.installCancellation { probe.cancelled() }
        XCTAssertEqual(probe.count, 1); XCTAssertEqual(probe.title, "Text fallback"); XCTAssertEqual(probe.cancelCount, 1)
    }
    func testInvalidPayloadImmediatelyPassesThroughAndExpiryCannotCompleteTwice() {
        for version: Any in [true, "1", 2] {
            let service = TranthorNotificationServiceExtension(), probe = CompletionProbe()
            let content = UNMutableNotificationContent(); content.title = "Untouched"
            content.userInfo = ["tranthor": ["version": version, "imageUrl": "https://images.example.test/a.png"]]
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            service.didReceive(request) { probe.record($0) }
            XCTAssertEqual(probe.count, 1)
            service.serviceExtensionTimeWillExpire()
            XCTAssertEqual(probe.count, 1); XCTAssertEqual(probe.title, "Untouched")
        }
    }
    func testComposableHandlerRejectsUnknownVersionsWithoutTakingCompletion() throws {
        let service = TranthorRichPush(configuration: try configuration(), load: { _, _ in
            throw RichImageError.invalidResponse // Never perform real network I/O in this test.
        })
        for version: Any in [true, "1", 2] {
            let probe = CompletionProbe(), content = UNMutableNotificationContent()
            content.userInfo = ["tranthor": ["version": version, "deliveryId": "unknown-version",
                                            "imageUrl": "https://images.example.test/a.png"]]
            XCTAssertFalse(service.didReceive(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { probe.record($0) })
            service.serviceExtensionTimeWillExpire()
            XCTAssertEqual(probe.count, 0, "The host still owns a foreign payload's completion")
        }
    }
    func testCancellationAndDisallowedURLNeverDownload() async throws {
        let loader = try downloader()
        do { _ = try await loader.download(XCTUnwrap(URL(string: "http://images.example.test/image"))); XCTFail("Accepted HTTP") }
        catch let error as RichImageError { XCTAssertEqual(error, .disallowedURL) }
        let task = Task { try await loader.download(XCTUnwrap(URL(string: "https://images.example.test/image"))) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Accepted cancelled download") }
        catch is CancellationError { }
        await loader.shutdown()
    }
    func testTruncatedPNGJPEGAndGIFRejectEvenWhenImageIOFindsMetadata() throws {
        let png = try png()
        let gif = try XCTUnwrap(Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"))
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 0.5, blue: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let jpeg = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(jpeg, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        for (data, mime) in [(png, "image/png"), (jpeg as Data, "image/jpeg"), (gif, "image/gif")] {
            _ = try RichImageDownloader.validate(data, mime: mime)
            XCTAssertThrowsError(try RichImageDownloader.validate(Data(data.dropLast(1)), mime: mime)) {
                XCTAssertEqual($0 as? RichImageError, .truncatedImage)
            }
        }
    }
    /// A body exactly at the largest allowed cap is read in full and then judged as an image.
    func testBodyAtTheSizeCapIsReadInFull() async throws {
        let cap = 10 * 1024 * 1024
        ImageProtocol.set(status: 200, mime: "image/png", data: Data(repeating: 65, count: cap))
        let transport = URLSessionConfiguration.ephemeral
        transport.protocolClasses = [ImageProtocol.self]
        let loader = RichImageDownloader(configuration: try RichImageConfiguration(allowedHosts: ["images.example.test"], maximumBytes: cap),
                                         transport: transport)
        do { _ = try await loader.download(XCTUnwrap(URL(string: "https://images.example.test/image"))); XCTFail("Garbage is not an image") }
        catch let error as RichImageError { XCTAssertEqual(error, .truncatedImage) }
        await loader.shutdown()
    }
    func testIncorrectDeclaredLengthRejectsOtherwiseValidImage() async throws {
        let data = try png()
        ImageProtocol.set(status: 200, mime: "image/png", data: data, length: data.count + 1)
        let loader = try downloader()
        do { _ = try await loader.download(XCTUnwrap(URL(string: "https://images.example.test/image"))); XCTFail("Accepted incomplete body") }
        catch let error as RichImageError { XCTAssertEqual(error, .truncatedImage) }
        await loader.shutdown()
    }
    func testStreamingByteCapOverridesDishonestLength() async throws {
        ImageProtocol.set(status: 200, mime: "image/png", data: Data(repeating: 65, count: 2048), length: 1)
        let loader = try downloader()
        do { _ = try await loader.download(XCTUnwrap(URL(string: "https://images.example.test/image"))); XCTFail("Trusted an undersized header") }
        catch let error as RichImageError { XCTAssertEqual(error, .oversizedImage) }
        await loader.shutdown()
    }
    func testTaskRedirectDelegateRefusesTheNextRequest() throws {
        let url = try XCTUnwrap(URL(string: "https://images.example.test/image")), delegate = ImageTransfers()
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: nil))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        nonisolated(unsafe) var calls = 0
        delegate.urlSession(session, task: session.dataTask(with: url), willPerformHTTPRedirection: response,
                            newRequest: URLRequest(url: try XCTUnwrap(URL(string: "https://other.example.test/image")))) {
            calls += 1; XCTAssertNil($0)
        }
        XCTAssertEqual(calls, 1)
    }
    func testSharedDownloadAndCompletedFileQuotas() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("image-quota-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ImageFileStore(root: root)
        var active: [URL] = []
        for _ in 0..<4 { active.append(try await store.begin(maximumBytes: 1)) }
        do { _ = try await store.begin(maximumBytes: 1); XCTFail("Fifth concurrent download admitted") }
        catch let error as RichImageError { XCTAssertEqual(error, .busy) }
        for file in active { await store.abort(file) }
        for _ in 0..<32 {
            let part = try await store.begin(maximumBytes: 1)
            try Data([0]).write(to: part)
            _ = try await store.commit(part, suffix: "png")
        }
        do { _ = try await store.begin(maximumBytes: 1); XCTFail("33rd completed file admitted") }
        catch let error as RichImageError { XCTAssertEqual(error, .busy) }
    }
    func testConcurrentRequestsRetainBothImagesAndUnknownPayloadDoesNotComplete() async throws {
        let gate = ImageGate(), first = CompletionProbe(), second = CompletionProbe(), data = try png()
        let done = expectation(description: "Both images delivered"); done.expectedFulfillmentCount = 2
        let service = TranthorRichPush(configuration: try configuration(), load: { _, _ in
            await gate.enter()
            return try await RichImageDownloader.prepareAttachment(data, mime: "image/png")
        })
        for (id, probe) in [("one", first), ("two", second)] {
            let content = UNMutableNotificationContent(); content.title = id
            content.userInfo = ["tranthor": ["version": 1, "deliveryId": id, "imageUrl": "https://images.example.test/a.png"]]
            XCTAssertTrue(service.didReceive(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { probe.record($0); done.fulfill() })
        }
        await gate.waitForTwo()
        XCTAssertEqual(first.count, 0); XCTAssertEqual(second.count, 0)
        await gate.release()
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(first.count, 1); XCTAssertNotNil(first.attachment)
        XCTAssertEqual(second.count, 1); XCTAssertNotNil(second.attachment)
        service.serviceExtensionTimeWillExpire()
        XCTAssertEqual(first.count, 1); XCTAssertEqual(second.count, 1)
        for probe in [first, second] { if let file = probe.attachment { RichImageDownloader.remove(file) } }
        let unknown = CompletionProbe(), content = UNMutableNotificationContent()
        XCTAssertFalse(service.didReceive(UNNotificationRequest(identifier: "unknown", content: content, trigger: nil)) { unknown.record($0) })
        XCTAssertEqual(unknown.count, 0)
    }
    func testExpiryDrainsEveryPendingRequestSynchronously() async throws {
        let gate = ImageGate(), probes = [CompletionProbe(), CompletionProbe()]
        let service = TranthorRichPush(configuration: try configuration(), load: { _, _ in
            await gate.enter(); throw CancellationError()
        })
        for (index, probe) in probes.enumerated() {
            let content = UNMutableNotificationContent(); content.title = "Fallback"
            content.userInfo = ["tranthor": ["version": 1, "deliveryId": "pending-\(index)", "imageUrl": "https://images.example.test/a.png"]]
            XCTAssertTrue(service.didReceive(UNNotificationRequest(identifier: "pending-\(index)", content: content, trigger: nil)) { probe.record($0) })
        }
        await gate.waitForTwo()
        service.serviceExtensionTimeWillExpire()
        for probe in probes { XCTAssertEqual(probe.count, 1); XCTAssertEqual(probe.title, "Fallback") }
        service.serviceExtensionTimeWillExpire()
        await gate.release()
        for probe in probes { XCTAssertEqual(probe.count, 1) }
    }
}

private actor ImageGate {
    private var blocked: [CheckedContinuation<Void, Never>] = []
    private var ready: CheckedContinuation<Void, Never>?
    func enter() async {
        await withCheckedContinuation { continuation in
            blocked.append(continuation)
            if blocked.count == 2 { ready?.resume(); ready = nil }
        }
    }
    func waitForTwo() async {
        if blocked.count == 2 { return }
        await withCheckedContinuation { ready = $0 }
    }
    func release() { let waiting = blocked; blocked.removeAll(); for waiter in waiting { waiter.resume() } }
}

private final class CompletionProbe: Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var counts = (delivered: 0, cancelled: 0)
    nonisolated(unsafe) private var recordedTitle = ""
    nonisolated(unsafe) private var recordedAttachment: URL?
    func record(_ content: UNNotificationContent) {
        lock.lock(); defer { lock.unlock() }
        counts.delivered += 1; recordedTitle = content.title; recordedAttachment = content.attachments.first?.url
    }
    func cancelled() { lock.lock(); counts.cancelled += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return counts.delivered }
    var cancelCount: Int { lock.lock(); defer { lock.unlock() }; return counts.cancelled }
    var title: String { lock.lock(); defer { lock.unlock() }; return recordedTitle }
    var attachment: URL? { lock.lock(); defer { lock.unlock() }; return recordedAttachment }
}
private final class ImageProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var response = (status: 200, mime: "image/png", data: Data(), length: 0)
    static func set(status: Int, mime: String, data: Data, length: Int? = nil) {
        lock.lock(); response = (status, mime, data, length ?? data.count); lock.unlock()
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let response = Self.response; Self.lock.unlock()
        guard let url = request.url, let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": response.mime, "Content-Length": String(response.length)]) else { return }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
