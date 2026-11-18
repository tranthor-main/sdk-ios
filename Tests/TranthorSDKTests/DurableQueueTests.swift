import Foundation
import XCTest
@testable import TranthorSDK

/// A batch whose retries run out stays queued and is retried later; only a rejection, an opt-out or a full queue discards events.
/// Time is driven by the injected sleep and responses are released explicitly: no wall-clock delays.
@MainActor
final class DurableQueueTests: XCTestCase {
    override func setUp() { super.setUp(); executionTimeAllowance = 15 }
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("durable-" + UUID().uuidString) }
    private func make(_ root: URL, _ transport: ManualTransport, _ sleeper: ManualSleeper, batchSize: Double = 100,
                      flushIntervalMs: Double = 7000, retries: Double = 0,
                      onError: (@Sendable (BatchFailure) -> Void)? = nil) async throws -> TranthorSDK {
        try await TranthorSDK(configuration: Configuration(writeKey: "fixture", batchSize: batchSize, flushIntervalMs: flushIntervalMs,
            retries: retries, automaticContext: false, storageDirectory: root, onError: onError),
            transport: transport, sleep: { try await sleeper.sleep($0) })
    }
    private func names(_ batch: [[String: JSONValue]]) -> [String] { batch.compactMap { $0["event"]?.string } }

    func testExhaustedRetryableBatchStaysQueuedWithoutOnErrorAndTheNextFlushDeliversIt() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = ManualTransport(), sleeper = ManualSleeper()
        let (stream, continuation) = AsyncStream<BatchFailure>.makeStream()
        let sdk = try await make(root, transport, sleeper, retries: 1, onError: { continuation.yield($0) })
        try await sdk.track(event: "a")
        let first = Task { try await sdk.flush() }
        try await transport.wait(1)
        await transport.complete(0, error: DeliveryFailure(status: 503, message: "down"))
        let backoff = try await sleeper.wait(500)
        await sleeper.release(backoff)
        try await transport.wait(2)
        await transport.complete(1, error: DeliveryFailure(status: 503, message: "down"))
        do { try await first.value; XCTFail("flush must still throw the failure") }
        catch { XCTAssertEqual((error as? DeliveryFailure)?.status, 503) }
        let second = Task { try await sdk.flush() }
        try await transport.wait(3)
        await transport.complete(2)
        try await second.value
        let requests = await transport.snapshot()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[2], requests[0], "The kept batch is sent again with the same message ids and timestamps")
        XCTAssertEqual(names(requests[2]), ["a"])
        await sdk.shutdown(); await sleeper.releaseAll(); continuation.finish()
        var failures: [BatchFailure] = []; for await failure in stream { failures.append(failure) }
        XCTAssertTrue(failures.isEmpty, "Running out of retries is not reported to onError")
    }

    func testEveryRetryableFailureKindKeepsTheBatch() async throws {
        for status in [nil, 408, 425, 429, 500, 503, 599] as [Int?] {
            let root = root(); defer { try? FileManager.default.removeItem(at: root) }
            let transport = ManualTransport(), sleeper = ManualSleeper()
            let sdk = try await make(root, transport, sleeper)
            try await sdk.track(event: "a")
            let flush = Task { try await sdk.flush() }
            try await transport.wait(1)
            await transport.complete(0, error: DeliveryFailure(status: status, message: "down"))
            do { try await flush.value; XCTFail("flush must throw for \(String(describing: status))") }
            catch { XCTAssertEqual((error as? DeliveryFailure)?.status, status) }
            await transport.autoSucceedFutureRequests()
            try await sdk.flush()
            let requests = await transport.snapshot()
            XCTAssertEqual(requests.map(names), [["a"], ["a"]], "status \(String(describing: status))")
            await sdk.shutdown(); await sleeper.releaseAll()
        }
    }

    func testBatchesQueuedBehindAnExhaustedBatchAreNotSentBeforeIt() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = ManualTransport(), sleeper = ManualSleeper()
        let sdk = try await make(root, transport, sleeper, batchSize: 1)
        try await sdk.track(event: "a")
        try await sdk.track(event: "b")
        try await sdk.track(event: "c")
        let flush = Task { try await sdk.flush() }
        try await transport.wait(1)
        await transport.complete(0, error: DeliveryFailure(status: 500, message: "down"))
        do { try await flush.value; XCTFail("flush must throw") } catch {}
        var requests = await transport.snapshot()
        XCTAssertEqual(requests.map(names), [["a"]], "b and c wait behind a")
        await transport.autoSucceedFutureRequests()
        try await sdk.flush()
        requests = await transport.snapshot()
        XCTAssertEqual(requests.map(names), [["a"], ["a"], ["b"], ["c"]])
        await sdk.shutdown(); await sleeper.releaseAll()
    }

    func testAutomaticDeliveryPausesAfterAnExhaustedCycleForGrowingLengths() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = ManualTransport(), sleeper = ManualSleeper()
        let sdk = try await make(root, transport, sleeper, batchSize: 3)
        try await sdk.track(event: "a")
        let first = Task { try await sdk.flush() }
        try await transport.wait(1)
        await transport.complete(0, error: DeliveryFailure(status: 503, message: "down"))
        do { try await first.value; XCTFail("flush must throw") } catch {}
        // A new event and a full batch do not start an attempt during the pause.
        for event in ["b", "c", "d"] {
            try await sdk.track(event: event)
            let active = await sdk.deliveryCycleActive
            XCTAssertFalse(active, "tracking \(event) must not start an attempt during the pause")
        }
        let pauses: [Double] = [30000, 60000, 120000, 240000, 300000, 300000]
        for (index, pause) in pauses.enumerated() {
            let id = try await sleeper.wait(pause)
            let sent = await transport.snapshot().count
            XCTAssertEqual(sent, index + 1, "No request is made until the pause ends")
            if index == pauses.count - 1 { break }
            await sleeper.release(id)
            try await transport.wait(index + 2)
            await transport.complete(index + 1, error: DeliveryFailure(status: 503, message: "down"))
        }
        let requested = await sleeper.requested
        XCTAssertEqual(requested, [7000] + pauses, "Only the first event's interval timer and the pauses ask for a sleep")
        await sdk.shutdown(); await sleeper.releaseAll()
    }

    func testADeliveredBatchResetsThePauseToThirtySeconds() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = ManualTransport(), sleeper = ManualSleeper()
        let sdk = try await make(root, transport, sleeper)
        try await sdk.track(event: "a")
        let first = Task { try await sdk.flush() }
        try await transport.wait(1)
        await transport.complete(0, error: DeliveryFailure(status: 503, message: "down"))
        do { try await first.value; XCTFail("flush must throw") } catch {}
        // The pause ends on its own and the next attempt fails too: the second pause is 60 s.
        let firstPause = try await sleeper.wait(30000)
        await sleeper.release(firstPause)
        try await transport.wait(2)
        await transport.complete(1, error: DeliveryFailure(status: 503, message: "down"))
        _ = try await sleeper.wait(60000)
        let delivered = Task { try await sdk.flush() }
        try await transport.wait(3)
        await transport.complete(2)
        try await delivered.value
        try await sdk.track(event: "b")
        let failing = Task { try await sdk.flush() }
        try await transport.wait(4)
        await transport.complete(3, error: DeliveryFailure(status: 503, message: "down"))
        do { try await failing.value; XCTFail("flush must throw") } catch {}
        let requested = await sleeper.requested
        XCTAssertEqual(requested, [7000, 30000, 60000, 7000, 30000])
        await sdk.shutdown(); await sleeper.releaseAll()
    }

    func testReturnToTheForegroundDuringThePauseAttemptsAtOnce() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = ManualTransport(), sleeper = ManualSleeper()
        let sdk = try await make(root, transport, sleeper)
        try await sdk.track(event: "a")
        let first = Task { try await sdk.flush() }
        try await transport.wait(1)
        await transport.complete(0, error: DeliveryFailure(status: 503, message: "down"))
        do { try await first.value; XCTFail("flush must throw") } catch {}
        _ = try await sleeper.wait(30000)
        await sdk.resumeOnForeground()
        try await transport.wait(2)
        await transport.complete(1)
        let requests = await transport.snapshot()
        XCTAssertEqual(requests.map(names), [["a"], ["a"]])
        await sdk.shutdown(); await sleeper.releaseAll()
    }

    func testFlushDuringThePauseAttemptsAtOnce() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = ManualTransport(), sleeper = ManualSleeper()
        let sdk = try await make(root, transport, sleeper)
        try await sdk.track(event: "a")
        let first = Task { try await sdk.flush() }
        try await transport.wait(1)
        await transport.complete(0, error: DeliveryFailure(status: 503, message: "down"))
        do { try await first.value; XCTFail("flush must throw") } catch {}
        let pause = try await sleeper.wait(30000)
        let second = Task { try await sdk.flush() }
        try await transport.wait(2)
        await transport.complete(1)
        try await second.value
        try await sleeper.waitCancellation(pause)
        await sdk.shutdown(); await sleeper.releaseAll()
    }

    func testANewInstanceOnTheSameStorageStartsWithoutAPause() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = ManualTransport(), sleeper = ManualSleeper()
        let sdk = try await make(root, transport, sleeper)
        try await sdk.track(event: "a")
        let first = Task { try await sdk.flush() }
        try await transport.wait(1)
        await transport.complete(0, error: DeliveryFailure(status: 503, message: "down"))
        do { try await first.value; XCTFail("flush must throw") } catch {}
        _ = try await sleeper.wait(30000)
        await sdk.shutdown(); await sleeper.releaseAll()
        let nextTransport = ManualTransport(), nextSleeper = ManualSleeper()
        let next = try await make(root, nextTransport, nextSleeper)
        let timer = try await nextSleeper.wait(7000)
        await nextSleeper.release(timer)
        try await nextTransport.wait(1)
        await nextTransport.complete(0)
        let requested = await nextSleeper.requested
        XCTAssertEqual(requested, [7000], "The interval timer, not a pause, starts the first attempt")
        let sent = await nextTransport.snapshot()
        XCTAssertEqual(sent.map(names), [["a"]])
        await next.shutdown(); await nextSleeper.releaseAll()
    }

    func testARejectedBatchIsDiscardedAndReportedWhileLaterBatchesStillGo() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = ManualTransport(), sleeper = ManualSleeper()
        let (stream, continuation) = AsyncStream<BatchFailure>.makeStream()
        let sdk = try await make(root, transport, sleeper, batchSize: 1, retries: 3, onError: { continuation.yield($0) })
        try await sdk.track(event: "a")
        try await sdk.track(event: "b")
        let flush = Task { try await sdk.flush() }
        try await transport.wait(1)
        await transport.complete(0, error: DeliveryFailure(status: 400, message: "rejected"))
        try await transport.wait(2)
        await transport.complete(1)
        do { try await flush.value; XCTFail("flush reports the rejection") }
        catch { XCTAssertEqual((error as? DeliveryFailure)?.status, 400) }
        let requests = await transport.snapshot()
        XCTAssertEqual(requests.map(names), [["a"], ["b"]], "The rejected batch is not sent again")
        await sdk.shutdown(); await sleeper.releaseAll(); continuation.finish()
        var failures: [BatchFailure] = []; for await failure in stream { failures.append(failure) }
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.error.status, 400)
        XCTAssertEqual(failures.first?.attempts, 1)
        XCTAssertEqual(failures.first?.events.compactMap { $0["event"]?.string }, ["a"])
    }

    func testOptOutDiscardsAKeptBatchAndEndsThePause() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = ManualTransport(), sleeper = ManualSleeper()
        let sdk = try await make(root, transport, sleeper)
        try await sdk.track(event: "a")
        let first = Task { try await sdk.flush() }
        try await transport.wait(1)
        await transport.complete(0, error: DeliveryFailure(status: 503, message: "down"))
        do { try await first.value; XCTFail("flush must throw") } catch {}
        let pause = try await sleeper.wait(30000)
        try await sdk.optOut()
        try await sleeper.waitCancellation(pause)
        try await sdk.optIn()
        try await sdk.flush()
        let requests = await transport.snapshot()
        XCTAssertEqual(requests.count, 1, "The discarded event is not sent after opting back in")
        await sdk.shutdown(); await sleeper.releaseAll()
    }
}
