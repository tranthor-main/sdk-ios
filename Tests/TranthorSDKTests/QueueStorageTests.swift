import Foundation
import XCTest
@testable import TranthorSDK

/// The queue is stored one small file per event, so the cost of an operation does not grow with the queue.
final class WriteLog: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = 0
    func add(_ count: Int) { lock.lock(); bytes += count; lock.unlock() }
    func take() -> Int { lock.lock(); defer { lock.unlock() }; let value = bytes; bytes = 0; return value }
}

@MainActor
final class QueueStorageTests: XCTestCase {
    override func setUp() { super.setUp(); executionTimeAllowance = 20 }
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("queue-storage-" + UUID().uuidString) }

    func testBytesWrittenByOneTrackDoNotGrowWithTheQueue() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let log = WriteLog()
        let sdk = try await TranthorSDK(configuration: Configuration(writeKey: "fixture", batchSize: 100_000, flushIntervalMs: 3_600_000,
            automaticContext: false, storageDirectory: root), transport: ManualTransport(), sleep: { try await ManualSleeper().sleep($0) },
            storeWrite: { data, url in log.add(data.count); try JSONStore.write(data, to: url) })
        _ = log.take()
        try await sdk.track(event: "Opened", properties: ["source": "app"])
        let empty = log.take()
        for index in 0..<499 { try await sdk.track(event: "Opened", properties: ["source": "app", "n": .number(Double(index))]) }
        _ = log.take()
        try await sdk.track(event: "Opened", properties: ["source": "app"])
        let full = log.take()
        XCTAssertLessThan(empty, 2048, "one track with an empty queue")
        XCTAssertLessThan(full, 2048, "one track with 500 events queued")
        await sdk.shutdown()
    }

    private func make(_ root: URL, _ transport: ManualTransport, _ sleeper: ManualSleeper, batchSize: Double = 100,
                      maxQueueSize: Int = 10_000, onError: (@Sendable (BatchFailure) -> Void)? = nil,
                      storeWrite: @escaping @Sendable (Data, URL) throws -> Void = { try JSONStore.write($0, to: $1) }) async throws -> TranthorSDK {
        try await TranthorSDK(configuration: Configuration(writeKey: "fixture", batchSize: batchSize, flushIntervalMs: 3_600_000,
            automaticContext: false, storageDirectory: root, maxQueueSize: maxQueueSize, onError: onError),
            transport: transport, sleep: { try await sleeper.sleep($0) }, storeWrite: storeWrite)
    }
    private func names(_ batch: [[String: JSONValue]]) -> [String] { batch.compactMap { $0["event"]?.string } }

    func testOrderAndStampsSurviveARestartIncludingABatchThatWasInFlight() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = ManualTransport(), sleeper = ManualSleeper()
        let sdk = try await make(root, transport, sleeper, batchSize: 2)
        for event in ["a", "b", "c", "d", "e"] { try await sdk.track(event: event) }
        let flush = Task { try? await sdk.flush() }
        try await transport.wait(1)
        let before = await transport.snapshot()
        let stopping = Task { await sdk.shutdown() }
        while !(await sdk.isStopped) { await Task.yield() }
        await transport.complete(0, error: DeliveryFailure(status: 503, message: "interrupted"))
        await stopping.value; await flush.value; await sleeper.releaseAll()
        let nextTransport = ManualTransport(), nextSleeper = ManualSleeper()
        await nextTransport.autoSucceedFutureRequests()
        let next = try await make(root, nextTransport, nextSleeper, batchSize: 2)
        try await next.flush()
        let sent = await nextTransport.snapshot()
        XCTAssertEqual(sent.map(names), [["a", "b"], ["c", "d"], ["e"]])
        XCTAssertEqual(sent[0], before[0], "The batch that was in flight keeps its message ids and timestamps")
        await next.shutdown(); await nextSleeper.releaseAll()
    }

    private func queueFolder(_ root: URL) throws -> URL {
        try JSONStore(directory: root, namespace: "default").url.deletingLastPathComponent().appendingPathComponent("queue", isDirectory: true)
    }
    private func queueFiles(_ root: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: queueFolder(root).path).sorted()
    }

    func testACorruptEventFileIsSetAsideAndTheOthersAreStillDeliveredInOrder() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try await make(root, ManualTransport(), ManualSleeper())
        for event in ["a", "b", "c"] { try await first.track(event: event) }
        await first.shutdown()
        let files = try queueFiles(root)
        XCTAssertEqual(files.count, 3)
        let damaged = Data("{broken".utf8)
        try damaged.write(to: queueFolder(root).appendingPathComponent(files[1]))
        let transport = ManualTransport(), sleeper = ManualSleeper()
        await transport.autoSucceedFutureRequests()
        let next = try await make(root, transport, sleeper)
        try await next.flush()
        let sent = await transport.snapshot()
        XCTAssertEqual(sent.map(names), [["a", "c"]])
        await next.shutdown(); await sleeper.releaseAll()
        let remaining = try queueFiles(root)
        XCTAssertFalse(remaining.contains(files[1]), "The damaged file no longer sits in the queue under its event name")
        XCTAssertEqual(remaining.count, 1, "The delivered events' files are gone; the damaged one is kept aside")
        XCTAssertEqual(try Data(contentsOf: queueFolder(root).appendingPathComponent(remaining[0])), damaged)
    }
    #if os(macOS)
    func testAnUnreadableEventFileStopsConfigureInsteadOfBeingSetAside() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try await make(root, ManualTransport(), ManualSleeper())
        for event in ["a", "b"] { try await first.track(event: event) }
        await first.shutdown()
        let files = try queueFiles(root)
        let locked = try queueFolder(root).appendingPathComponent(files[0])
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: locked.path) }
        do { let sdk = try await make(root, ManualTransport(), ManualSleeper()); await sdk.shutdown(); XCTFail("Unreadable event file must stop configure") }
        catch { guard case TranthorError.storeTemporarilyUnavailable = error else { return XCTFail("Got \(error)") } }
        XCTAssertEqual(try queueFiles(root), files, "Nothing is renamed or deleted when a file cannot be read")
    }
    #endif

    func testOptOutDeletesTheQueueFiles() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let sdk = try await make(root, ManualTransport(), ManualSleeper())
        for event in ["a", "b"] { try await sdk.track(event: event) }
        let before = try queueFiles(root)
        XCTAssertEqual(before.count, 2)
        try await sdk.optOut()
        XCTAssertEqual(try queueFiles(root), [])
        await sdk.shutdown()
    }

    func testARestartAfterAnInterruptedOptOutSendsNothingAndFinishesTheDeletion() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try await make(root, ManualTransport(), ManualSleeper())
        for event in ["a", "b"] { try await first.track(event: event) }
        await first.shutdown()
        XCTAssertEqual(try queueFiles(root).count, 2)
        // The opt-out wrote consent and the process died before it deleted the files.
        try JSONStore(directory: root, namespace: "default").saveConsent(true)
        let transport = ManualTransport(), sleeper = ManualSleeper()
        await transport.autoSucceedFutureRequests()
        let next = try await make(root, transport, sleeper)
        try await next.flush()
        let sent = await transport.snapshot()
        XCTAssertEqual(sent.count, 0)
        XCTAssertEqual(try queueFiles(root), [])
        await next.shutdown(); await sleeper.releaseAll()
    }

    func testOverflowDeletesTheOldestFilesAndReportsThemWithZeroAttempts() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let (stream, continuation) = AsyncStream<BatchFailure>.makeStream()
        let sdk = try await make(root, ManualTransport(), ManualSleeper(), maxQueueSize: 3, onError: { continuation.yield($0) })
        for index in 0..<8 { try await sdk.track(event: "e\(index)") }
        XCTAssertEqual(try queueFiles(root), ["00000000000000000006.json", "00000000000000000007.json", "00000000000000000008.json"])
        await sdk.shutdown(); continuation.finish()
        var failures: [BatchFailure] = []; for await failure in stream { failures.append(failure) }
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.attempts, 0)
        XCTAssertEqual(failures.first?.events.compactMap { $0["event"]?.string }, ["e0", "e1", "e2", "e3", "e4"])
        var store = try JSONStore(directory: root, namespace: "default")
        XCTAssertEqual(try store.load().queued.compactMap { $0["event"]?.string }, ["e5", "e6", "e7"])
    }

    private func seedReleaseZeroOneZero(_ root: URL) throws -> JSONStore {
        let store = try JSONStore(directory: root, namespace: "default")
        try Data(releaseZeroOneZeroState().utf8).write(to: store.url)
        try Data("{\"version\":1,\"optedOut\":false}".utf8).write(to: store.consentURL)
        return store
    }

    func testAVersionOneStateIsMovedToQueueFilesActiveFirstWithTheSameStamps() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try seedReleaseZeroOneZero(root)
        let transport = ManualTransport(), sleeper = ManualSleeper()
        await transport.autoSucceedFutureRequests()
        let sdk = try await make(root, transport, sleeper, batchSize: 10)
        XCTAssertEqual(try queueFiles(root).count, 4)
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [String: Any])
        XCTAssertEqual(state["version"] as? Int, 2)
        XCTAssertNil(state["queued"]); XCTAssertNil(state["active"])
        XCTAssertEqual(state["userId"] as? String, "u1")
        XCTAssertEqual(state["anonymousId"] as? String, "6F1C2D3E-4A5B-4C6D-8E7F-0123456789AB")
        XCTAssertEqual((state["installation"] as? [String: Any])?["token"] as? String, "ab12")
        try await sdk.flush()
        let requests = await transport.snapshot()
        let sent = try XCTUnwrap(requests.first)
        XCTAssertEqual(names(sent), ["active1", "active2", "queued1", "queued2"])
        XCTAssertEqual(sent.compactMap { $0["messageId"]?.string }, ["m1", "m2", "m3", "m4"])
        XCTAssertEqual(sent.compactMap { $0["timestamp"]?.string }, ["2026-11-01T00:00:01.000Z", "2026-11-01T00:00:02.000Z",
                                                                      "2026-11-01T00:00:03.000Z", "2026-11-01T00:00:04.000Z"])
        await sdk.shutdown(); await sleeper.releaseAll()
    }

    func testMigrationInterruptedBeforeTheStateRewriteNeitherDuplicatesNorLosesEvents() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try seedReleaseZeroOneZero(root)
        do {
            let sdk = try await make(root, ManualTransport(), ManualSleeper(), batchSize: 10, storeWrite: { data, url in
                if url.lastPathComponent == "state.json" { throw POSIXError(.EIO) }
                try JSONStore.write(data, to: url)
            })
            await sdk.shutdown(); XCTFail("The state rewrite was made to fail")
        } catch {}
        XCTAssertEqual(try queueFiles(root).count, 4, "The files were written before the state rewrite failed")
        XCTAssertEqual(try Data(contentsOf: store.url), Data(releaseZeroOneZeroState().utf8), "The old state is untouched")
        let transport = ManualTransport(), sleeper = ManualSleeper()
        await transport.autoSucceedFutureRequests()
        let sdk = try await make(root, transport, sleeper, batchSize: 10)
        XCTAssertEqual(try queueFiles(root).count, 4)
        try await sdk.flush()
        let sent = await transport.snapshot()
        XCTAssertEqual(sent.map(names), [["active1", "active2", "queued1", "queued2"]])
        await sdk.shutdown(); await sleeper.releaseAll()
    }

    func testAFailedStateWriteLeavesNoEventFileBehindForAnIdentify() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let failing = WriteLog()
        let sdk = try await make(root, ManualTransport(), ManualSleeper(), storeWrite: { data, url in
            if url.lastPathComponent == "state.json" && failing.take() > 0 { throw POSIXError(.ENOSPC) }
            try JSONStore.write(data, to: url)
        })
        failing.add(1) // Arms one failure of the next state write; configure's own writes are already done.
        do { try await sdk.identify(userId: "u1"); XCTFail("The state write was made to fail") } catch {}
        let user = await sdk.userId
        XCTAssertNil(user, "The identity change is rolled back")
        XCTAssertEqual(try queueFiles(root), [], "The identify event file is removed again")
        await sdk.shutdown()
    }
}
