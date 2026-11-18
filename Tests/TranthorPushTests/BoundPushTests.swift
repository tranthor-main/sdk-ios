import Foundation
import XCTest
@testable import TranthorPush
@testable import TranthorSDK

/// Bound to a TranthorSDK, TranthorPush registers the Installation and reports Push Received/Opened/Dismissed
/// through the SDK's own queue.
@MainActor
final class BoundPushTests: XCTestCase {
    private actor Permission {
        var value: InstallationPermission = .granted
        func set(_ v: InstallationPermission) { value = v }
    }
    private actor Events { var all: [PushEvent] = []; func add(_ e: PushEvent) { all.append(e) } }
    private struct Harness { let root: URL; let sdk: TranthorSDK; let push: TranthorPush; let permission: Permission; let events: Events }

    private func harness(signedIn: Bool = false) async throws -> Harness {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tranthor-bound-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let sdk = try await TranthorSDK.configure(Configuration(writeKey: "fixture", host: "http://127.0.0.1:1", batchSize: 100,
            flushIntervalMs: 3_600_000, storageNamespace: "bound-push", storageDirectory: root))
        if signedIn { try await sdk.identify(userId: "customer-1") } // A phone is registered only to an identified customer.
        let permission = Permission(), events = Events()
        let push = try await TranthorPush(
            configuration: PushConfiguration(bundleIdentifier: "com.example.bound", environment: .production, onEvent: { await events.add($0) }),
            sdk: sdk, permission: { await permission.value }, categoryStore: nil)
        return Harness(root: root, sdk: sdk, push: push, permission: permission, events: events)
    }
    private func queued(_ h: Harness) async throws -> [[String: JSONValue]] {
        await h.sdk.shutdown()
        var store = try JSONStore(directory: h.root, namespace: "bound-push")
        return try store.load().queued.filter { !($0["type"] == "identify" && $0["userId"] == "customer-1") }
    }
    private func note(_ id: String = "delivery-123") throws -> PushNotification {
        try XCTUnwrap(PushNotification(userInfo: ["tranthor": ["version": 1, "deliveryId": id]]))
    }
    private let token = Data([0x00, 0xab, 0xcd, 0xef])

