import Foundation
import XCTest
@testable import TranthorSDK

/// Counts down failures for an injected file operation: `failures` calls fail, then it succeeds again.
final class FailureBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    init(_ failures: Int = 0) { remaining = failures }
    func set(_ failures: Int) { lock.lock(); remaining = failures; lock.unlock() }
    /// True while a failure is left, using one up.
    func consume() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard remaining > 0 else { return false }
        remaining -= 1
        return true
    }
}

/// A queue file whose deletion fails is not forgotten: it is never sent again by this process and is deleted later.
@MainActor
final class QueueDeletionTests: XCTestCase {
    override func setUp() { super.setUp(); executionTimeAllowance = 20 }
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("queue-deletion-" + UUID().uuidString) }
    private func make(_ root: URL, _ transport: ManualTransport, _ sleeper: ManualSleeper, maxQueueSize: Int = 10_000,
                      storeWrite: @escaping @Sendable (Data, URL) throws -> Void = { try JSONStore.write($0, to: $1) },
                      storeRemove: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) async throws -> TranthorSDK {
        try await TranthorSDK(configuration: Configuration(writeKey: "fixture", flushIntervalMs: 3_600_000,
            automaticContext: false, storageDirectory: root, maxQueueSize: maxQueueSize),
            transport: transport, sleep: { try await sleeper.sleep($0) }, storeWrite: storeWrite, storeRemove: storeRemove)
    }
    private func names(_ batch: [[String: JSONValue]]) -> [String] { batch.compactMap { $0["event"]?.string ?? $0["type"]?.string } }
    private func queueFiles(_ root: URL) throws -> [String] {
        let folder = try JSONStore(directory: root, namespace: "default").queueURL
        return try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }
    private func removing(_ budget: FailureBudget) -> @Sendable (URL) throws -> Void {
        { url in
            if budget.consume() { throw POSIXError(.EIO) }
            try FileManager.default.removeItem(at: url)
        }
    }
    private func sentAfterRestart(_ root: URL) async throws -> [[String]] {
        let transport = ManualTransport(), sleeper = ManualSleeper()
        await transport.autoSucceedFutureRequests()
        let next = try await make(root, transport, sleeper)
        try await next.flush()
        let sent = await transport.snapshot()
        await next.shutdown(); await sleeper.releaseAll()
        return sent.map(names)
    }

    func testEventsWhoseFilesOptOutCouldNotDeleteAreNeverSentAfterOptIn() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = ManualTransport(), sleeper = ManualSleeper()
        let budget = FailureBudget(2)
        let sdk = try await make(root, transport, sleeper, storeRemove: removing(budget))
        try await sdk.track(event: "old1")
        try await sdk.track(event: "old2")
        try await sdk.optOut()
        XCTAssertEqual(try queueFiles(root).count, 2, "Both deletions failed")
        try await sdk.optIn()
        try await sdk.track(event: "new")
        await sdk.shutdown(); await sleeper.releaseAll()
        let sent = try await sentAfterRestart(root)
        XCTAssertEqual(sent, [["new"]])
    }

    func testOptInThrowsAndTheUserStaysOptedOutWhileTheQueueFilesCannotBeDeleted() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = ManualTransport(), sleeper = ManualSleeper()
        let budget = FailureBudget(3)
        let sdk = try await make(root, transport, sleeper, storeRemove: removing(budget))
        try await sdk.track(event: "old")
        try await sdk.optOut() // The deletion fails once, in the budget's first call.
        do { try await sdk.optIn(); XCTFail("optIn must fail while the file cannot be deleted") }
        catch { guard case TranthorError.storeTemporarilyUnavailable = error else { return XCTFail("Got \(error)") } }
        let optedOut = await sdk.isOptedOut
        XCTAssertTrue(optedOut)
        try await sdk.track(event: "ignored")
        budget.set(0)
        try await sdk.optIn()
        let optedOutAfter = await sdk.isOptedOut
        XCTAssertFalse(optedOutAfter)
        XCTAssertEqual(try queueFiles(root), [])
        await sdk.shutdown(); await sleeper.releaseAll()
    }

    func testADeliveredOrRejectedBatchWhoseFileCannotBeDeletedIsNotSentAgainAndIsDeletedLater() async throws {
        for status in [nil, 400] as [Int?] {
            let root = root(); defer { try? FileManager.default.removeItem(at: root) }
            let transport = ManualTransport(), sleeper = ManualSleeper()
            let budget = FailureBudget(1)
            let sdk = try await make(root, transport, sleeper, storeRemove: removing(budget))
            try await sdk.track(event: "a")
            let first = Task { try await sdk.flush() }
            try await transport.wait(1)
            await transport.complete(0, error: status.map { DeliveryFailure(status: $0, message: "rejected") })
            _ = try? await first.value
            XCTAssertEqual(try queueFiles(root).count, 1, "The first deletion failed (status \(String(describing: status)))")
            try await sdk.track(event: "b")
            let second = Task { try await sdk.flush() }
            try await transport.wait(2)
            await transport.complete(1)
            try await second.value
            let requests = await transport.snapshot()
            XCTAssertEqual(requests.map(names), [["a"], ["b"]], "a is not sent again (status \(String(describing: status)))")
            XCTAssertEqual(try queueFiles(root), [], "The file left behind is deleted by a later cycle (status \(String(describing: status)))")
            await sdk.shutdown(); await sleeper.releaseAll()
        }
    }

    func testAFileTrimmedForCapacityWhoseDeletionFailedIsDeletedLater() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = ManualTransport(), sleeper = ManualSleeper()
        await transport.autoSucceedFutureRequests()
        let budget = FailureBudget(1)
        let sdk = try await make(root, transport, sleeper, maxQueueSize: 2, storeRemove: removing(budget))
        for event in ["a", "b", "c"] { try await sdk.track(event: event) }
        XCTAssertEqual(try queueFiles(root), ["00000000000000000001.json", "00000000000000000002.json", "00000000000000000003.json"],
                       "a was trimmed but its file could not be deleted")
        try await sdk.flush()
        let requests = await transport.snapshot()
        XCTAssertEqual(requests.map(names), [["b", "c"]])
        XCTAssertEqual(try queueFiles(root), [])
        await sdk.shutdown(); await sleeper.releaseAll()
    }

    func testAFailedResetChangesNeitherIdentityInMemoryNorOnDisk() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let budget = FailureBudget()
        let sdk = try await make(root, ManualTransport(), ManualSleeper(), storeWrite: { data, url in
            if url.lastPathComponent == "state.json" && budget.consume() { throw POSIXError(.ENOSPC) }
            try JSONStore.write(data, to: url)
        })
        try await sdk.identify(userId: "u1")
        let anonymous = await sdk.anonymousId
        budget.set(1)
        do { try await sdk.reset(); XCTFail("The state write was made to fail") } catch {}
        let user = await sdk.userId, anonymousAfter = await sdk.anonymousId
        XCTAssertEqual(user, "u1")
        XCTAssertEqual(anonymousAfter, anonymous)
        await sdk.shutdown()
        let stored = try loadState(directory: root, namespace: "default")
        XCTAssertEqual(stored.userId, "u1")
        XCTAssertEqual(stored.anonymousId, anonymous)
    }

    func testAnIdentifyEventFileThatCouldNotBeRolledBackIsNeverSent() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let writes = FailureBudget(), removals = FailureBudget()
        let sdk = try await make(root, ManualTransport(), ManualSleeper(), storeWrite: { data, url in
            if url.lastPathComponent == "state.json" && writes.consume() { throw POSIXError(.ENOSPC) }
            try JSONStore.write(data, to: url)
        }, storeRemove: removing(removals))
        writes.set(1); removals.set(1) // Armed after configure, whose own writes are done.
        do { try await sdk.identify(userId: "u1"); XCTFail("The state write was made to fail") } catch {}
        XCTAssertEqual(try queueFiles(root).count, 1, "The rollback could not delete the event file")
        try await sdk.flush()
        XCTAssertEqual(try queueFiles(root), [], "A later cycle deletes it")
        await sdk.shutdown()
        let sent = try await sentAfterRestart(root)
        XCTAssertEqual(sent, [])
    }
}
