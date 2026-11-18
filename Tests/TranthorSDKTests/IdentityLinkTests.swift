import Foundation
import XCTest
@testable import TranthorSDK

/// identify(userId:) links the stored anonymousId and rotates it when a different user identifies.
@MainActor
final class IdentityLinkTests: XCTestCase {
    func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("tranthor-link-" + UUID().uuidString) }
    func config(_ root: URL) -> Configuration {
        Configuration(writeKey: "fixture", host: "http://127.0.0.1:1", batchSize: 100, flushIntervalMs: 60000,
                      storageNamespace: "identity-link", storageDirectory: root)
    }
    func queued(_ root: URL) throws -> [[String: JSONValue]] {
        var store = try JSONStore(directory: root, namespace: "identity-link")
        return try store.load().queued
    }

    func testFirstIdentifyAfterAnonymousUseCarriesTheStoredAnonymousId() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let sdk = try await TranthorSDK.configure(config(root))
        let anon = await sdk.anonymousId
        try await sdk.track(event: "anonymous")
        try await sdk.identify(userId: "user-1")
        try await sdk.identify(userId: "user-1")
        let after = await sdk.anonymousId
        XCTAssertEqual(after, anon)
        await sdk.shutdown()
        let q = try queued(root)
        XCTAssertEqual(q[0]["anonymousId"], .string(anon))
        for index in 1...2 {
            XCTAssertEqual(q[index]["userId"], "user-1")
            XCTAssertEqual(q[index]["anonymousId"], .string(anon))
        }
    }

    func testIdentifyWithADifferentUserRotatesBeforeSending() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let sdk = try await TranthorSDK.configure(config(root))
        let anon = await sdk.anonymousId
        try await sdk.identify(userId: "user-1")
        try await sdk.identify(userId: "user-2")
        let rotated = await sdk.anonymousId
        XCTAssertNotEqual(rotated, anon)
        XCTAssertNotNil(UUID(uuidString: rotated))
        await sdk.shutdown()
        let q = try queued(root)
        XCTAssertEqual(q[0]["anonymousId"], .string(anon))
        XCTAssertEqual(q[1]["userId"], "user-2")
        XCTAssertEqual(q[1]["anonymousId"], .string(rotated))
    }

    func testExplicitAnonymousIdWinsAndIsNotStored() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let sdk = try await TranthorSDK.configure(config(root))
        let anon = await sdk.anonymousId
        try await sdk.identify(userId: "user-1", anonymousId: "caller-1")
        let unchanged = await sdk.anonymousId
        XCTAssertEqual(unchanged, anon)
        try await sdk.identify(userId: "user-2", anonymousId: "caller-2")
        let rotated = await sdk.anonymousId
        XCTAssertNotEqual(rotated, anon)
        try await sdk.identify(userId: "user-2")
        await sdk.shutdown()
        let q = try queued(root)
        XCTAssertEqual(q[0]["anonymousId"], "caller-1")
        XCTAssertEqual(q[1]["anonymousId"], "caller-2")
        XCTAssertEqual(q[2]["anonymousId"], .string(rotated))
    }

    func testRotatedIdentityPersistsAcrossRestart() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try await TranthorSDK.configure(config(root))
        let anon = await first.anonymousId
        try await first.identify(userId: "user-1")
        try await first.identify(userId: "user-2")
        let rotated = await first.anonymousId
        await first.shutdown()
        XCTAssertNotEqual(rotated, anon)
        let second = try await TranthorSDK.configure(config(root))
        let restoredAnonymous = await second.anonymousId
        let restoredUser = await second.userId
        XCTAssertEqual(restoredAnonymous, rotated)
        XCTAssertEqual(restoredUser, "user-2")
        try await second.identify(userId: "user-2")
        let same = await second.anonymousId
        XCTAssertEqual(same, rotated)
        try await second.identify(userId: "user-1")
        let third = await second.anonymousId
        await second.shutdown()
        XCTAssertNotEqual(third, rotated)
        let q = try queued(root)
        XCTAssertEqual(q[2]["anonymousId"], .string(rotated))
        XCTAssertEqual(q[3]["anonymousId"], .string(third))
    }

    func testEmptyUserIdIsNotAUserAndDoesNotDefeatRotation() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let sdk = try await TranthorSDK.configure(config(root))
        try await sdk.identify(userId: "user-a")
        let linkedToA = await sdk.anonymousId
        try await sdk.identify(userId: "", traits: ["guest": true])
        let userAfterEmpty = await sdk.userId
        let anonymousAfterEmpty = await sdk.anonymousId
        XCTAssertEqual(userAfterEmpty, "user-a")
        XCTAssertEqual(anonymousAfterEmpty, linkedToA)
        try await sdk.identify(userId: "user-b")
        let rotated = await sdk.anonymousId
        let user = await sdk.userId
        XCTAssertNotEqual(rotated, linkedToA)
        XCTAssertEqual(user, "user-b")
        await sdk.shutdown()
        let q = try queued(root)
        // "" is not a user: the traits event falls back to the stored identity like identify(userId: nil).
        XCTAssertEqual(q[1]["userId"], "user-a")
        XCTAssertNil(q[1]["anonymousId"])
        XCTAssertEqual(q[2]["anonymousId"], .string(rotated))
    }

    func testRejectedIdentifyRestoresBothIds() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let sdk = try await TranthorSDK.configure(config(root))
        try await sdk.identify(userId: "user-1")
        let anon = await sdk.anonymousId
        do { try await sdk.identify(userId: "user-2", traits: ["bad": .number(.infinity)]); XCTFail("Expected serialization failure") } catch {}
        let user = await sdk.userId
        let after = await sdk.anonymousId
        XCTAssertEqual(user, "user-1")
        XCTAssertEqual(after, anon)
        await sdk.shutdown()
        let restored = try await TranthorSDK.configure(config(root))
        let restoredUser = await restored.userId
        let restoredAnonymous = await restored.anonymousId
        XCTAssertEqual(restoredUser, "user-1")
        XCTAssertEqual(restoredAnonymous, anon)
        await restored.shutdown()
    }

    func testEventsAfterIdentifyCarryOnlyTheStoredUserId() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let sdk = try await TranthorSDK.configure(config(root))
        try await sdk.identify(userId: "user-1")
        try await sdk.track(event: "after")
        try await sdk.screen(name: "Home")
        await sdk.shutdown()
        for event in try queued(root).dropFirst() {
            XCTAssertEqual(event["userId"], "user-1")
            XCTAssertNil(event["anonymousId"])
        }
    }
}