    func testTokenRegistersTheInstallationThroughTheSDKQueue() async throws {
        let h = try await harness(signedIn: true)
        try await h.push.registerDeviceToken(token)
        let events = try await queued(h)
        XCTAssertEqual(events.count, 1)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event["event"], "Installation Registered")
        let p = try XCTUnwrap(event["properties"]?.object)
        XCTAssertEqual(p["platform"], "ios"); XCTAssertEqual(p["appId"], "com.example.bound")
        XCTAssertEqual(p["environment"], "production"); XCTAssertEqual(p["token"], "00abcdef")
        XCTAssertEqual(p["permissionState"], "granted")
    }
    func testSameTokenAndPermissionIsNotSentAgainButAPermissionChangeIs() async throws {
        let h = try await harness(signedIn: true)
        try await h.push.registerDeviceToken(token)
        try await h.push.registerDeviceToken(token)
        try await h.push.refreshPermission()
        await h.permission.set(.denied)
        try await h.push.refreshPermission()
        let events = try await queued(h)
        XCTAssertEqual(events.compactMap { $0["properties"]?["permissionState"]?.string }, ["granted", "denied"])
    }
    func testRefreshPermissionBeforeATokenDoesNothing() async throws {
        let h = try await harness()
        try await h.push.refreshPermission()
        let events = try await queued(h)
        XCTAssertEqual(events.count, 0)
    }
    func testRotatedTokenRemovesTheOldOne() async throws {
        let h = try await harness(signedIn: true)
        try await h.push.registerDeviceToken(token)
        try await h.push.registerDeviceToken(Data([1, 2]))
        let events = try await queued(h)
        XCTAssertEqual(events.compactMap { $0["event"]?.string }, ["Installation Registered", "Installation Removed", "Installation Registered"])
    }
    func testSDKConsentChangesKeepTheInstallationInStep() async throws {
        let h = try await harness(signedIn: true)
        try await h.push.registerDeviceToken(token)
        try await h.sdk.optOut()
        try await h.sdk.optIn()
        let events = try await queued(h)
        XCTAssertEqual(events.compactMap { $0["event"]?.string }, ["Installation Registered"])
        XCTAssertEqual(events.first?["properties"]?["token"], "00abcdef")
    }
    func testAnEmptyTokenIsRejectedAndNothingIsQueued() async throws {
        let h = try await harness(signedIn: true)
        do { try await h.push.registerDeviceToken(Data()); XCTFail("Empty token") } catch PushError.emptyDeviceToken {}
        let events = try await queued(h)
        XCTAssertEqual(events.count, 0)
    }

    func testForegroundIsReportedAsPushReceivedWithOnlyTheDeliveryId() async throws {
        let h = try await harness()
        let handled = try await h.push.handle(note(), interaction: .foreground)
        XCTAssertTrue(handled)
        let seen = await h.events.all
        let events = try await queued(h)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event["event"], "Push Received")
        XCTAssertEqual(event["properties"], ["deliveryId": "delivery-123"])
        XCTAssertEqual(event["messageId"], "24A51D3B-B4AF-88FA-AB13-3997ABB90868")
        XCTAssertEqual(seen.first?.messageId, "24A51D3B-B4AF-88FA-AB13-3997ABB90868")
        XCTAssertEqual(seen.first?.interaction, .foreground)
    }
    func testOpenedAndDismissedAreSeparateClaimsWithDeterministicIds() async throws {
        let h = try await harness()
        _ = try await h.push.handle(note(), interaction: .opened(actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier"))
        _ = try await h.push.handle(note(), interaction: .dismissed)
        let events = try await queued(h)
        XCTAssertEqual(events.compactMap { $0["event"]?.string }, ["Push Opened", "Push Dismissed"])
        XCTAssertEqual(events.compactMap { $0["properties"]?["deliveryId"]?.string }, ["delivery-123", "delivery-123"])
        XCTAssertEqual(events.last?["messageId"], "B18F63EE-5DB4-8A75-8190-F27FEFA3F795")
        XCTAssertNotEqual(events.first?["messageId"], events.last?["messageId"])
    }
    func testDuplicateObservationsAreReportedOnce() async throws {
        let h = try await harness()
        for _ in 0..<3 { _ = try await h.push.handle(note(), interaction: .foreground) }
        let events = try await queued(h)
        XCTAssertEqual(events.count, 1)
    }
    func testEventsCarryTheIdentityAtAdmission() async throws {
        let h = try await harness()
        try await h.sdk.identify(userId: "user-1")
        _ = try await h.push.handle(note(), interaction: .foreground)
        let events = try await queued(h)
        XCTAssertEqual(events.last?["userId"], "user-1")
        XCTAssertNil(events.last?["anonymousId"])
    }
    func testOptedOutSDKDiscardsClaimsButTheHandlerStillSaysItWasRecognised() async throws {
        let h = try await harness()
        try await h.sdk.optOut()
        let handled = try await h.push.handle(note(), interaction: .foreground)
        XCTAssertTrue(handled)
        let seen = await h.events.all
        XCTAssertEqual(seen.count, 0)
        let events = try await queued(h)
        XCTAssertEqual(events.count, 0)
    }
    func testUnrecognisedPayloadIsLeftToTheHost() async throws {
        let h = try await harness()
        let handled = try await h.push.handle(PushNotification(userInfo: ["foo": "bar"]), interaction: .foreground)
        XCTAssertFalse(handled)
    }

    // MARK: Consent and the server's registration
    private actor Recorder: SDKTransport {
        var events: [[String: JSONValue]] = []
        nonisolated func shutdown() {}
        func send(_ batch: [[String: JSONValue]]) async throws { events.append(contentsOf: batch) }
        func installationEvents(_ name: String) -> [[String: JSONValue]] { events.filter { $0["event"] == .string(name) } }
    }
    private func recordingHarness() async throws -> (sdk: TranthorSDK, push: TranthorPush, transport: Recorder, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tranthor-bound-consent-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let transport = Recorder()
        let sdk = try await TranthorSDK(
            configuration: Configuration(writeKey: "fixture", host: "http://127.0.0.1:1", batchSize: 100, flushIntervalMs: 3_600_000,
                                         retries: 0, baseDelay: 0, storageNamespace: "bound-consent", storageDirectory: root),
            transport: transport, sleep: sleepMilliseconds)
        try await sdk.identify(userId: "customer-1")
        let push = try await TranthorPush(
            configuration: PushConfiguration(bundleIdentifier: "com.example.bound", environment: .production),
            sdk: sdk, permission: { .granted }, categoryStore: nil)
        try await push.registerDeviceToken(token)
        return (sdk, push, transport, root)
    }
    private func eventually(_ what: String, _ check: () async -> Bool) async throws {
        for _ in 0..<500 { if await check() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Timed out waiting for \(what)")
    }

    func testOptOutQueuesExactlyOneInstallationRemovedAndOptInRegistersThePhoneAgain() async throws {
        let h = try await recordingHarness()
        try await h.sdk.optOut()
        try await eventually("the removal") { await h.transport.installationEvents("Installation Removed").count == 1 }
        let removed = await h.transport.installationEvents("Installation Removed")
        XCTAssertEqual(removed.count, 1)
        XCTAssertEqual(removed.first?["properties"]?["token"], "00abcdef")
        XCTAssertEqual(removed.first?["userId"], "customer-1")
        try await h.sdk.optIn()
        try await h.sdk.flush()
        let registered = await h.transport.installationEvents("Installation Registered")
        XCTAssertEqual(registered.count, 1, "The registration queued before the opt-out was discarded; the opt-in sends a new one")
        XCTAssertEqual(registered.first?["properties"]?["token"], "00abcdef")
        await h.sdk.shutdown()
    }
    func testAnotherOptOutWhileAlreadyOptedOutDoesNotRemoveTheInstallationAgain() async throws {
        let h = try await recordingHarness()
        try await h.sdk.optOut()
        try await eventually("the removal") { await h.transport.installationEvents("Installation Removed").count == 1 }
        try await h.sdk.optOut()
        try await Task.sleep(for: .milliseconds(150))
        let removed = await h.transport.installationEvents("Installation Removed")
        XCTAssertEqual(removed.count, 1)
        await h.sdk.shutdown()
        var store = try JSONStore(directory: h.root, namespace: "bound-consent")
        XCTAssertTrue(try store.load().pendingRemovals.isEmpty)
    }

    /// Message ids are stable: the same delivery and interaction always produce the same id, so the server can
    /// count a claim once.
    func testMessageIdsAreStable() {
        let vectors: [(String, PushInteraction, String)] = [
            ("delivery-123", .foreground, "24A51D3B-B4AF-88FA-AB13-3997ABB90868"),
            ("delivery-123", .opened(actionIdentifier: "default"), "1AB91B92-E51A-870E-85ED-98EA62BDF64E"),
            ("delivery-123", .dismissed, "B18F63EE-5DB4-8A75-8190-F27FEFA3F795"),
            ("unique-device-delivery", .opened(actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier"), "D6E5A013-DE62-8E83-B961-6DA1354FB030"),
            ("x.Y_z:0-9", .opened(actionIdentifier: "reply"), "3C8C1672-8558-8087-80FE-2FBBD32ABB77"),
        ]
        for (id, interaction, expected) in vectors {
            XCTAssertEqual(PushEvent(deliveryID: id, interaction: interaction).messageId, expected, "\(id) \(interaction)")
        }
        let opened = PushEvent(deliveryID: "d", interaction: .opened(actionIdentifier: "default"))
        XCTAssertNotEqual(opened.messageId, PushEvent(deliveryID: "d", interaction: .foreground).messageId)
        XCTAssertNotEqual(opened.messageId, PushEvent(deliveryID: "d", interaction: .opened(actionIdentifier: "reply")).messageId)
        XCTAssertNotNil(UUID(uuidString: opened.messageId))
    }
}
