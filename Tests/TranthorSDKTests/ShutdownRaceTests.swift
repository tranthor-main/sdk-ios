import Foundation
import Network
import XCTest
@testable import TranthorSDK

/// `shutdown()` invalidates the URL session. A delivery already under way must have ended by then (cancelled and
/// awaited), and a send that comes after must fail with an error: URLSession raises an uncatchable
/// NSGenericException ("Task created in a session that has been invalidated") when a task is created on an
/// invalidated session.
/// One-shot HTTP responder on the loopback interface.
private final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "loopback-server")
    private let lock = NSLock()
    private var received = ""
    private(set) var port: UInt16 = 0
    init(response: String) throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: queue)
            read(connection, response)
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port?.rawValue else { throw URLError(.cannotConnectToHost) }
        self.port = port
    }
    /// Reads until the whole request (headers and the `Content-Length` body) is in, then answers it.
    private func read(_ connection: NWConnection, _ response: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, error in
            let text = self.lock.withLock { () -> String in self.received += String(decoding: data ?? Data(), as: UTF8.self); return self.received }
            if let end = text.range(of: "\r\n\r\n") {
                let length = text.lowercased().components(separatedBy: "content-length: ").dropFirst().first
                    .flatMap { Int($0.prefix { $0.isNumber }) } ?? 0
                if text[end.upperBound...].utf8.count >= length {
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
            }
            if error == nil { self.read(connection, response) }
        }
    }
    var request: String { lock.withLock { received } }
    func stop() { listener.cancel() }
}

final class TransportShutdownTests: XCTestCase {
    private let batch: [[String: JSONValue]] = [["type": "track", "event": "Late", "messageId": "m-1"]]

    func testSendAfterShutdownFailsWithADeliveryFailureInsteadOfCrashing() async throws {
        let transport = try Transport(configuration: Configuration(writeKey: "fixture", host: "http://127.0.0.1:1"))
        transport.shutdown()
        do { try await transport.send(batch); XCTFail("A send after shutdown must fail") }
        catch let failure as DeliveryFailure {
            XCTAssertNil(failure.status)
            XCTAssertEqual(failure.message, "Transport shut down")
        }
    }
    func testASuccessfulResponseEndsTheSendAndCarriesTheBatchAndTheWriteKey() async throws {
        let server = try LoopbackServer(response: "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        defer { server.stop() }
        let transport = try Transport(configuration: Configuration(writeKey: "key-123", host: "http://127.0.0.1:\(server.port)"))
        defer { transport.shutdown() }
        try await transport.send(batch)
        XCTAssertTrue(server.request.hasPrefix("POST /api/public/apps/batch HTTP/1.1"))
        XCTAssertTrue(server.request.contains("\"event\":\"Late\""))
        XCTAssertTrue(server.request.lowercased().contains("authorization: key-123"))
    }
    func testAServerErrorKeepsItsStatusAndRetryAfter() async throws {
        let server = try LoopbackServer(response: "HTTP/1.1 503 Service Unavailable\r\nRetry-After: 7\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        defer { server.stop() }
        let transport = try Transport(configuration: Configuration(writeKey: "fixture", host: "http://127.0.0.1:\(server.port)"))
        defer { transport.shutdown() }
        do { try await transport.send(batch); XCTFail("A 503 must fail") }
        catch let failure as DeliveryFailure {
            XCTAssertEqual(failure.status, 503)
            XCTAssertEqual(failure.message, "HTTP delivery failure")
            XCTAssertEqual(failure.retryAfterMs, 7000)
        }
    }
    func testCancellingTheCallingTaskEndsTheRequest() async throws {
        let server = try LoopbackServer(response: "")   // Never answers: the connection is cancelled without a response.
        defer { server.stop() }
        let transport = try Transport(configuration: Configuration(writeKey: "fixture", host: "http://127.0.0.1:\(server.port)"))
        defer { transport.shutdown() }
        let batch = batch
        let task = Task { try await transport.send(batch) }
        task.cancel()
        do { try await task.value; XCTFail("A cancelled send must not succeed") }
        catch let failure as DeliveryFailure { XCTAssertEqual(failure.message, "Network delivery failure") }
    }
    func testShutdownTwiceIsHarmless() async throws {
        let transport = try Transport(configuration: Configuration(writeKey: "fixture", host: "http://127.0.0.1:1"))
        transport.shutdown(); transport.shutdown()
        do { try await transport.send(batch); XCTFail("A send after shutdown must fail") }
        catch let failure as DeliveryFailure { XCTAssertEqual(failure.message, "Transport shut down") }
    }
    func testSendsRacingWithShutdownAllEndInADeliveryFailure() async throws {
        let transport = try Transport(configuration: Configuration(writeKey: "fixture", host: "http://127.0.0.1:1"))
        let batch = batch
        let messages = await withTaskGroup(of: String.self, returning: [String].self) { group in
            for _ in 0..<40 {
                group.addTask {
                    do { try await transport.send(batch); return "sent" }
                    catch let failure as DeliveryFailure { return failure.message }
                    catch { return "other: \(error)" }
                }
            }
            group.addTask { transport.shutdown(); return "shutdown" }
            var all: [String] = []
            for await message in group { all.append(message) }
            return all
        }
        XCTAssertEqual(messages.filter { $0 == "shutdown" }.count, 1)
        // Each send either reached the unreachable host (a network failure) or came after shutdown.
        XCTAssertEqual(Set(messages).subtracting(["shutdown", "Network delivery failure", "Transport shut down"]), [])
    }
}

/// A transport whose `send` never answers until it is cancelled, like a request to a server that hangs, and which
/// records whether `shutdown()` was called while a send was still running.
private final class HangingTransport: SDKTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var running = 0
    private var sends = 0
    private var shutdownWhileSending = false
    private var sentAfterShutdown = false
    private var isShutdown = false
    let started: AsyncStream<Void>
    private let startedContinuation: AsyncStream<Void>.Continuation
    init() { (started, startedContinuation) = AsyncStream.makeStream() }

    var report: (sends: Int, shutdownWhileSending: Bool, sentAfterShutdown: Bool, isShutdown: Bool) {
        lock.withLock { (sends, shutdownWhileSending, sentAfterShutdown, isShutdown) }
    }
    func send(_ batch: [[String: JSONValue]]) async throws {
        lock.withLock { running += 1; sends += 1; if isShutdown { sentAfterShutdown = true } }
        startedContinuation.yield()
        defer { lock.withLock { running -= 1 } }
        try await Task.sleep(for: .seconds(120))
    }
    func shutdown() {
        lock.withLock { if running > 0 { shutdownWhileSending = true }; isShutdown = true }
    }
    func waitForSend() async { for await _ in started { return } }
}

@MainActor
final class ShutdownRaceTests: XCTestCase {
    override func setUp() { super.setUp(); executionTimeAllowance = 20 }
    private let token = "00ab" + String(repeating: "cd", count: 30)

