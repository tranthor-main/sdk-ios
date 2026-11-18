import Foundation
import XCTest
@testable import TranthorSDK

/// Sleeps and responses are released explicitly; no wall-clock delays drive these races.
private enum TestTimeout: Error { case waitingForSleeper(Double), waitingForCancellation(Int), waitingForRequests(Int), waitingForActorCheckpoint }
private actor ManualSleeper {
    struct Pending { let delay: Double; let continuation: CheckedContinuation<Void, any Error> }
    var pending: [Int: Pending] = [:]
    var next = 0
    var cancelled: Set<Int> = []
    var sleepWaiters: [(Double, CheckedContinuation<Int, Never>)] = []
    var cancelWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    func sleep(_ delay: Double) async throws {
        let id = next; next += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = Pending(delay: delay, continuation: continuation)
                if let index = sleepWaiters.firstIndex(where: { $0.0 == delay }) {
                    sleepWaiters.remove(at: index).1.resume(returning: id)
                }
            }
        } onCancel: { Task { await self.markCancelled(id) } }
    }
    func wait(_ delay: Double) async throws -> Int {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if let id = pending.first(where: { $0.value.delay == delay && !cancelled.contains($0.key) })?.key { return id }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw TestTimeout.waitingForSleeper(delay)
    }
    func waitCancellation(_ id: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !cancelled.contains(id) {
            guard ContinuousClock.now < deadline else { throw TestTimeout.waitingForCancellation(id) }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    func markCancelled(_ id: Int) {
        cancelled.insert(id)
        for waiter in cancelWaiters.removeValue(forKey: id) ?? [] { waiter.resume() }
    }
    func release(_ id: Int, ignoringCancellation: Bool = false) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        if cancelled.contains(id) && !ignoringCancellation { entry.continuation.resume(throwing: CancellationError()) }
        else { entry.continuation.resume() }
    }
    func releaseAll() { for id in Array(pending.keys) { release(id) } }
}
private actor ManualTransport: SDKTransport {
    var requests: [[[String: JSONValue]]] = []
    var automaticSuccess = false
    func autoSucceedFutureRequests() { automaticSuccess = true }
    var responses: [Int: CheckedContinuation<Void, any Error>] = [:]
    var observers: [(Int, CheckedContinuation<Void, Never>)] = []
    nonisolated func shutdown() {}
    func send(_ batch: [[String: JSONValue]]) async throws {
        let index = requests.count
        requests.append(batch)
        if automaticSuccess { return }
        try await withCheckedThrowingContinuation { continuation in
            responses[index] = continuation
            let ready = observers.filter { requests.count >= $0.0 }
            observers.removeAll { requests.count >= $0.0 }
            for observer in ready { observer.1.resume() }
        }
    }
    func wait(_ count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while requests.count < count {
            guard ContinuousClock.now < deadline else { throw TestTimeout.waitingForRequests(count) }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    func complete(_ index: Int, error: DeliveryFailure? = nil) {
        guard let continuation = responses.removeValue(forKey: index) else { return }
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
    func snapshot() -> [[[String: JSONValue]]] { requests }
}

/// The queue delivers in order and keeps its invariants across retries, capacity limits, consent and shutdown.
@MainActor
final class QueueTests: XCTestCase {
    override func setUp() { super.setUp(); executionTimeAllowance = 15 }
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("queue-" + UUID().uuidString) }
    private func sdk(_ root: URL, _ transport: ManualTransport, _ sleeper: ManualSleeper) async throws -> TranthorSDK {
        try await TranthorSDK(configuration: Configuration(writeKey: "fixture", batchSize: 100, flushIntervalMs: 60000,
            automaticContext: false, storageDirectory: root), transport: transport, sleep: { try await sleeper.sleep($0) })
    }
    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw TestTimeout.waitingForActorCheckpoint }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    private func cancellationRace(flushOrdering: Bool) async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = ManualTransport(), sleeper = ManualSleeper()
        let sdk = try await sdk(root, transport, sleeper)
        try await sdk.track(event: "a")
        let flush = Task { try await sdk.flush() }
        try await transport.wait(1)
        await transport.complete(0, error: DeliveryFailure(status: 503, message: "retry"))
        let retry = try await sleeper.wait(500)
        let expiry = Task { await sdk.pauseForBackgroundExpiry() }
        try await sleeper.waitCancellation(retry)
        let secondFlush: Task<Void, any Error>?
        if flushOrdering {
            secondFlush = Task { try await sdk.flush() }
            // A serial actor checkpoint after the new waiter attaches, without wall-clock sleep.
            try await waitUntil { await sdk.flushWaiterCount >= 2 }
        } else { secondFlush = nil; await sdk.resumeOnForeground() }
        await sleeper.release(retry)
        await expiry.value
        do { try await flush.value; XCTFail("Cancelled cycle must reject its waiter") } catch {}
        if let secondFlush { do { try await secondFlush.value; XCTFail("Waiter attached to cancelled cycle must reject") } catch {} }
        let saved = try loadState(directory: root, namespace: "default")
        XCTAssertEqual(saved.queued.compactMap { $0["event"]?.string }, ["a"])
        XCTAssertTrue(saved.active.isEmpty)
        try await sdk.track(event: "b")
        let recovery = Task { try await sdk.flush() }
        try await transport.wait(2)
        let requests = await transport.snapshot()
        XCTAssertEqual(requests[1].compactMap { $0["event"]?.string }, ["a", "b"])
        XCTAssertEqual(requests[0][0]["messageId"], requests[1][0]["messageId"])
        XCTAssertEqual(requests[0][0]["timestamp"], requests[1][0]["timestamp"])
        await transport.complete(1)
        try await recovery.value
        await sdk.shutdown(); await sleeper.releaseAll()
    }
    func testExpiryForegroundOrderingRestoresActiveAndRejectsCancelledFlush() async throws { try await cancellationRace(flushOrdering: false) }
    func testExpiryFlushOrderingRestoresActiveAndRejectsBothCancelledWaiters() async throws { try await cancellationRace(flushOrdering: true) }

    func testAcknowledgementWinsCancellationAfterSuccessfulResponse() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = ManualTransport(), sleeper = ManualSleeper()
        let sdk = try await sdk(root, transport, sleeper)
        try await sdk.track(event: "acknowledged")
        let flush = Task { try await sdk.flush() }; try await transport.wait(1)
        let expiry = Task { await sdk.pauseForBackgroundExpiry() }
        // Actor flag guarantees cancellation was issued before the transport's successful return.
        try await waitUntil { await sdk.deliveryPaused }
        await transport.complete(0)
        await expiry.value
        do { try await flush.value; XCTFail("Cancelled cycle waiter must reject") } catch {}
        let saved = try loadState(directory: root, namespace: "default")
        XCTAssertTrue(saved.queued.isEmpty); XCTAssertTrue(saved.active.isEmpty)
        await sdk.shutdown(); await sleeper.releaseAll()
    }
    func testBackgroundCutsRetryBackoffAndPersistsAfterOneImmediateAttempt() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = ManualTransport(), sleeper = ManualSleeper()
        let sdk = try await sdk(root, transport, sleeper)
        try await sdk.track(event: "background")
        let flush = Task { try await sdk.flush() }; try await transport.wait(1)
        await transport.complete(0, error: DeliveryFailure(status: 503, message: "retry"))
        let retry = try await sleeper.wait(500)
        let background = Task { await sdk.flushForBackground(UUID()) }
        try await sleeper.waitCancellation(retry)
        await sleeper.release(retry)
        try await transport.wait(2)
        await transport.complete(1, error: DeliveryFailure(status: 503, message: "retry"))
        await background.value
        do { try await flush.value; XCTFail("Background retry pause must reject flush") } catch {}
        let requests = await transport.snapshot()
        XCTAssertEqual(requests.count, 2)
        let saved = try loadState(directory: root, namespace: "default")
        XCTAssertEqual(saved.queued.count, 1); XCTAssertTrue(saved.active.isEmpty)
        await sdk.shutdown(); await sleeper.releaseAll()
    }
    func testForegroundDuringBackgroundSleeperCancellationDoesNotAdvanceUnacknowledgedBatch() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = ManualTransport(), sleeper = ManualSleeper()
        let sdk = try await sdk(root, transport, sleeper)
        try await sdk.track(event: "a")
        let flush = Task { try await sdk.flush() }; try await transport.wait(1)
        await transport.complete(0, error: DeliveryFailure(status: 503, message: "retry"))
        let retry = try await sleeper.wait(500)
        try await sdk.track(event: "b")
        await transport.autoSucceedFutureRequests()
        let background = Task { await sdk.flushForBackground(UUID()) }
        try await sleeper.waitCancellation(retry)
        await sdk.resumeOnForeground()
        await sleeper.release(retry)
        await background.value
        do { try await flush.value; XCTFail("Unacknowledged cancelled sleeper must reject flush") } catch {}
        let requests = await transport.snapshot()
        XCTAssertEqual(requests.count, 1, "An unacknowledged batch cannot advance to the later batch")
        let saved = try loadState(directory: root, namespace: "default")
        XCTAssertEqual(saved.queued.compactMap { $0["event"]?.string }, ["a", "b"])
        XCTAssertTrue(saved.active.isEmpty)
        await sdk.shutdown(); await sleeper.releaseAll()
    }
    func testStaleTimerCannotFlushLaterQueue() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = ManualTransport(), sleeper = ManualSleeper()
        let sdk = try await sdk(root, transport, sleeper)
        try await sdk.track(event: "first")
        let stale = await sdk.pendingTimer
        let firstTimer = try await sleeper.wait(60000)
        let flush = Task { try await sdk.flush() }; try await transport.wait(1)
        try await sleeper.waitCancellation(firstTimer)
        await transport.complete(0); try await flush.value
        try await sdk.track(event: "later")
        await sleeper.release(firstTimer, ignoringCancellation: true)
        await stale?.value
        let active = await sdk.deliveryCycleActive
        XCTAssertFalse(active, "A stale timer must not create a delivery cycle")
        let requests = await transport.snapshot()
        XCTAssertEqual(requests.count, 1, "A cancelled timer generation cannot flush a later queue")
        let saved = try loadState(directory: root, namespace: "default")
        XCTAssertEqual(saved.queued.compactMap { $0["event"]?.string }, ["later"])
        let secondTimer = try await sleeper.wait(60000)
        await sleeper.release(secondTimer)
        try await transport.wait(2); await transport.complete(1)
        await sdk.shutdown(); await sleeper.releaseAll()
    }
    func testDuplicateNamespaceRejectedAndReleasedAtShutdown() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let c = Configuration(writeKey: "fixture", batchSize: 100, flushIntervalMs: 60000, storageDirectory: root)
        let first = try await TranthorSDK.configure(c)
        try await first.track(event: "a")
        do { _ = try await TranthorSDK.configure(c); XCTFail("Duplicate live namespace must throw") }
        catch { XCTAssertEqual(error as? TranthorError, .namespaceInUse) }
        await first.shutdown()
        let second = try await TranthorSDK.configure(c)
        try await second.track(event: "b"); await second.shutdown()
        XCTAssertEqual(try loadState(directory: root, namespace: "default").queued.compactMap { $0["event"]?.string }, ["a", "b"])
    }
    func testAllStoppedMutatorsCannotOverwriteNewOwnerStore() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let c = Configuration(writeKey: "fixture", batchSize: 100, flushIntervalMs: 60000, storageDirectory: root)
        let old = try await TranthorSDK.configure(c); await old.shutdown()
        let new = try await TranthorSDK.configure(c); try await new.track(event: "new")
        let store = try JSONStore(directory: root, namespace: "default")
        let before = try Data(contentsOf: store.url), consent = try Data(contentsOf: store.consentURL)
        try await old.track(event: "stale"); try await old.identify(userId: "stale")
        try await old.page(name: "stale"); try await old.screen(name: "stale")
        try await old.reset(); try await old.optOut(); try await old.optIn()
        do { try await old.flush(); XCTFail("Stopped flush must reject") } catch {}
        await old.shutdown()
        XCTAssertEqual(try Data(contentsOf: store.url), before)
        XCTAssertEqual(try Data(contentsOf: store.consentURL), consent)
        await new.shutdown()
    }
    func testQueueCapacityReservesInFlightBatchAndRemainsBoundedAfterCancellation() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = ManualTransport(), sleeper = ManualSleeper()
        let (stream, continuation) = AsyncStream<BatchFailure>.makeStream()
        let sdk = try await TranthorSDK(configuration: Configuration(writeKey: "fixture", batchSize: 100, flushIntervalMs: 60000,
            automaticContext: false, storageDirectory: root, maxQueueSize: 3, onError: { continuation.yield($0) }),
            transport: transport, sleep: { try await sleeper.sleep($0) })
        try await sdk.track(event: "a")
        let flush = Task { try await sdk.flush() }; try await transport.wait(1)
        for event in ["b", "c", "d"] { try await sdk.track(event: event) }
        let expiry = Task { await sdk.pauseForBackgroundExpiry() }
        try await waitUntil { await sdk.deliveryPaused }
        await transport.complete(0, error: DeliveryFailure(status: 503, message: "retry"))
        await expiry.value
        do { try await flush.value; XCTFail("Cancelled cycle must reject") } catch {}
        await sdk.shutdown(); await sleeper.releaseAll(); continuation.finish()
        let saved = try loadState(directory: root, namespace: "default")
        XCTAssertEqual(saved.queued.compactMap { $0["event"]?.string }, ["a", "c", "d"])
        XCTAssertEqual(saved.queued.count + saved.active.count, 3)
        var failures: [BatchFailure] = []
        for await value in stream { failures.append(value) }
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.events.compactMap { $0["event"]?.string }, ["b"])
    }
    func testQueueCapDropsOldestAndReportsOneBurst() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let (stream, continuation) = AsyncStream<BatchFailure>.makeStream()
        let sdk = try await TranthorSDK.configure(Configuration(writeKey: "fixture", batchSize: 100, flushIntervalMs: 60000,
            automaticContext: false, storageDirectory: root, maxQueueSize: 3, onError: { continuation.yield($0) }))
        for index in 0..<8 { try await sdk.track(event: "e\(index)") }
        await sdk.shutdown(); continuation.finish()
        var failures: [BatchFailure] = []
        for await value in stream { failures.append(value) }
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.events.count, 5)
        XCTAssertEqual(failures.first?.attempts, 0)
        XCTAssertEqual(try loadState(directory: root, namespace: "default").queued.compactMap { $0["event"]?.string }, ["e5", "e6", "e7"])
    }
    func testDroppedEventsAreReportedAfterTheInjectedDelayNotTheGlobalOne() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = ManualTransport(), sleeper = ManualSleeper()
        let (stream, continuation) = AsyncStream<BatchFailure>.makeStream()
        let sdk = try await TranthorSDK(configuration: Configuration(writeKey: "fixture", batchSize: 100, flushIntervalMs: 60000,
            automaticContext: false, storageDirectory: root, maxQueueSize: 2, onError: { continuation.yield($0) }),
            transport: transport, sleep: { try await sleeper.sleep($0) })
        for index in 0..<4 { try await sdk.track(event: "e\(index)") }
        let delay = try await sleeper.wait(500) // The drop report waits on the injected sleep.
        await sleeper.release(delay)
        var reports = stream.makeAsyncIterator()
        let failure = await reports.next()
        XCTAssertEqual(failure?.events.compactMap { $0["event"]?.string }, ["e0", "e1"])
        await sdk.shutdown(); continuation.finish()
    }
    func testPersistedActiveBatchRestoresBeforeWaitingEvents() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try JSONStore(directory: root, namespace: "default")
        var state = StoredState()
        func event(_ name: String) -> [String: JSONValue] {
            ["type": "track", "event": .string(name), "messageId": .string(name),
             "timestamp": "2026-10-13T00:00:00.000Z", "anonymousId": .string(state.anonymousId)]
        }
        state.active = [event("inflight1"), event("inflight2")]; state.queued = [event("waiting")]
        try store.save(state); try store.saveConsent(false)
        let transport = ManualTransport(), sleeper = ManualSleeper()
        await transport.autoSucceedFutureRequests()
        let sdk = try await sdk(root, transport, sleeper)
        try await sdk.flush()
        let sent = await transport.snapshot().flatMap { $0.compactMap { $0["event"]?.string } }
        XCTAssertEqual(sent, ["inflight1", "inflight2", "waiting"])
        await sdk.shutdown(); await sleeper.releaseAll()
    }
    func testConcurrentShutdownWaitsForFirstCleanupAndLeaseRelease() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = ManualTransport(), sleeper = ManualSleeper()
        let c = Configuration(writeKey: "fixture", batchSize: 100, flushIntervalMs: 60000,
                              automaticContext: false, storageDirectory: root)
        let sdk = try await TranthorSDK(configuration: c, transport: transport, sleep: { try await sleeper.sleep($0) })
        try await sdk.track(event: "a")
        let flush = Task { try? await sdk.flush() }
        try await transport.wait(1)
        let first = Task { await sdk.shutdown() }
        try await waitUntil { await sdk.isStopped }
        let second = Task { () -> Result<TranthorSDK, any Error> in
            await sdk.shutdown()
            do { return .success(try await TranthorSDK.configure(c)) }
            catch { return .failure(error) }
        }
        // The first cleanup is deliberately held in send; the second must await that cleanup.
        try await Task.sleep(for: .milliseconds(50))
        await transport.complete(0)
        let result = await second.value
        await first.value; await flush.value; await sleeper.releaseAll()
        switch result {
        case .success(let next): await next.shutdown()
        case .failure(let error): XCTFail("configure after the second shutdown returned failed: \(error)")
        }
    }
    func testResignActiveRetryContinuesWithoutForegroundCycleOrDrops() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = ManualTransport(), sleeper = ManualSleeper()
        let (stream, continuation) = AsyncStream<BatchFailure>.makeStream()
        let sdk = try await TranthorSDK(configuration: Configuration(writeKey: "fixture", batchSize: 2,
            flushIntervalMs: 1000, automaticContext: false, storageDirectory: root, maxQueueSize: 4,
            onError: { continuation.yield($0) }), transport: transport, sleep: { try await sleeper.sleep($0) })
        try await sdk.track(event: "a")
        let resign = Task { await sdk.flushForInactivity() }
        try await transport.wait(1)
        await transport.complete(0, error: DeliveryFailure(status: 503, message: "blip"))
        let retry = try await sleeper.wait(500)
        let paused = await sdk.deliveryPaused; XCTAssertFalse(paused)
        await transport.autoSucceedFutureRequests(); await sleeper.release(retry); await resign.value
        for (index, pair) in [["b", "c"], ["d", "e"]].enumerated() {
            for event in pair { try await sdk.track(event: event) }
            try await transport.wait(index + 3)
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while await sdk.deliveryCycleActive {
                guard ContinuousClock.now < deadline else { throw TestTimeout.waitingForRequests(index + 3) }
                try await Task.sleep(for: .milliseconds(1))
            }
        }
        try await sdk.track(event: "f")
        let timer = try await sleeper.wait(1000); await sleeper.release(timer)
        try await transport.wait(5)
        try await sdk.flush()
        await sdk.shutdown(); await sleeper.releaseAll(); continuation.finish()
        let requests = await transport.snapshot()
        XCTAssertEqual(requests.dropFirst().flatMap { $0.compactMap { $0["event"]?.string } }, ["a", "b", "c", "d", "e", "f"])
        var failures: [BatchFailure] = []; for await failure in stream { failures.append(failure) }
        XCTAssertTrue(failures.isEmpty)
    }

}
