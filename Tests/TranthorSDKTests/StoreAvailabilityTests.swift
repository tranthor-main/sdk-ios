import Foundation
import XCTest
@testable import TranthorSDK

/// The store reports an unavailable disk as `storeTemporarilyUnavailable` and never overwrites state it could not read.
@MainActor
final class StoreAvailabilityTests: XCTestCase {
    override func setUp() { super.setUp(); executionTimeAllowance = 20 }
    private func assertUnavailable(_ error: any Error, code: CocoaError.Code? = nil, file: StaticString = #filePath, line: UInt = #line) {
        guard case let TranthorError.storeTemporarilyUnavailable(underlying) = error else {
            return XCTFail("Expected recoverable store error, got \(error)", file: file, line: line)
        }
        if let code { XCTAssertEqual((underlying as? CocoaError)?.code, code, file: file, line: line) }
    }
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("store-availability-" + UUID().uuidString) }
    private func configuration(_ root: URL) -> Configuration {
        Configuration(writeKey: "fixture", host: "http://127.0.0.1:1", batchSize: 1_000_000,
                      flushIntervalMs: 3_600_000, automaticContext: false, storageDirectory: root)
    }
    #if os(macOS)
    func testUnreadableStateThrowsTwiceWithoutQuarantineOrConsentChangesThenRecovers() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try await TranthorSDK.configure(configuration(root))
        try await first.identify(userId: "u1")
        for event in ["a", "b", "c"] { try await first.track(event: event) }
        let anonymous = await first.anonymousId; await first.shutdown()
        var store = try JSONStore(directory: root, namespace: "default")
        let original = try Data(contentsOf: store.url), consent = try Data(contentsOf: store.consentURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.url.path) }
        for _ in 0..<2 {
            do { let sdk = try await TranthorSDK.configure(configuration(root)); await sdk.shutdown(); XCTFail("Unreadable state must stop configure") }
            catch { assertUnavailable(error) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.corruptURL.path))
            XCTAssertEqual(try Data(contentsOf: store.consentURL), consent)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.url.path)
        XCTAssertEqual(try Data(contentsOf: store.url), original)
        let recovered = try await TranthorSDK.configure(configuration(root))
        let optedOut = await recovered.isOptedOut, restoredAnonymous = await recovered.anonymousId, user = await recovered.userId
        XCTAssertFalse(optedOut); XCTAssertEqual(restoredAnonymous, anonymous); XCTAssertEqual(user, "u1")
        await recovered.shutdown()
        XCTAssertEqual(try store.load().queued.compactMap { $0["event"]?.string }, ["a", "b", "c"])
    }
    func testUnwritableNamespaceConfigureThrowsRecoverableErrorThenPreservesConsentIdentityAndQueue() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try await TranthorSDK.configure(configuration(root))
        try await first.identify(userId: "u1"); try await first.track(event: "a")
        let anonymous = await first.anonymousId; await first.shutdown()
        var store = try JSONStore(directory: root, namespace: "default")
        let folder = store.url.deletingLastPathComponent()
        let stateBytes = try Data(contentsOf: store.url), consentBytes = try Data(contentsOf: store.consentURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        do {
            let sdk = try await TranthorSDK.configure(configuration(root)); await sdk.shutdown()
            XCTFail("Read-only namespace must fail configure")
        } catch { assertUnavailable(error, code: .fileWriteNoPermission) }
        XCTAssertEqual(try Data(contentsOf: store.url), stateBytes)
        XCTAssertEqual(try Data(contentsOf: store.consentURL), consentBytes)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let recovered = try await TranthorSDK.configure(configuration(root))
        let optedOut = await recovered.isOptedOut, identity = await recovered.anonymousId, user = await recovered.userId
        XCTAssertFalse(optedOut); XCTAssertEqual(identity, anonymous); XCTAssertEqual(user, "u1")
        await recovered.shutdown()
        XCTAssertEqual(try store.load().queued.compactMap { $0["event"]?.string }, ["a"])
    }
    func testUnreadableConsentDoesNotQuarantineDamagedStateOrOverwriteConsent() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try JSONStore(directory: root, namespace: "default")
        let damaged = Data("{broken".utf8); try damaged.write(to: store.url); try store.saveConsent(true)
        let consent = try Data(contentsOf: store.consentURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.consentURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.consentURL.path) }
        do { let sdk = try await TranthorSDK.configure(configuration(root)); await sdk.shutdown(); XCTFail("Unreadable consent must stop configure") }
        catch { assertUnavailable(error) }
        XCTAssertEqual(try Data(contentsOf: store.url), damaged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.corruptURL.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.consentURL.path)
        XCTAssertEqual(try Data(contentsOf: store.consentURL), consent)
    }
    #endif
    /// A state file without `version` is not trusted: it is set aside as state.corrupt.json and only its anonymous ID and
    /// user ID are kept. The queue, in-flight events, stored push token and pending removals are not restored (they stay in
    /// the set-aside file). Consent comes from the consent file, so an opted-in user stays opted in.
    func testStateWithoutVersionIsSetAsideAndOnlyTheIdentityIsKept() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try JSONStore(directory: root, namespace: "default")
        let anonymous = UUID().uuidString
        let object: [String: Any] = [
            "anonymousId": anonymous, "userId": "u1", "optedOut": false,
            "queued": [["type": "track", "event": "lost", "messageId": "m1", "timestamp": "t", "userId": "u1"]],
            "installation": ["token": "ab", "appId": "com.example.app", "environment": "production", "permission": "granted"]]
        let original = try JSONSerialization.data(withJSONObject: object)
        try original.write(to: store.url); try store.saveConsent(false)
        let sdk = try await TranthorSDK.configure(configuration(root))
        let restoredAnonymous = await sdk.anonymousId, user = await sdk.userId, optedOut = await sdk.isOptedOut
        XCTAssertEqual(restoredAnonymous, anonymous); XCTAssertEqual(user, "u1"); XCTAssertFalse(optedOut)
        await sdk.shutdown()
        XCTAssertEqual(try Data(contentsOf: store.corruptURL), original)
        var reread = try JSONStore(directory: root, namespace: "default")
        let state = try reread.load()
        XCTAssertTrue(state.queued.isEmpty, "The queued event is not restored")
        XCTAssertNil(state.installation, "The stored push token is not restored")
        XCTAssertEqual(state.userId, "u1")
    }
    func testAConsentFileThatCannotBeDecodedOptsTheUserOutAndIsSetAside() async throws {
        for damaged in ["{\"optedOut\":", "{\"version\":2,\"optedOut\":false}", "{\"version\":1}"] {
            let root = root(); defer { try? FileManager.default.removeItem(at: root) }
            let first = try await TranthorSDK.configure(configuration(root))
            let anonymous = await first.anonymousId
            await first.shutdown()
            let store = try JSONStore(directory: root, namespace: "default")
            try Data(damaged.utf8).write(to: store.consentURL)
            let sdk = try await TranthorSDK.configure(configuration(root))
            let optedOut = await sdk.isOptedOut, restoredAnonymous = await sdk.anonymousId
            XCTAssertTrue(optedOut, "\(damaged) must never read as opted in")
            XCTAssertEqual(restoredAnonymous, anonymous, "The identity is kept")
            try await sdk.track(event: "ignored")
            await sdk.shutdown()
            var reread = try JSONStore(directory: root, namespace: "default")
            XCTAssertTrue(try reread.load().queued.isEmpty)
            let aside = store.consentURL.deletingLastPathComponent().appendingPathComponent("consent.corrupt.json")
            XCTAssertEqual(try Data(contentsOf: aside), Data(damaged.utf8))
        }
    }
    func testDecodableConsentWinsOverGarbageStateForBothConsentValues() async throws {
        for optedOut in [false, true] {
            let root = root(); defer { try? FileManager.default.removeItem(at: root) }
            let store = try JSONStore(directory: root, namespace: "default")
            let damaged = Data("{broken".utf8); try damaged.write(to: store.url); try store.saveConsent(optedOut)
            let sdk = try await TranthorSDK.configure(configuration(root))
            let actual = await sdk.isOptedOut; XCTAssertEqual(actual, optedOut)
            await sdk.shutdown(); XCTAssertEqual(try Data(contentsOf: store.corruptURL), damaged)
        }
    }
    func testConsentOnlyCrashResidueHonoursBothConsentValues() async throws {
        for optedOut in [false, true] {
            let root = root(); defer { try? FileManager.default.removeItem(at: root) }
            var store = try JSONStore(directory: root, namespace: "default"); try store.saveConsent(optedOut)
            let sdk = try await TranthorSDK.configure(configuration(root))
            let actual = await sdk.isOptedOut; XCTAssertEqual(actual, optedOut)
            await sdk.shutdown(); XCTAssertEqual(try store.load().optedOut, optedOut)
        }
    }
    func testFailedQuarantineMoveThrowsAndCannotOverwriteOriginal() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        var store = try JSONStore(directory: root, namespace: "default", move: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        let damaged = Data("{broken".utf8); try damaged.write(to: store.url); try store.saveConsent(false)
        let consent = try Data(contentsOf: store.consentURL)
        XCTAssertThrowsError(try store.load()) { self.assertUnavailable($0) }
        XCTAssertThrowsError(try store.save(StoredState()))
        do {
            let sdk = try await TranthorSDK(configuration: configuration(root), transport: AvailabilityTransport(), sleep: sleepMilliseconds,
                                          storeMove: { _, _ in throw CocoaError(.fileWriteNoPermission) })
            await sdk.shutdown(); XCTFail("configure must stop when quarantine cannot move the original")
        } catch { assertUnavailable(error) }
        XCTAssertEqual(try Data(contentsOf: store.url), damaged)
        XCTAssertEqual(try Data(contentsOf: store.consentURL), consent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.corruptURL.path))
        // The failed initializer also releases its lease for the next successful recovery.
        let sdk = try await TranthorSDK.configure(configuration(root)); await sdk.shutdown()
    }
    func testFirstRunStateWriteFailureLeavesRecoverableConsentOnlyResidue() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        var store = try JSONStore(directory: root, namespace: "default")
        do {
            let sdk = try await TranthorSDK(configuration: configuration(root), transport: AvailabilityTransport(), sleep: sleepMilliseconds,
                storeWrite: { data, url in
                    if url.lastPathComponent == "state.json" { throw CocoaError(.fileWriteNoPermission) }
                    try data.write(to: url, options: .atomic)
                })
            await sdk.shutdown(); XCTFail("Injected first-run state write must fail configure")
        } catch { assertUnavailable(error, code: .fileWriteNoPermission) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.consentURL.path))
        XCTAssertFalse(try store.load().optedOut)
        let sdk = try await TranthorSDK.configure(configuration(root))
        let optedOut = await sdk.isOptedOut; XCTAssertFalse(optedOut); await sdk.shutdown()
    }
    func testInitialConsentAndStateWriteErrorsPreserveUnderlyingDiagnosticsAndReleaseLease() async throws {
        for filename in ["consent.json", "state.json"] {
            let root = root(); defer { try? FileManager.default.removeItem(at: root) }
            do {
                let sdk = try await TranthorSDK(configuration: configuration(root), transport: AvailabilityTransport(), sleep: sleepMilliseconds,
                    storeWrite: { data, url in
                        if url.lastPathComponent == filename { throw POSIXError(.ENOSPC) }
                        try JSONStore.write(data, to: url)
                    })
                await sdk.shutdown(); XCTFail("Full disk must fail configure")
            } catch {
                guard case let TranthorError.storeTemporarilyUnavailable(underlying) = error else {
                    XCTFail("Expected documented recoverable error"); continue
                }
                XCTAssertEqual((underlying as? POSIXError)?.code, .ENOSPC)
            }
            let sdk = try await TranthorSDK.configure(configuration(root)); await sdk.shutdown()
        }
    }
    func testFutureStateAndConsentFailClosedUntilExplicitOptIn() async throws {
        for filename in ["state.json", "consent.json"] {
            let root = root(); defer { try? FileManager.default.removeItem(at: root) }
            var store = try JSONStore(directory: root, namespace: "default")
            try store.save(StoredState()); try store.saveConsent(false)
            let url = filename == "state.json" ? store.url : store.consentURL
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            object["version"] = filename == "state.json" ? 3 : 2
            try JSONSerialization.data(withJSONObject: object).write(to: url)
            let sdk = try await TranthorSDK.configure(configuration(root))
            let optedOut = await sdk.isOptedOut; XCTAssertTrue(optedOut)
            try await sdk.optIn(); await sdk.shutdown()
            XCTAssertFalse(try store.load().optedOut)
        }
    }
    func testSavesReadAndVerifyStateOnlyOnceAtLoad() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let seed = try JSONStore(directory: root, namespace: "default")
        try seed.save(StoredState()); try seed.saveConsent(false)
        let (reads, continuation) = AsyncStream<URL>.makeStream()
        var store = try JSONStore(directory: root, namespace: "default", read: {
            continuation.yield($0); return try Data(contentsOf: $0)
        })
        var state = try store.load()
        for index in 0..<10 { state.userId = "u\(index)"; try store.save(state.state) }
        continuation.finish()
        var urls: [URL] = []; for await url in reads { urls.append(url) }
        XCTAssertEqual(urls.filter { $0 == store.url }.count, 1, "Single-writer saves must not re-read or re-decode state")
        XCTAssertEqual(urls.filter { $0 == store.consentURL }.count, 1)
    }
}
private struct AvailabilityTransport: SDKTransport {
    func send(_ batch: [[String: JSONValue]]) async throws {}
    func shutdown() {}
}