    private func make(_ transport: HangingTransport, root: URL? = nil) async throws -> TranthorSDK {
        let root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("tranthor-shutdown-race-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let sdk = try await TranthorSDK(configuration: Configuration(writeKey: "fixture", host: "http://127.0.0.1:1", batchSize: 100,
            flushIntervalMs: 3_600_000, retries: 0, storageNamespace: "shutdown-race", storageDirectory: root),
            transport: transport, sleep: sleepMilliseconds)
        // A phone is registered only to an identified customer, so these races start with one signed in.
        if await sdk.userId == nil, await !sdk.isOptedOut { try await sdk.identify(userId: "customer-1") }
        return sdk
    }
    private func register(_ sdk: TranthorSDK) async throws {
        try await sdk.registerInstallation(token: token, appId: "com.example.race", environment: .development, permission: .granted)
    }
    /// The delivery under way has ended, and nothing was sent after the transport was shut down.
    private func assertShutDownAfterTheSendEnded(_ transport: HangingTransport, file: StaticString = #filePath, line: UInt = #line) {
        let report = transport.report
        XCTAssertEqual(report.sends, 1, file: file, line: line)
        XCTAssertFalse(report.shutdownWhileSending, "shutdown() must not invalidate the session while a delivery is in flight", file: file, line: line)
        XCTAssertFalse(report.sentAfterShutdown, file: file, line: line)
        XCTAssertTrue(report.isShutdown, file: file, line: line)
    }

    func testShutdownAfterOptOutEndsTheRemovalDeliveryBeforeInvalidatingTheSession() async throws {
        let transport = HangingTransport(), sdk = try await make(transport)
        try await register(sdk)
        try await sdk.optOut()
        await transport.waitForSend()
        await sdk.shutdown()
        assertShutDownAfterTheSendEnded(transport)
    }
    func testShutdownAfterTrackAndFlushEndsTheDeliveryBeforeInvalidatingTheSession() async throws {
        let transport = HangingTransport(), sdk = try await make(transport)
        try await sdk.track(event: "Opened")
        let flush = Task { try await sdk.flush() }
        await transport.waitForSend()
        await sdk.shutdown()
        _ = await flush.result
        assertShutDownAfterTheSendEnded(transport)
    }
    func testShutdownAfterIdentifyAndFlushEndsTheDeliveryBeforeInvalidatingTheSession() async throws {
        let transport = HangingTransport(), sdk = try await make(transport)
        try await sdk.identify(userId: "user-1")
        let flush = Task { try await sdk.flush() }
        await transport.waitForSend()
        await sdk.shutdown()
        _ = await flush.result
        assertShutDownAfterTheSendEnded(transport)
    }
    func testShutdownAfterRegisterInstallationAndFlushEndsTheDeliveryBeforeInvalidatingTheSession() async throws {
        let transport = HangingTransport(), sdk = try await make(transport)
        try await register(sdk)
        let flush = Task { try await sdk.flush() }
        await transport.waitForSend()
        await sdk.shutdown()
        _ = await flush.result
        assertShutDownAfterTheSendEnded(transport)
    }
    func testAnInterruptedRemovalIsStillStoredAfterShutdown() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tranthor-shutdown-race-" + UUID().uuidString)
        let transport = HangingTransport(), sdk = try await make(transport, root: root)
        try await register(sdk)
        try await sdk.optOut()
        await transport.waitForSend()
        await sdk.shutdown()
        var store = try JSONStore(directory: root, namespace: "shutdown-race")
        let state = try store.load()
        XCTAssertEqual(state.pendingRemovals.map { $0["event"]?.string }, ["Installation Removed"], "The cancelled delivery leaves the removal to retry")
        XCTAssertEqual(state.queued.count, 0)
    }
}
