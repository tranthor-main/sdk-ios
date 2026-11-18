import Foundation
import XCTest
@testable import TranthorPush
@testable import TranthorSDK

/// Notification handling and lifecycle of a bound TranthorPush: ownership of payloads, duplicate suppression,
/// configuration validation and shutdown.
@MainActor
final class TranthorPushTests: XCTestCase {
    private func make(onEvent: @escaping @Sendable (PushEvent) async throws -> Void = { _ in }, limit: Int = 1024,
                      signedIn: Bool = false) async throws -> (push: TranthorPush, sdk: TranthorSDK, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tranthor-push-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let sdk = try await TranthorSDK.configure(Configuration(writeKey: "fixture", host: "http://127.0.0.1:1", batchSize: 100,
            flushIntervalMs: 3_600_000, storageNamespace: "push", storageDirectory: root))
        if signedIn { try await sdk.identify(userId: "customer-1") }
        let push = try await TranthorPush(configuration: PushConfiguration(bundleIdentifier: "com.example.tests", environment: .development,
                                                                           recentEventLimit: limit, onEvent: onEvent),
                                          sdk: sdk, permission: { .granted }, categoryStore: nil)
        return (push, sdk, root)
    }
    private func queued(_ h: (push: TranthorPush, sdk: TranthorSDK, root: URL)) async throws -> [[String: JSONValue]] {
        await h.sdk.shutdown()
        var store = try JSONStore(directory: h.root, namespace: "push")
        return try store.load().queued.filter { $0["type"] != "identify" }
    }
    private func notification(_ id: String = "delivery-1") throws -> PushNotification {
        try XCTUnwrap(PushNotification(userInfo: ["tranthor": ["version": 1, "deliveryId": id]]))
    }

    func testTokenUsesEveryByteAndDoesNotAssumeLength() async throws {
        let h = try await make(signedIn: true)
        try await h.push.registerDeviceToken(Data([0, 1, 15, 16, 255]))
        try await h.push.registerDeviceToken(Data([0, 1, 15, 16, 255]))
        let events = try await queued(h)
        XCTAssertEqual(events.compactMap { $0["properties"]?["token"]?.string }, ["00010f10ff"], "A repeated token is registered once")
    }
    func testPayloadOwnershipRejectsOtherVendorsAndWrongVersions() {
        let invalid: [[AnyHashable: Any]] = [[:], ["aps": ["alert": "Other"]],
            ["tranthor": ["version": true, "deliveryId": "x"]], ["tranthor": ["version": "1", "deliveryId": "x"]],
            ["tranthor": ["version": 2, "deliveryId": "x"]], ["tranthor": ["version": 1, "deliveryId": " "]],
            ["tranthor": ["version": 1, "deliveryId": String(repeating: "x", count: 129)]],
            ["tranthor": ["version": 1, "deliveryId": "line\nbreak"]],
            ["tranthor": ["version": 1, "deliveryId": "user@example.com"]]]
        for payload in invalid { XCTAssertNil(PushNotification(userInfo: payload)) }
        XCTAssertNotNil(PushNotification(userInfo: ["tranthor": ["version": 1, "deliveryId": "valid"], "aps": ["alert": "Hi"]]))
    }
    func testUnownedPayloadReturnsFalseAndReportsNothing() async throws {
        let h = try await make()
        let handled = try await h.push.handle(nil, interaction: .foreground)
        XCTAssertFalse(handled)
        let events = try await queued(h)
        XCTAssertTrue(events.isEmpty)
    }
    func testResetToANewAnonymousIdentityDoesNotLeakThePriorUser() async throws {
        let h = try await make()
        try await h.sdk.identify(userId: "old-user")
        try await h.sdk.reset()
        let anonymous = await h.sdk.anonymousId
        _ = try await h.push.handle(notification(), interaction: .foreground)
        let events = try await queued(h)
        XCTAssertEqual(events.last?["anonymousId"]?.string, anonymous)
        XCTAssertNil(events.last?["userId"])
    }
    func testConcurrentDuplicateObservationsDoNotRepeatTheCallback() async throws {
        let gate = Gate(), recorder = Recorder()
        let h = try await make(onEvent: { event in
            await recorder.add(event)
            await gate.enterOnce()
        })
        let payload = try notification()
        let first = Task { try await h.push.handle(payload, interaction: .foreground) }
        await gate.waitUntilEntered()
        for _ in 0..<25 { _ = try await h.push.handle(payload, interaction: .foreground) }
        await gate.release(); _ = try await first.value
        _ = try await h.push.handle(payload, interaction: .foreground)
        _ = try await h.push.handle(payload, interaction: .opened(actionIdentifier: "default"))
        let events = await recorder.events
        XCTAssertEqual(events.count, 2, "Foreground and opened are separate observations")
    }
    func testAFailedCallbackCanBeRetriedAndDuplicateTrackingIsBounded() async throws {
        let recorder = Recorder()
        await recorder.failNext()
        let h = try await make(onEvent: { try await recorder.record($0) }, limit: 2)
        do { _ = try await h.push.handle(notification("a"), interaction: .foreground); XCTFail("Should fail") } catch RecorderError.failed {}
        for id in ["a", "b", "c", "a"] { _ = try await h.push.handle(notification(id), interaction: .foreground) }
        let events = await recorder.events
        XCTAssertEqual(events.map(\.deliveryID), ["a", "a", "b", "c", "a"])
    }
    func testShutdownRejectsLaterTokensAndIgnoresNotifications() async throws {
        let recorder = Recorder()
        let h = try await make(onEvent: { await recorder.add($0) }, signedIn: true)
        try await h.push.registerDeviceToken(Data([1]))
        await h.push.shutdown(); await h.push.shutdown()
        do { try await h.push.registerDeviceToken(Data([2])); XCTFail("Stopped") } catch PushError.shutDown {}
        let handled = try await h.push.handle(notification(), interaction: .foreground)
        XCTAssertTrue(handled)
        let sent = await recorder.events, events = try await queued(h)
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(events.compactMap { $0["event"]?.string }, ["Installation Registered"], "Nothing after shutdown")
    }
    func testBundleIdentifierValidation() async throws {
        let h = try await make()
        for id in ["", ".bad", "bad..name", "bad/name", "single", "a."] {
            do {
                _ = try await TranthorPush(configuration: PushConfiguration(bundleIdentifier: id, environment: .production), sdk: h.sdk,
                                           permission: { .unknown }, categoryStore: nil)
                XCTFail("\(id) should be rejected")
            } catch PushError.invalidBundleIdentifier {}
        }
        XCTAssertEqual(PushConfiguration(bundleIdentifier: "a.b", environment: .development, recentEventLimit: 0).recentEventLimit, 1)
        await h.sdk.shutdown()
    }
}

private enum RecorderError: Error { case failed }
private actor Recorder {
    var events: [PushEvent] = []
    private var failing = false
    func add(_ event: PushEvent) { events.append(event) }
    func failNext() { failing = true }
    func record(_ event: PushEvent) throws {
        events.append(event)
        if failing { failing = false; throw RecorderError.failed }
    }
}
private actor Gate {
    private var entered = false, used = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    func enterOnce() async {
        guard !used else { return }
        used = true
        await withCheckedContinuation { continuation in
            waiter = continuation; entered = true
            entryWaiters.forEach { $0.resume() }; entryWaiters.removeAll()
        }
    }
    func waitUntilEntered() async { if !entered { await withCheckedContinuation { entryWaiters.append($0) } } }
    func release() { waiter?.resume(); waiter = nil }
}
