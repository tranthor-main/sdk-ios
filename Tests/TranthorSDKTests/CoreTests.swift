import Foundation
import XCTest
@testable import TranthorSDK

@MainActor
final class CoreTests: XCTestCase {
    func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("tranthor-unit-" + UUID().uuidString) }
    func testCorruptStoreIsDiscardedAndReplaced() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        var store = try JSONStore(directory: root, namespace: "../../escape")
        try Data("{broken".utf8).write(to: store.url)
        let fresh = try store.load()
        XCTAssertNotNil(UUID(uuidString: fresh.anonymousId))
        XCTAssertTrue(fresh.queued.isEmpty)
        try store.save(fresh)
        XCTAssertEqual(try store.load().anonymousId, fresh.anonymousId)
        XCTAssertTrue(store.url.path.hasPrefix(root.path + "/"))
        try Data("{\"anonymousId\":\"invalid\"}".utf8).write(to: store.url)
        XCTAssertNotNil(UUID(uuidString: try store.load().anonymousId))
    }
    func testRetryAfterAndDelayEdges() {
        for value in [nil, "", " 1", "1 ", "+1", "-1", "1.0", "1e2", "0x10", "١", "１", "1\n", "Wed, 21 Oct 2015 07:28:00 GMT"] as [String?] {
            XCTAssertEqual(retryAfter(value), 0, "\(value ?? "nil")")
        }
        XCTAssertEqual(retryAfter("0"), 0)
        XCTAssertEqual(retryAfter("0002"), 2000)
        XCTAssertEqual(retryAfter("30"), 30000)
        XCTAssertEqual(retryAfter(String(repeating: "9", count: 500)), 30000)
        XCTAssertEqual(retryDelay(base: 500, attempt: 0, requested: 0), 500)
        XCTAssertEqual(retryDelay(base: 500, attempt: 4, requested: 0), 8000)
        XCTAssertEqual(retryDelay(base: 600, attempt: 1, requested: 1000), 1200)
        XCTAssertEqual(retryDelay(base: 500, attempt: 2000, requested: 0), 30000)
        XCTAssertEqual(retryDelay(base: 0, attempt: 2000, requested: 1000), 1000)
    }
    func testConfigurationFallbacks() {
        for value in [nil, 0, -1, 1.1, .nan, .infinity, Double(Int.max)] as [Double?] {
            let c = Configuration(writeKey: "fixture", batchSize: value, flushIntervalMs: value)
            XCTAssertEqual(c.batchSize, 5); XCTAssertEqual(c.flushIntervalMs, 500)
        }
        let defaults = Configuration(writeKey: "fixture", retries: .nan, baseDelay: .infinity)
        XCTAssertEqual(defaults.retries, 5); XCTAssertEqual(defaults.baseDelay, 500)
        XCTAssertEqual(defaults.host, "https://api.tranthor.com")
        XCTAssertTrue(defaults.automaticContext)
        let c = Configuration(writeKey: "fixture", batchSize: 2, flushIntervalMs: 20, retries: 2.8, baseDelay: -10)
        XCTAssertEqual(c.batchSize, 2); XCTAssertEqual(c.flushIntervalMs, 20)
        XCTAssertEqual(c.retries, 2); XCTAssertEqual(c.baseDelay, 0)
        XCTAssertEqual(Configuration(writeKey: "fixture", retries: -2).retries, 0)
        XCTAssertEqual(Configuration(writeKey: "fixture", baseDelay: 0.5).baseDelay, 0.5)
    }
    func testIdentityContextAndStablePersistence() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = Configuration(writeKey: "fixture", host: "http://127.0.0.1:1", batchSize: 100, flushIntervalMs: 60000,
                                   storageNamespace: "identity", storageDirectory: root)
        let sdk = try await TranthorSDK.configure(config)
        let anon = await sdk.anonymousId
        try await sdk.track(event: "anonymous")
        try await sdk.identify(userId: "known", traits: ["a": 1])
        try await sdk.track(event: "known")
        try await sdk.page(anonymousId: "explicit", context: ["library": ["name": "caller"], "locale": "custom"])
        try await sdk.screen(userId: "override", messageId: "id", timestamp: "literal")
        try await sdk.reset()
        let resetAnon = await sdk.anonymousId
        XCTAssertNotEqual(anon, resetAnon)
        try await sdk.track(event: "reset")
        await sdk.shutdown()
        var store = try JSONStore(directory: root, namespace: "identity")
        let state = try store.load()
        let q = state.queued
        XCTAssertEqual(q.count, 6)
        XCTAssertEqual(q[0]["anonymousId"], .string(anon)); XCTAssertNil(q[0]["userId"])
        // The login identify links the stored anonymous ID; later events carry only the user ID.
        XCTAssertEqual(q[1]["userId"], "known"); XCTAssertEqual(q[1]["anonymousId"], .string(anon))
        XCTAssertEqual(q[2]["userId"], "known"); XCTAssertNil(q[2]["anonymousId"])
        XCTAssertEqual(q[3]["anonymousId"], "explicit"); XCTAssertNil(q[3]["userId"])
        XCTAssertEqual(q[4]["userId"], "override"); XCTAssertNil(q[4]["anonymousId"])
        XCTAssertEqual(q[4]["messageId"], "id"); XCTAssertEqual(q[4]["timestamp"], "literal")
        XCTAssertEqual(q[5]["anonymousId"], .string(resetAnon))
        XCTAssertEqual(q[3]["context"]?["library"], ["name": "caller"])
        XCTAssertEqual(q[3]["context"]?["locale"], "custom")
        for key in ["library", "os", "device", "app", "locale", "timezone"] { XCTAssertNotNil(q[0]["context"]?[key]) }
        let new = try await TranthorSDK.configure(config)
        let restoredAnonymous = await new.anonymousId
        let restoredUser = await new.userId
        XCTAssertEqual(restoredAnonymous, resetAnon); XCTAssertNil(restoredUser)
        await new.shutdown()
        XCTAssertEqual(try store.load().queued, q)
    }
    func testIdentifyPersistsUserAndConsent() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let c = Configuration(writeKey: "fixture", host: "http://127.0.0.1:1", batchSize: 100, flushIntervalMs: 60000, storageDirectory: root)
        let first = try await TranthorSDK.configure(c)
        try await first.identify(userId: "saved")
        await first.shutdown()
        let second = try await TranthorSDK.configure(c)
        let user = await second.userId
        XCTAssertEqual(user, "saved")
        try await second.optOut()
        try await second.identify(userId: "ignored")
        await second.shutdown()
        let third = try await TranthorSDK.configure(c)
        let optedOut = await third.isOptedOut
        let savedUser = await third.userId
        XCTAssertTrue(optedOut); XCTAssertEqual(savedUser, "saved")
        try await third.flush()
        try await third.optIn()
        await third.shutdown()
    }
    func testTimestampFormat() {
        XCTAssertEqual(timestamp(Date(timeIntervalSince1970: 1577934245.006)), "2020-01-02T03:04:05.006Z")
        XCTAssertEqual(timestamp(Date(timeIntervalSince1970: 0)), "1970-01-01T00:00:00.000Z")
    }
    func testConcurrentTracksAreDurableAndUnique() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let sdk = try await TranthorSDK.configure(Configuration(writeKey: "fixture", host: "http://127.0.0.1:1", batchSize: 1000,
            flushIntervalMs: 60000, automaticContext: false, storageDirectory: root))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<200 { group.addTask { try await sdk.track(event: "event-\(index)") } }
            try await group.waitForAll()
        }
        await sdk.shutdown()
        let events = try loadState(directory: root, namespace: "default").queued
        XCTAssertEqual(events.count, 200)
        XCTAssertEqual(Set(events.compactMap { $0["messageId"]?.string }).count, 200)
        XCTAssertEqual(Set(events.compactMap { $0["event"]?.string }).count, 200)
        XCTAssertTrue(events.allSatisfy { $0["anonymousId"] != nil && $0["userId"] == nil })
    }
    func testNonFinitePayloadRejectedBeforeQueueing() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let errors = ErrorLogForUnitTests()
        let sdk = try await TranthorSDK.configure(Configuration(writeKey: "fixture", host: "http://127.0.0.1:1", flushIntervalMs: 60000, storageDirectory: root, onError: { errors.append($0) }))
        do { try await sdk.track(event: "bad", properties: ["value": .number(.nan)]); XCTFail("Expected serialization failure") } catch {}
        do { try await sdk.identify(userId: "invalid", traits: ["value": .number(.infinity)]); XCTFail("Expected serialization failure") } catch {}
        let user = await sdk.userId
        XCTAssertNil(user)
        let entries = await errors.snapshot()
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries.allSatisfy { $0.attempts == 0 && $0.error.status == nil && $0.events.count == 1 })
        await sdk.shutdown()
        XCTAssertTrue(try loadState(directory: root, namespace: "default").queued.isEmpty)
    }
}

private struct ErrorLogForUnitTests: Sendable {
    enum Entry: Sendable { case failure(BatchFailure), snapshot(CheckedContinuation<[BatchFailure], Never>) }
    let continuation: AsyncStream<Entry>.Continuation
    init() {
        let (stream, continuation) = AsyncStream<Entry>.makeStream()
        self.continuation = continuation
        Task {
            var entries: [BatchFailure] = []
            for await entry in stream {
                switch entry {
                case .failure(let value): entries.append(value)
                case .snapshot(let continuation): continuation.resume(returning: entries)
                }
            }
        }
    }
    func append(_ value: BatchFailure) { continuation.yield(.failure(value)) }
    func snapshot() async -> [BatchFailure] {
        await withCheckedContinuation { continuation.yield(.snapshot($0)) }
    }
}

func loadState(directory: URL, namespace: String) throws -> StoredState {
    var store = try JSONStore(directory: directory, namespace: namespace)
    return try store.load()
}
