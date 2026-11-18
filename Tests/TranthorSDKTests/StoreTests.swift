import Foundation
import XCTest
@testable import TranthorSDK

/// The on-disk state survives damage: identity, queue and consent are kept, and damaged files are quarantined, not overwritten.
@MainActor
final class StoreTests: XCTestCase {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("tranthor-store-" + UUID().uuidString)
    }
    private func consentURL(_ store: JSONStore) -> URL { store.url.deletingLastPathComponent().appendingPathComponent("consent.json") }
    private func corruptURL(_ store: JSONStore) -> URL { store.url.deletingLastPathComponent().appendingPathComponent("state.corrupt.json") }
    private func write(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)
    }

    /// A state file without `active` still restores identity, queue and consent.
    func testMissingActiveFieldPreservesIdentityQueueAndConsent() throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var store = try JSONStore(directory: root, namespace: "schema")
        let anonymous = UUID().uuidString
        let event: [String: Any] = ["type": "track", "event": "kept", "messageId": "stable-id", "timestamp": "stable-time", "userId": "u1"]
        try write(["version": 1, "anonymousId": anonymous, "userId": "u1", "optedOut": true, "queued": [event]], to: store.url)
        let restored = try store.load()
        XCTAssertTrue(restored.optedOut)
        XCTAssertEqual(restored.anonymousId, anonymous)
        XCTAssertEqual(restored.userId, "u1")
        XCTAssertEqual(restored.queued.count, 1)
        XCTAssertEqual(restored.queued.first?["messageId"], "stable-id")
        XCTAssertEqual(restored.queued.first?["timestamp"], "stable-time")
        XCTAssertFalse(FileManager.default.fileExists(atPath: corruptURL(store).path))
    }

    func testMissingFieldsUseDefaultsWithoutRegeneratingValidIdentity() throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var store = try JSONStore(directory: root, namespace: "defaults")
        let anonymous = UUID().uuidString
        try write(["version": 1, "anonymousId": anonymous], to: store.url)
        try write(["version": 1, "optedOut": false], to: consentURL(store))
        let restored = try store.load()
        XCTAssertEqual(restored.anonymousId, anonymous)
        XCTAssertNil(restored.userId)
        XCTAssertTrue(restored.queued.isEmpty)
        XCTAssertFalse(restored.optedOut)
        try store.save(restored.state)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [String: Any])
        XCTAssertEqual(encoded["version"] as? Int, 2)
    }

    /// A truncated state file is quarantined and consent fails closed.
    func testTruncatedStateFailsClosedAndIsQuarantined() throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var store = try JSONStore(directory: root, namespace: "truncated")
        var state = StoredState(); state.optedOut = true
        try store.save(state)
        let original = try Data(contentsOf: store.url)
        let truncated = Data(original.prefix(original.count / 2))
        try truncated.write(to: store.url)
        let restored = try store.load()
        XCTAssertTrue(restored.optedOut)
        XCTAssertNotNil(UUID(uuidString: restored.anonymousId))
        XCTAssertEqual(try Data(contentsOf: corruptURL(store)), truncated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
        try store.save(restored.state)
        XCTAssertEqual(try Data(contentsOf: corruptURL(store)), truncated)
        XCTAssertTrue(try store.load().optedOut)
    }

    func testMalformedQueueSalvagesIndependentIdentityAndFailsClosed() throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var store = try JSONStore(directory: root, namespace: "salvage")
        let anonymous = UUID().uuidString
        try write(["version": 1, "anonymousId": anonymous, "userId": "salvaged-user", "queued": "not-an-array"], to: store.url)
        try write(["version": 1, "optedOut": false], to: consentURL(store))
        let original = try Data(contentsOf: store.url)
        let restored = try store.load()
        XCTAssertFalse(restored.optedOut)
        XCTAssertEqual(restored.anonymousId, anonymous)
        XCTAssertEqual(restored.userId, "salvaged-user")
        XCTAssertTrue(restored.queued.isEmpty)
        XCTAssertEqual(try Data(contentsOf: corruptURL(store)), original)
    }

    func testExistingStateWithoutSeparateConsentFailsClosed() throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var store = try JSONStore(directory: root, namespace: "missing-consent")
        let state = StoredState()
        try store.save(state)
        let restored = try store.load()
        XCTAssertTrue(restored.optedOut)
        XCTAssertEqual(restored.anonymousId, state.anonymousId)
    }

    func testCorruptConsentFailsClosedAndIsNotOverwrittenByStateSave() throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var store = try JSONStore(directory: root, namespace: "corrupt-consent")
        try store.save(StoredState())
        let damaged = Data("{\"optedOut\":".utf8)
        try damaged.write(to: consentURL(store))
        XCTAssertTrue(try store.load().optedOut)
        try store.save(StoredState())
        XCTAssertEqual(try Data(contentsOf: consentURL(store).deletingLastPathComponent().appendingPathComponent("consent.corrupt.json")), damaged)
        XCTAssertTrue(try store.load().optedOut)
    }

    func testStateSaveDoesNotImplicitlyOptIn() throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var store = try JSONStore(directory: root, namespace: "independent-consent")
        try write(["version": 1, "optedOut": true], to: consentURL(store))
        let original = try Data(contentsOf: consentURL(store))
        try store.save(StoredState())
        XCTAssertEqual(try Data(contentsOf: consentURL(store)), original)
        XCTAssertTrue(try store.load().optedOut)
    }

    func testUnknownSchemaVersionIsQuarantinedAndFailsClosed() throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var store = try JSONStore(directory: root, namespace: "future-version")
        let anonymous = UUID().uuidString
        try write(["version": 999, "anonymousId": anonymous, "optedOut": false, "queued": [], "active": []], to: store.url)
        try write(["version": 1, "optedOut": false], to: consentURL(store))
        let restored = try store.load()
        XCTAssertTrue(restored.optedOut, "Downgrades must fail closed even with previously valid opt-in consent")
        XCTAssertEqual(restored.anonymousId, anonymous)
        XCTAssertTrue(FileManager.default.fileExists(atPath: corruptURL(store).path))
    }

    func testOnlyBrandNewStoreDefaultsOptedIn() throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var store = try JSONStore(directory: root, namespace: "new")
        XCTAssertFalse(try store.load().optedOut)
    }

    func testConsentOnlyHonouredAndQuarantineWithoutConsentFailsClosed() throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var store = try JSONStore(directory: root, namespace: "interrupted-repair")
        try write(["version": 1, "optedOut": false], to: consentURL(store))
        XCTAssertFalse(try store.load().optedOut)
        try FileManager.default.removeItem(at: consentURL(store))
        try Data("{damaged".utf8).write(to: corruptURL(store))
        XCTAssertTrue(try store.load().optedOut)
    }

    func testWrongShapeStateHonoursPersistedOptIn() throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var store = try JSONStore(directory: root, namespace: "wrong-shape")
        try write(["version": 1, "optedOut": false], to: consentURL(store))
        for damaged in ["not-json", "{}", "[]", "{\"queued\":[]}", "{\"anonymousId\":false}", "{\"anonymousId\":\"invalid\"}"] {
            let data = Data(damaged.utf8)
            try data.write(to: store.url)
            let restored = try store.load()
            XCTAssertFalse(restored.optedOut, damaged)
            XCTAssertNotNil(UUID(uuidString: restored.anonymousId))
            XCTAssertEqual(try Data(contentsOf: corruptURL(store)), data)
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
        }
    }

    func testLongNamespaceHasStableBoundedDistinctPath() throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let namespace = String(repeating: "a", count: 1_000)
        let first = try JSONStore(directory: root, namespace: namespace)
        let second = try JSONStore(directory: root, namespace: namespace)
        let distinct = try JSONStore(directory: root, namespace: namespace + "b")
        XCTAssertEqual(first.url, second.url)
        XCTAssertNotEqual(first.url, distinct.url)
        // Independently known SHA-256 vector for 1,000 ASCII 'a' bytes.
        XCTAssertEqual(first.url.deletingLastPathComponent().lastPathComponent, "sha256-41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
        try first.save(StoredState())
        XCTAssertLessThan(first.url.deletingLastPathComponent().lastPathComponent.utf8.count, 255)
        let folder = first.url.deletingLastPathComponent()
        XCTAssertEqual(try folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertEqual(try first.url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        // The queue folder and its event files carry the same protections as the state file.
        try first.append([QueuedEvent(sequence: 1, event: ["event": "kept"])])
        let queueFolder = folder.appendingPathComponent("queue", isDirectory: true)
        let eventFile = queueFolder.appendingPathComponent("00000000000000000001.json")
        XCTAssertEqual(try queueFolder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertEqual(try eventFile.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        #if os(iOS)
        for url in [first.url, queueFolder, eventFile] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let protection = (attributes[.protectionKey] as? FileProtectionType)?.rawValue ?? (attributes[.protectionKey] as? String)
            XCTAssertEqual(protection, FileProtectionType.completeUntilFirstUserAuthentication.rawValue, url.lastPathComponent)
        }
        #endif
    }

    func testExplicitOptInRecoversAfterCorruptionWithoutDestroyingEvidence() throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var store = try JSONStore(directory: root, namespace: "recovery")
        let damaged = Data("{damaged".utf8)
        try damaged.write(to: store.url)
        var restored = try store.load()
        XCTAssertTrue(restored.optedOut)
        // Mirror configure's explicit consent repair before normal state persistence.
        try store.saveConsent(restored.optedOut)
        try store.save(restored.state)
        XCTAssertTrue(try store.load().optedOut)
        try store.saveConsent(false)
        restored.optedOut = false
        try store.save(restored.state)
        XCTAssertFalse(try store.load().optedOut)
        XCTAssertEqual(try Data(contentsOf: corruptURL(store)), damaged)
    }
}
