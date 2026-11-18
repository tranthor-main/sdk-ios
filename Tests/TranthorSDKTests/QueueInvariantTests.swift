import Foundation
import XCTest
@testable import TranthorSDK

/// Behaviour of the durable queue that later changes must not lose.
@MainActor
final class QueueInvariantTests: XCTestCase {
    override func setUp() { super.setUp(); executionTimeAllowance = 20 }
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("queue-invariant-" + UUID().uuidString) }
    private func make(_ root: URL, _ transport: ManualTransport, _ sleeper: ManualSleeper) async throws -> TranthorSDK {
        try await TranthorSDK(configuration: Configuration(writeKey: "fixture", flushIntervalMs: 7000, retries: 0, automaticContext: false, storageDirectory: root),
                              transport: transport, sleep: { try await sleeper.sleep($0) })
    }
    private func names(_ batch: [[String: JSONValue]]) -> [String] { batch.compactMap { $0["event"]?.string } }
    private func queueFolder(_ root: URL) throws -> URL { try JSONStore(directory: root, namespace: "default").queueURL }
    private func queueFiles(_ root: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: queueFolder(root).path).sorted()
    }

    func testTheNumberOfAFileSetAsideIsNotReusedAfterARestart() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try await make(root, ManualTransport(), ManualSleeper())
        for event in ["a", "b", "c"] { try await first.track(event: event) }
        await first.shutdown()
        try Data("{broken".utf8).write(to: queueFolder(root).appendingPathComponent("00000000000000000003.json"))
        // This start sets the damaged file aside as 00000000000000000003.corrupt.
        let second = try await make(root, ManualTransport(), ManualSleeper())
        await second.shutdown()
        XCTAssertEqual(try queueFiles(root), ["00000000000000000001.json", "00000000000000000002.json", "00000000000000000003.corrupt"])
        // The next start finds only the set-aside file at that number.
        let third = try await make(root, ManualTransport(), ManualSleeper())
        try await third.track(event: "d")
        await third.shutdown()
        XCTAssertEqual(try queueFiles(root), ["00000000000000000001.json", "00000000000000000002.json",
                                               "00000000000000000003.corrupt", "00000000000000000004.json"])
    }

    func testFilesThatAreNotASequenceNumberPlusJsonAreIgnoredAndNotDelivered() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try await make(root, ManualTransport(), ManualSleeper())
        for event in ["a", "b"] { try await first.track(event: event) }
        await first.shutdown()
        let event = Data(#"{"type":"track","event":"stray","messageId":"m","timestamp":"2026-11-01T00:00:00.000Z","userId":"u"}"#.utf8)
        let strays = ["0000000000000000001.json", "000000000000000000010.json", "00000000000000000011.JSON", "00000000000000000012.json~",
                      "00000000000000000013.json.bak", "00000000000000000014.txt", "stray.json", ".DS_Store"]
        for name in strays { try event.write(to: queueFolder(root).appendingPathComponent(name)) }
        let transport = ManualTransport(), sleeper = ManualSleeper()
        await transport.autoSucceedFutureRequests()
        let next = try await make(root, transport, sleeper)
        try await next.flush()
        let sent = await transport.snapshot()
        XCTAssertEqual(sent.map(names), [["a", "b"]])
        XCTAssertEqual(try queueFiles(root), strays.sorted(), "Only the queue's own files are deleted")
        await next.shutdown(); await sleeper.releaseAll()
    }

    func testAVersionOneStateIsMigratedWhileOptedOutWithoutSendingOrKeepingAnyQueueFile() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try JSONStore(directory: root, namespace: "default")
        try Data(releaseZeroOneZeroState(optedOut: true).utf8).write(to: store.url)
        try Data("{\"version\":1,\"optedOut\":true}".utf8).write(to: store.consentURL)
        let transport = ManualTransport(), sleeper = ManualSleeper()
        await transport.autoSucceedFutureRequests()
        let sdk = try await make(root, transport, sleeper)
        let optedOut = await sdk.isOptedOut
        XCTAssertTrue(optedOut)
        try await sdk.flush()
        let sent = await transport.snapshot()
        XCTAssertEqual(sent.count, 0)
        XCTAssertEqual(try queueFiles(root), [])
        await sdk.shutdown(); await sleeper.releaseAll()
        let again = try await make(root, transport, sleeper)
        try await again.flush()
        let sentAfterRestart = await transport.snapshot()
        XCTAssertEqual(sentAfterRestart.count, 0)
        await again.shutdown(); await sleeper.releaseAll()
    }

    /// A pause that was started and then cancelled must not start a delivery when its sleep completes anyway.
    private func startPause(_ sdk: TranthorSDK, _ transport: ManualTransport, _ sleeper: ManualSleeper) async throws -> (id: Int, task: Task<Void, Never>) {
        try await sdk.track(event: "a")
        let first = Task { try await sdk.flush() }
        try await transport.wait(1)
        await transport.complete(0, error: DeliveryFailure(status: 503, message: "down"))
        do { try await first.value; XCTFail("flush must throw") } catch {}
        let id = try await sleeper.wait(30000)
        let task = await sdk.pause.task
        return (id, try XCTUnwrap(task))
    }

    func testOptOutCancelsAStartedPauseAndItsLateCompletionMakesNoRequest() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = ManualTransport(), sleeper = ManualSleeper()
        let sdk = try await make(root, transport, sleeper)
        let pause = try await startPause(sdk, transport, sleeper)
        try await sdk.optOut()
        try await sleeper.waitCancellation(pause.id)
        try await sdk.optIn()
        try await sdk.track(event: "b") // Work is waiting, so a pause that ended by mistake would start a delivery.
        await sleeper.release(pause.id, ignoringCancellation: true)
        await pause.task.value
        let active = await sdk.deliveryCycleActive
        XCTAssertFalse(active)
        let sent = await transport.snapshot()
        XCTAssertEqual(sent.count, 1, "Only the failed attempt was made")
        await transport.succeedEverything()
        await sdk.shutdown(); await sleeper.releaseAll()
    }

    func testShutdownCancelsAStartedPauseAndItsLateCompletionMakesNoRequest() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = ManualTransport(), sleeper = ManualSleeper()
        let sdk = try await make(root, transport, sleeper)
        let pause = try await startPause(sdk, transport, sleeper)
        await sdk.shutdown()
        try await sleeper.waitCancellation(pause.id)
        await sleeper.release(pause.id, ignoringCancellation: true)
        await pause.task.value
        let sent = await transport.snapshot()
        XCTAssertEqual(sent.count, 1, "Only the failed attempt was made")
        await transport.succeedEverything()
        await sleeper.releaseAll()
    }
}
