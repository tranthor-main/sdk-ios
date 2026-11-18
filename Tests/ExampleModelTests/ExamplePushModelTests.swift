import Foundation
import XCTest
import TranthorSDK
@testable import TranthorPush
#if SWIFT_PACKAGE
@testable import ExampleModelSupport
#else
@testable import TranthorExample
#endif

@MainActor
final class ExamplePushModelTests: XCTestCase {
    private func payload(_ id: String = "cold-start") throws -> PushNotification {
        try XCTUnwrap(PushNotification(userInfo: ["tranthor": ["version": 1, "deliveryId": id]]))
    }
    private func model() -> ExamplePushModel {
        ExamplePushModel(bundleIdentifier: "com.example.tests", environment: .development, factory: { configuration, sdk in
            try await TranthorPush(configuration: configuration, sdk: sdk, categoryStore: nil)
        })
    }
    private func makeSDK() async throws -> TranthorSDK {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("example-push-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try await TranthorSDK.configure(Configuration(writeKey: "fixture", host: "http://127.0.0.1:1", flushIntervalMs: 3_600_000,
                                                             storageNamespace: "example-push", storageDirectory: root))
    }
    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    }
    func testColdStartTapWaitsForPersistedConsentAndIdentity() async throws {
        let push = model(), collector = Collector(), sdk = try await makeSDK()
        push.onEvent = { collector.events.append($0) }
        try await push.receive(payload(), interaction: .opened(actionIdentifier: "default"))
        XCTAssertTrue(collector.events.isEmpty)
        await push.synchronize(optedOut: false, sdk: sdk)
        await waitUntil { !collector.events.isEmpty }
        XCTAssertEqual(collector.events.count, 1)
        XCTAssertEqual(collector.events.first?.deliveryID, "cold-start")
        await sdk.shutdown()
    }
    func testColdStartTapIsDiscardedWhenPersistedConsentIsOut() async throws {
        let push = model(), collector = Collector(), sdk = try await makeSDK()
        push.onEvent = { collector.events.append($0) }
        try await push.receive(payload(), interaction: .opened(actionIdentifier: "default"))
        await push.synchronize(optedOut: true, sdk: sdk)
        await push.synchronize(optedOut: false, sdk: sdk)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(collector.events.isEmpty, "Opt in must not replay observations discarded by persisted opt out")
        await sdk.shutdown()
    }
    func testColdStartBufferDropsOldestAt32AndDoesNotGrow() async throws {
        let push = model(), collector = Collector(), sdk = try await makeSDK()
        push.onEvent = { collector.events.append($0) }
        for index in 0..<40 { try await push.receive(payload("item-\(index)"), interaction: .foreground) }
        await push.synchronize(optedOut: false, sdk: sdk)
        await waitUntil { collector.events.count == 32 }
        XCTAssertEqual(collector.events.count, 32)
        XCTAssertEqual(collector.events.first?.deliveryID, "item-8")
        XCTAssertEqual(collector.events.last?.deliveryID, "item-39")
        await sdk.shutdown()
    }
    func testDisableSuppressesOwnedMetricsAndPreservesUnrelatedHostNotifications() async throws {
        let push = model(), collector = Collector(), sdk = try await makeSDK()
        push.onEvent = { collector.events.append($0) }
        await push.synchronize(optedOut: false, sdk: sdk)
        await push.disable()
        try await push.receive(payload(), interaction: .foreground)
        await push.receive(nil, interaction: .foreground)
        XCTAssertTrue(collector.events.isEmpty)
        await sdk.shutdown()
    }
}
@MainActor
private final class Collector { var events: [PushEvent] = [] }
