import Foundation
import XCTest
@testable import TranthorPush
@testable import TranthorSDK

/// The last permission a bound TranthorPush read is the one the SDK ends up with, however registerDeviceToken and
/// refreshPermission interleave.
@MainActor
final class BoundPushStateTests: XCTestCase {
    private actor Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var open = false
        func wait() async { if open { return }; await withCheckedContinuation { waiters.append($0) } }
        func release() { open = true; waiters.forEach { $0.resume() }; waiters = [] }
    }
    private let token = Data([0xab, 0xcd])

    private func sdk(_ name: String, signedIn: Bool = false) async throws -> (TranthorSDK, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tranthor-bound-state-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let sdk = try await TranthorSDK.configure(Configuration(writeKey: "fixture", host: "http://127.0.0.1:1", batchSize: 100,
            flushIntervalMs: 3_600_000, storageNamespace: name, storageDirectory: root))
        if signedIn { try await sdk.identify(userId: "customer-1") } // A phone is registered only to an identified customer.
        return (sdk, root)
    }
    private func permissions(_ events: [[String: JSONValue]]) -> [String] {
        events.filter { $0["event"] == "Installation Registered" }.compactMap { $0["properties"]?["permissionState"]?.string }
    }

    func testTheLastPermissionReadWinsWhenTokenAndRefreshInterleave() async throws {
        let (sdk, root) = try await sdk("b6", signedIn: true)
        let gate = Gate(), calls = Counter()
        let push = try await TranthorPush(
            configuration: PushConfiguration(bundleIdentifier: "com.example.state", environment: .development), sdk: sdk,
            permission: {
                // The first read is slow and still says granted; the user then turns notifications off.
                if await calls.next() == 1 { await gate.wait(); return .granted }
                return .denied
            }, categoryStore: nil)
        let first = Task { try await push.registerDeviceToken(self.token) }
        try await Task.sleep(for: .milliseconds(100)) // The first call is inside permission().
        let second = Task { try await push.refreshPermission() }
        try await Task.sleep(for: .milliseconds(100))
        await gate.release()
        try await first.value; try await second.value
        await sdk.shutdown()
        var store = try JSONStore(directory: root, namespace: "b6")
        let events = try store.load().queued
        XCTAssertEqual(permissions(events).last, "denied", "A stale 'granted' must not be the last word")
        XCTAssertEqual(permissions(events), ["granted", "denied"], "Registered in the order the permission was read")
    }
    func testConcurrentRegistrationsNeverReorderAnInstallationRefresh() async throws {
        let (sdk, root) = try await sdk("b6-many", signedIn: true)
        let push = try await TranthorPush(
            configuration: PushConfiguration(bundleIdentifier: "com.example.state", environment: .development), sdk: sdk,
            permission: { .granted }, categoryStore: nil)
        try await push.registerDeviceToken(token)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 { group.addTask { try? await push.refreshPermission() } }
        }
        await sdk.shutdown()
        var store = try JSONStore(directory: root, namespace: "b6-many")
        XCTAssertEqual(permissions(try store.load().queued), ["granted"], "Same binding: sent once")
    }
    private actor Counter { var n = 0; func next() -> Int { n += 1; return n } }
}
