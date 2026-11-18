#if canImport(UIKit)
import UIKit
import XCTest
@testable import TranthorSDK

@MainActor
final class LifecycleNotificationTests: XCTestCase {
    override func setUp() { super.setUp(); executionTimeAllowance = 10 }
    private func makeSDK(_ root: URL, _ transport: InactivityTransport) async throws -> TranthorSDK {
        try await TranthorSDK(configuration: Configuration(writeKey: "fixture", batchSize: 100,
            flushIntervalMs: 60000, baseDelay: 1, automaticContext: false, storageDirectory: root),
            transport: transport, sleep: sleepMilliseconds)
    }
    func testResignActiveNotificationRetainsOrdinaryRetryDelivery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = InactivityTransport()
        let sdk = try await makeSDK(root, transport)
        try await sdk.track(event: "inactive")
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await transport.attempts < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let attempts = await transport.attempts, paused = await sdk.deliveryPaused
        XCTAssertEqual(attempts, 2, "Resign-active must retry without waiting for a background/foreground cycle")
        XCTAssertFalse(paused)
        await sdk.shutdown()
    }
    func testHomePressPromotesRunningInactivityFlushToBackgroundMode() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = OfflineTransport()
        let sdk = try await TranthorSDK(configuration: Configuration(writeKey: "fixture", batchSize: 100,
            flushIntervalMs: 60000, baseDelay: 1000, automaticContext: false, storageDirectory: root),
            transport: transport, sleep: sleepMilliseconds)
        try await sdk.track(event: "home")
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        let firstDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await transport.attempts == 0, ContinuousClock.now < firstDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(150))
        let before = await transport.attempts, pausedBefore = await sdk.deliveryPaused
        XCTAssertEqual(before, 1); XCTAssertFalse(pausedBefore)
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(700))
        while !(await sdk.deliveryPaused), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let attempts = await transport.attempts, paused = await sdk.deliveryPaused
        XCTAssertEqual(attempts, 2, "Home must cancel inactivity backoff and make one immediate background attempt")
        XCTAssertTrue(paused, "Failed background delivery must pause with the batch retained")
        await sdk.shutdown()
        var store = try JSONStore(directory: root, namespace: "default")
        XCTAssertEqual(try store.load().queue.events.compactMap { $0.event["event"]?.string }, ["home"])
    }
    func testDidBecomeActiveNotificationResumesPausedDeliveryTimer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sdk = try await makeSDK(root, InactivityTransport())
        try await sdk.track(event: "waiting")
        await sdk.pauseForBackgroundExpiry()
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await sdk.deliveryPaused, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let paused = await sdk.deliveryPaused, timer = await sdk.pendingTimer
        XCTAssertFalse(paused, "Returning from an inactive alert must resume delivery")
        XCTAssertNotNil(timer)
        await sdk.shutdown()
    }
}
private actor InactivityTransport: SDKTransport {
    private(set) var attempts = 0
    nonisolated func shutdown() {}
    func send(_ batch: [[String: JSONValue]]) async throws {
        attempts += 1
        if attempts == 1 { throw DeliveryFailure(status: 503, message: "fixture blip") }
    }
}
private actor OfflineTransport: SDKTransport {
    private(set) var attempts = 0
    nonisolated func shutdown() {}
    func send(_ batch: [[String: JSONValue]]) async throws {
        attempts += 1; throw DeliveryFailure(status: 503, message: "fixture offline")
    }
}
#endif
