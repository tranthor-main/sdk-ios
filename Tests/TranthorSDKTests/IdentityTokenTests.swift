import CryptoKit
import Foundation
import XCTest
@_spi(Testing) @testable import TranthorSDK

// MARK: - Fixtures

/// A JWT-shaped token. It is not signed: the SDK never verifies a token, it only reads `exp`.
private func jwt(_ label: String, exp: Double) -> String {
    func b64(_ text: String) -> String {
        Data(text.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    return b64(#"{"alg":"HS256","typ":"JWT"}"#) + "." + b64(#"{"sub":"\#(label)","exp":\#(Int(exp))}"#) + ".signature"
}

private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 1_800_000_000_000.0
    var ms: Double { lock.withLock { current } }
    func advance(seconds: Double) { lock.withLock { current += seconds * 1000 } }
    /// A token that expires `seconds` from the clock's now.
    func token(_ label: String, expiresIn seconds: Double) -> String { jwt(label, exp: (ms / 1000).rounded() + seconds) }
}

private actor Wire: SDKTransport {
    struct Sent { let batch: [[String: JSONValue]]; let tokens: [String] }
    private(set) var sent: [Sent] = []
    private var script: [Result<ResponseNotes, DeliveryFailure>]
    init(_ script: [Result<ResponseNotes, DeliveryFailure>] = []) { self.script = script }
    nonisolated func shutdown() {}
    func send(_ batch: [[String: JSONValue]]) async throws { _ = try await send(batch, identityTokens: []) }
    func send(_ batch: [[String: JSONValue]], identityTokens: [String]) async throws -> ResponseNotes {
        sent.append(Sent(batch: batch, tokens: identityTokens))
        switch script.isEmpty ? .success(ResponseNotes()) : script.removeFirst() {
        case .success(let notes): return notes
        case .failure(let failure): throw failure
        }
    }
}

private actor Sleeper {
    private struct Pending { let delay: Double; let continuation: CheckedContinuation<Void, any Error> }
    private var pending: [Int: Pending] = [:]
    private var next = 0
    private(set) var delays: [Double] = []
    func sleep(_ delay: Double) async throws {
        let id = next; next += 1
        delays.append(delay)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { pending[id] = Pending(delay: delay, continuation: $0) }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: Int) { pending.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError()) }
    /// Waits until a sleep of exactly `delay` is pending, then lets it finish.
    func fire(_ delay: Double) async throws {
        for _ in 0..<5000 {
            if let id = pending.first(where: { $0.value.delay == delay })?.key {
                pending.removeValue(forKey: id)?.continuation.resume()
                return
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("No pending sleep of \(delay) ms; saw \(waits)")
    }
    /// The delays other than the 1 h flush interval the tests configure and the 20 s provider timeout.
    var waits: [Double] { delays.filter { $0 != 3_600_000 && $0 != 20_000 } }
}

private final class Provider: @unchecked Sendable {
    enum Answer { case token(String), nothing, fail, hang }
    private let lock = NSLock()
    private var answers: [Answer]
    private var asked: [String] = []
    init(_ answers: [Answer]) { self.answers = answers }
    var calls: [String] { lock.withLock { asked } }
    func callAsFunction(_ user: String) async throws -> String? {
        let answer: Answer = lock.withLock { asked.append(user); return answers.isEmpty ? .nothing : answers.removeFirst() }
        switch answer {
        case .token(let token): return token
        case .nothing: return nil
        case .fail: throw URLError(.userAuthenticationRequired)
        // Ignores cancellation on purpose: the SDK must not wait for it.
        case .hang: await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }; return nil
        }
    }
}

private final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [BatchFailure] = []
    private var notes: [Notice] = []
    func add(_ failure: BatchFailure) { lock.withLock { failures.append(failure) } }
    func add(_ notice: Notice) { lock.withLock { notes.append(notice) } }
    var errors: [BatchFailure] { lock.withLock { failures } }
    var notices: [Notice] { lock.withLock { notes } }
}

private func refused(_ users: [String]? = nil, reason: String = "signature") -> DeliveryFailure {
    DeliveryFailure(status: 403, message: "HTTP delivery failure", code: "identity_not_verified", userIds: users, reason: reason)
}

// MARK: - exp decoding and the cache

final class IdentityTokenCacheTests: XCTestCase {
    private func payloadToken(_ json: String, padded: Bool = false, standardAlphabet: Bool = false) -> String {
        var body = Data(json.utf8).base64EncodedString()
        if !standardAlphabet { body = body.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_") }
        if !padded { body = body.replacingOccurrences(of: "=", with: "") }
        return "e30." + body + ".s"
    }
    func testReadsExpFromTheUnverifiedPayload() {
        XCTAssertEqual(decodeJwtExp(jwt("a", exp: 1_900_000_000)), 1_900_000_000)
        // A payload whose bytes need the url-safe alphabet (`-` and `_`) and has no padding.
        let json = #"{"sub":"???>>>~~~","exp":1900000001}"#
        XCTAssertTrue(Data(json.utf8).base64EncodedString().contains(where: { $0 == "+" || $0 == "/" }))
        XCTAssertEqual(decodeJwtExp(payloadToken(json)), 1_900_000_001)
        XCTAssertEqual(decodeJwtExp(payloadToken(#"{"exp":12.5}"#)), 12.5)
        XCTAssertEqual(decodeJwtExp("e30.eyJleHAiOjB9.x"), 0, "exp 0 is a real (long gone) expiry")
    }
    func testIgnoresTokensItCannotRead() {
        for token in ["", "abc", "a.b", "a.b.c.d", "a..c", "a.%%%.c", payloadToken("[1]"), payloadToken("{}"),
                      payloadToken(#"{"exp":"1900000000"}"#), payloadToken(#"{"exp":true}"#), payloadToken(#"{"exp":-1}"#),
                      payloadToken(#"{"exp":253402300800}"#), payloadToken(#"{"exp":190000000}"#, padded: true),
                      payloadToken(#"{"sub":"???>>>~~~","exp":1900000000}"#, standardAlphabet: true), payloadToken("not json")] {
            XCTAssertNil(decodeJwtExp(token), token)
        }
    }
    func testFreshnessUsesExpAndAnUnreadableTokenCountsAsValid() {
        var cache = IdentityTokenCache()
        let now = 1_800_000_000_000.0
        cache.set(jwt("a", exp: now / 1000 + 90), for: "a")
        cache.set("opaque-token", for: "b")
        XCTAssertNotNil(cache.fresh(for: "a", nowMs: now, minValidityMs: 60_000))
        XCTAssertNil(cache.fresh(for: "a", nowMs: now + 31_000, minValidityMs: 60_000), "less than 60 s left")
        XCTAssertNotNil(cache.fresh(for: "a", nowMs: now + 31_000, minValidityMs: 0))
        XCTAssertNil(cache.fresh(for: "a", nowMs: now + 91_000, minValidityMs: 0))
        XCTAssertNotNil(cache.fresh(for: "a", nowMs: now + 91_000, minValidityMs: -tokenGraceMs), "the server still accepts it shortly after it expires")
        XCTAssertNil(cache.fresh(for: "a", nowMs: now + 211_000, minValidityMs: -tokenGraceMs))
        XCTAssertEqual(cache.fresh(for: "b", nowMs: now + 9e12, minValidityMs: 60_000), "opaque-token")
        XCTAssertNil(cache.fresh(for: "c", nowMs: now, minValidityMs: 0), "a token is only returned for its own user")
    }
    func testRetainKeepsOnlyTheNamedUsersAndEmptyEntriesAreRefused() {
        var cache = IdentityTokenCache()
        cache.set("t1", for: "a"); cache.set("t2", for: "b"); cache.set("", for: "c"); cache.set("t3", for: "")
        XCTAssertEqual(cache.users, ["a", "b"])
        XCTAssertTrue(cache.retain(["b"]))
        XCTAssertFalse(cache.retain(["b"]))
        XCTAssertEqual(cache.users, ["b"])
    }
    func testIsStoredAsAPlainMapAndToleratesDamage() throws {
        var cache = IdentityTokenCache()
        cache.set("t1", for: "a")
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(cache), as: UTF8.self), #"{"a":"t1"}"#)
        XCTAssertEqual(try JSONDecoder().decode(IdentityTokenCache.self, from: Data(#"{"a":"t1","":"x","b":""}"#.utf8)).users, ["a"])
        XCTAssertThrowsError(try JSONDecoder().decode(IdentityTokenCache.self, from: Data("[1]".utf8)))
    }
    func testRequestCutAndTransportDetail() {
        let queue: [[String: JSONValue]] = (1...12).map { ["userId": .string("u\($0)")] }
        XCTAssertEqual(requestCut(queue, batchSize: 100), 10)
        XCTAssertEqual(requestCut(queue, batchSize: 4), 4)
        XCTAssertEqual(requestCut([["anonymousId": "x"], ["userId": "a"], ["anonymousId": "y"], ["userId": "a"]], batchSize: 100), 4)
        let body = Data(#"{"code":"identity_not_verified","reason":"expired","userIds":["a","b"],"message":"secret token inside"}"#.utf8)
        let detail = Transport.errorDetail(body, status: 403)
        XCTAssertEqual(detail.code, "identity_not_verified"); XCTAssertEqual(detail.reason, "expired"); XCTAssertEqual(detail.userIds, ["a", "b"])
        XCTAssertNil(Transport.errorDetail(body, status: 400).code, "only the two identity refusals are read")
        XCTAssertNil(Transport.errorDetail(Data("<html>".utf8), status: 403).code)
        XCTAssertEqual(retryAfter("120", capSeconds: 300), 120_000)
        XCTAssertEqual(retryAfter("9999", capSeconds: 300), 300_000)
        XCTAssertEqual(retryAfter("120"), 30_000, "the ordinary cap stays 30 s")
        XCTAssertEqual(Transport.retryAfterMs("0", identityUnavailable: true), 1_000, "a held batch waits at least a second")
        XCTAssertEqual(Transport.retryAfterMs(nil, identityUnavailable: true), 0, "absent: the hold uses its 30 s default")
        XCTAssertEqual(Transport.retryAfterMs("0", identityUnavailable: false), 0)
        XCTAssertEqual(Transport.retryAfterMs("400", identityUnavailable: true), 300_000)
    }
}

// MARK: - The SDK

@MainActor
final class IdentityTokenTests: XCTestCase {
    override func setUp() { super.setUp(); executionTimeAllowance = 20 }
    private func root() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("identity-" + UUID().uuidString)
        // The teardown block holds only the URL, so no main-actor state is touched from XCTest's nonisolated tearDown.
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func sdk(_ root: URL, _ wire: Wire, _ sleeper: Sleeper, _ clock: FakeClock, provider: Provider? = nil, reports: Reports = Reports(),
                     retries: Double = 5, batchSize: Double = 100,
                     write: @escaping @Sendable (Data, URL) throws -> Void = { try JSONStore.write($0, to: $1) }) async throws -> TranthorSDK {
        var call: (@Sendable (String) async throws -> String?)?
        if let provider { call = { @Sendable user in try await provider(user) } }
        let configuration = Configuration(writeKey: "fixture", batchSize: batchSize, flushIntervalMs: 3_600_000, retries: retries,
                                          automaticContext: false, storageDirectory: root, onError: { reports.add($0) },
                                          identityTokenProvider: call, appId: "com.example.app", onNotice: { reports.add($0) })
        return try await TranthorSDK(configuration: configuration, transport: wire, sleep: { try await sleeper.sleep($0) },
                                     storeWrite: write, now: { clock.ms })
    }
    private func tokens(_ root: URL) throws -> [String: String] { try loadState(directory: root, namespace: "default").identityTokens.tokens }
    private func flushFails(_ sdk: TranthorSDK) async -> DeliveryFailure? {
        do { try await sdk.flush(); return nil } catch { return error as? DeliveryFailure }
    }

    // Attaching

    func testTokenTravelsBesideTheEventsNeverInsideOneAndOnlyForItsUser() async throws {
        let root = root(), clock = FakeClock(), wire = Wire(), sleeper = Sleeper()
        let sdk = try await sdk(root, wire, sleeper, clock)
        let ta = clock.token("a", expiresIn: 3600), tb = clock.token("b", expiresIn: 3600)
        try await sdk.identify(userId: "a", identityToken: ta)
        try await sdk.identify(userId: "b", identityToken: tb)
        try await sdk.track(event: "late", userId: "a")
        try await sdk.track(event: "stranger", userId: "c")
        try await sdk.track(event: "anonymous", anonymousId: "anon")
        try await sdk.flush()
        let sent = await wire.sent
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].tokens, [ta, tb], "one per user, in the order the users first appear; none for c or anonymous")
        let wireText = String(decoding: try JSONEncoder().encode(sent[0].batch.map(JSONValue.object)), as: UTF8.self)
        XCTAssertFalse(wireText.contains(ta) || wireText.contains(tb))
        XCTAssertFalse(sent[0].batch.contains { $0["identityToken"] != nil })
        await sdk.shutdown()
    }
    func testTokenIsAttachedUntilTheServerWouldRefuseIt() async throws {
        let root = root(), clock = FakeClock(), wire = Wire(), sleeper = Sleeper()
        let provider = Provider([])
        let sdk = try await sdk(root, wire, sleeper, clock, provider: provider)
        let recent = clock.token("recent", expiresIn: -60)   // expired a minute ago: still accepted
        try await sdk.identify(userId: "recent", identityToken: recent)
        try await sdk.flush()
        var sent = await wire.sent
        XCTAssertEqual(sent[0].tokens, [recent])
        XCTAssertEqual(provider.calls, ["recent"], "it is renewed ahead of time, but the old one still goes when none comes")
        clock.advance(seconds: 61)   // now 121 s past exp, and the provider is backing off
        try await sdk.track(event: "x")
        try await sdk.flush()
        sent = await wire.sent
        XCTAssertEqual(sent[1].tokens, [], "long after it expired it is withheld")
        await sdk.shutdown()
    }

    // Eviction and persistence

    func testTokenIsKeptWhileItsUserIsCurrentOrHasEventsQueued() async throws {
        let root = root(), clock = FakeClock(), wire = Wire(), sleeper = Sleeper()
        let sdk = try await sdk(root, wire, sleeper, clock)
        try await sdk.identify(userId: "a", identityToken: clock.token("a", expiresIn: 3600))
        try await sdk.identify(userId: "b", identityToken: clock.token("b", expiresIn: 3600))
        XCTAssertEqual(try tokens(root).keys.sorted(), ["a", "b"], "a still has an event queued")
        try await sdk.flush()
        XCTAssertEqual(try tokens(root).keys.sorted(), ["b"], "a is evicted once sent; b is the current user")
        await sdk.shutdown()
    }
    func testResetKeepsTheOutgoingUsersTokenUntilTheirRemovalIsSent() async throws {
        let root = root(), clock = FakeClock(), wire = Wire(), sleeper = Sleeper()
        let sdk = try await sdk(root, wire, sleeper, clock)
        let ta = clock.token("a", expiresIn: 3600)
        try await sdk.identify(userId: "a", identityToken: ta)
        try await sdk.registerInstallation(token: "apns-token", appId: "com.example.app", environment: .development, permission: .granted)
        try await sdk.flush()
        try await sdk.reset()
        XCTAssertEqual(try tokens(root), ["a": ta], "the Installation Removed under a's identity is still queued")
        try await sdk.flush()
        let sent = await wire.sent
        let last = try XCTUnwrap(sent.last)
        XCTAssertEqual(last.batch.compactMap { $0["event"]?.string }, ["Installation Removed"])
        XCTAssertEqual(last.batch[0]["userId"]?.string, "a")
        XCTAssertEqual(last.tokens, [ta])
        XCTAssertTrue(try tokens(root).isEmpty, "evicted once their queued items are sent")
        await sdk.shutdown()
    }
    func testCacheIsWrittenWithTheQueueAndSurvivesARestart() async throws {
        let root = root(), clock = FakeClock(), sleeper = Sleeper()
        let writes = ProtectedWrites()
        let first = try await sdk(root, Wire(), sleeper, clock, write: { data, url in try writes.record(data, url) })
        let token = clock.token("a", expiresIn: 3600)
        try await first.identify(userId: "a", identityToken: token)
        await first.shutdown()
        // The token is in the state file, written by the same protected write as every queued event file.
        let carrying = writes.entries.filter { $0.text.contains(token) }
        XCTAssertFalse(carrying.isEmpty)
        for entry in carrying { XCTAssertEqual(entry.url.lastPathComponent, "state.json") }
        XCTAssertTrue(writes.entries.contains { $0.url.deletingLastPathComponent().lastPathComponent == "queue" && $0.text.contains("\"identify\"") },
                      "the event itself went through the same write")
        let folder = root.appendingPathComponent("sha256-" + "default".sha256Hex)
        var leaks: [String] = []
        for path in try FileManager.default.subpathsOfDirectory(atPath: folder.path) {
            let url = folder.appendingPathComponent(path)
            if (try? String(contentsOf: url, encoding: .utf8))?.contains(token) == true { leaks.append(url.lastPathComponent) }
        }
        XCTAssertEqual(leaks, ["state.json"], "no second place holds the token")
        let values = try folder.appendingPathComponent("state.json").resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        // After a restart the event goes out with the stored token.
        let wire = Wire()
        let second = try await sdk(root, wire, sleeper, clock)
        try await second.flush()
        let sent = await wire.sent
        XCTAssertEqual(sent.first?.tokens, [token])
        await second.shutdown()
    }
    func testStateWrittenBeforeIdentityTokensStillLoads() async throws {
        let root = root(), clock = FakeClock(), sleeper = Sleeper()
        let first = try await sdk(root, Wire(), sleeper, clock)
        try await first.identify(userId: "a", identityToken: clock.token("a", expiresIn: 3600))
        await first.shutdown()
        let file = root.appendingPathComponent("sha256-" + "default".sha256Hex).appendingPathComponent("state.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertNotNil(object.removeValue(forKey: "identityTokens"))
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        let second = try await sdk(root, Wire(), sleeper, clock)
        XCTAssertEqual(try loadState(directory: root, namespace: "default").queued.count, 1, "the queue is not quarantined")
        await second.shutdown()
    }

    // The provider

    func testAThrowingOrEmptyProviderNeverDelaysDelivery() async throws {
        for answer in [Provider.Answer.fail, .nothing] {
            let root = root(), clock = FakeClock(), wire = Wire(), sleeper = Sleeper()
            let provider = Provider([answer])
            let sdk = try await sdk(root, wire, sleeper, clock, provider: provider)
            try await sdk.identify(userId: "a")
            try await sdk.flush()   // no sleep is ever released: nothing waited for a timer
            let sent = await wire.sent
            XCTAssertEqual(sent.count, 1)
            XCTAssertEqual(sent[0].tokens, [])
            XCTAssertEqual(provider.calls, ["a"])
            await sdk.shutdown()
        }
    }
    func testAHangingProviderDelaysOneSendByTheTimeoutThenBacksOffForSixtySeconds() async throws {
        let root = root(), clock = FakeClock(), wire = Wire(), sleeper = Sleeper()
        let provider = Provider([.hang, .token("renewed")])
        let sdk = try await sdk(root, wire, sleeper, clock, provider: provider)
        try await sdk.identify(userId: "a")
        let flush = Task { try await sdk.flush() }
        try await sleeper.fire(20_000)   // the default timeout
        try await flush.value
        var sent = await wire.sent
        XCTAssertEqual(sent.count, 1, "the batch was sent anyway")
        XCTAssertEqual(sent[0].tokens, [])
        // Inside the backoff the provider is not asked again, so nothing waits.
        clock.advance(seconds: 59)
        try await sdk.track(event: "x"); try await sdk.flush()
        XCTAssertEqual(provider.calls, ["a"])
        clock.advance(seconds: 2)
        try await sdk.track(event: "y"); try await sdk.flush()
        XCTAssertEqual(provider.calls, ["a", "a"])
        sent = await wire.sent
        XCTAssertEqual(sent.last?.tokens, ["renewed"])
        await sdk.shutdown()
    }
    func testACancelledProviderWaitIsNotAProviderFailure() async throws {
        let root = root(), clock = FakeClock(), wire = Wire(), sleeper = Sleeper()
        let provider = Provider([.hang, .token("renewed")])
        let sdk = try await sdk(root, wire, sleeper, clock, provider: provider)
        try await sdk.identify(userId: "a")
        let flush = Task { try await sdk.flush() }
        for _ in 0..<5000 where provider.calls.isEmpty { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(provider.calls, ["a"])
        await sdk.pauseForBackgroundExpiry()   // cancels the delivery cycle while the provider is being waited for
        do { try await flush.value; XCTFail("A cancelled cycle rejects its flush") } catch {}
        await sdk.resumeOnForeground()
        try await sdk.flush()
        XCTAssertEqual(provider.calls, ["a", "a"], "no 60 s backoff: the provider did not fail")
        let sent = await wire.sent
        XCTAssertEqual(sent.last?.tokens, ["renewed"])
        await sdk.shutdown()
    }
    func testAnExpiringTokenIsRenewedBeforeTheSend() async throws {
        let root = root(), clock = FakeClock(), wire = Wire(), sleeper = Sleeper()
        let fresh = clock.token("a2", expiresIn: 3600)
        let provider = Provider([.token(fresh)])
        let sdk = try await sdk(root, wire, sleeper, clock, provider: provider)
        try await sdk.identify(userId: "a", identityToken: clock.token("a1", expiresIn: 30))
        try await sdk.flush()
        let sent = await wire.sent
        XCTAssertEqual(sent[0].tokens, [fresh])
        await sdk.shutdown()
    }

    // A refused identity token

    func testARefusedTokenIsRenewedAndTheSameBatchSentOnceMoreWithoutSpendingARetry() async throws {
        let root = root(), clock = FakeClock(), sleeper = Sleeper()
        let wire = Wire([.failure(refused(["a"]))])
        let renewed = clock.token("a2", expiresIn: 3600)
        let sdk = try await sdk(root, wire, sleeper, clock, provider: Provider([.token(renewed)]), retries: 0)
        try await sdk.identify(userId: "a", identityToken: clock.token("a1", expiresIn: 3600))
        try await sdk.flush()
        let sent = await wire.sent
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[1].tokens, [renewed])
        XCTAssertEqual(sent[0].batch.map { $0["messageId"] }, sent[1].batch.map { $0["messageId"] })
        await sdk.shutdown()
    }
    func testAPreviousUsersItemsAreDroppedAndReportedAndTheCurrentUsersAreSent() async throws {
        let root = root(), clock = FakeClock(), sleeper = Sleeper(), reports = Reports()
        let wire = Wire([.failure(refused(["a"], reason: "expired"))])
        let sdk = try await sdk(root, wire, sleeper, clock, provider: Provider([]), reports: reports)
        let ta = clock.token("a", expiresIn: 3600), tb = clock.token("b", expiresIn: 3600)
        try await sdk.identify(userId: "a", identityToken: ta)
        try await sdk.identify(userId: "b", identityToken: tb)
        try await sdk.flush()
        let sent = await wire.sent
        XCTAssertEqual(sent.map(\.tokens), [[ta, tb], [tb]])
        XCTAssertEqual(sent[1].batch.compactMap { $0["userId"]?.string }, ["b"])
        let errors = reports.errors
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors[0].error.status, 403); XCTAssertEqual(errors[0].error.message, "identity not verified")
        XCTAssertEqual(errors[0].attempts, 1)
        XCTAssertEqual(errors[0].events.compactMap { $0["userId"]?.string }, ["a"])
        XCTAssertFalse(String(describing: errors[0]).contains(ta), "a token is never in a report")
        // The dropped items are gone from disk too, so a restart does not bring them back.
        XCTAssertTrue(try loadState(directory: root, namespace: "default").queued.isEmpty)
        await sdk.shutdown()
    }
    func testWithoutAUsableTokenTheBatchIsHeldNotDroppedAndAFlushTriesAgain() async throws {
        let root = root(), clock = FakeClock(), sleeper = Sleeper(), reports = Reports()
        let wire = Wire([.failure(refused(["a"], reason: "missing")), .failure(refused(["a"], reason: "missing"))])
        let sdk = try await sdk(root, wire, sleeper, clock, provider: Provider([]), reports: reports)
        try await sdk.identify(userId: "a")
        let failure = await flushFails(sdk)
        XCTAssertEqual(failure?.status, 403)
        let held = try loadState(directory: root, namespace: "default").queued
        XCTAssertEqual(held.count, 1, "kept at the head with its stamps")
        XCTAssertTrue(reports.errors.isEmpty, "a hold is not a failure for good")
        XCTAssertEqual(reports.notices.map(\.kind), [.identityRefused]); XCTAssertEqual(reports.notices.first?.reason, "missing")
        let waits = await sleeper.waits
        XCTAssertEqual(waits, [60_000], "a hold lasts the provider backoff, 60 s by default")
        // An explicit flush ends the hold and tries at once.
        let again = await flushFails(sdk)
        XCTAssertEqual(again?.status, 403)
        let sent = await wire.sent
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[0].batch.first?["messageId"], sent[1].batch.first?["messageId"])
        // The third try is accepted.
        try await sdk.flush()
        XCTAssertTrue(try loadState(directory: root, namespace: "default").queued.isEmpty)
        await sdk.shutdown()
    }
    func testARenewedTokenThatIsRefusedAgainStopsRenewingAndSaysItIsTheSigningCode() async throws {
        let root = root(), clock = FakeClock(), sleeper = Sleeper(), reports = Reports()
        let wire = Wire([.failure(refused(["a"])), .failure(refused(["a"]))])
        let provider = Provider([.token(clock.token("a2", expiresIn: 3600))])
        let sdk = try await sdk(root, wire, sleeper, clock, provider: provider, reports: reports)
        try await sdk.identify(userId: "a", identityToken: clock.token("a1", expiresIn: 3600))
        let failure = await flushFails(sdk)
        XCTAssertEqual(failure?.reason, "signature")
        XCTAssertEqual(provider.calls, ["a"], "renewed once, not in a loop")
        let sent = await wire.sent
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(reports.notices.count, 1)
        XCTAssertEqual(reports.notices[0].reason, "signature")
        XCTAssertTrue(reports.notices[0].message.contains("signs tokens"))
        await sdk.shutdown()
    }
    func testOtherUsersAndAnonymousItemsAreSentFirstWhenTheCurrentUsersTokenCannotBeHad() async throws {
        let root = root(), clock = FakeClock(), sleeper = Sleeper(), reports = Reports()
        let wire = Wire([.failure(refused(["b"]))])
        let sdk = try await sdk(root, wire, sleeper, clock, provider: Provider([]), reports: reports)
        let ta = clock.token("a", expiresIn: 3600)
        try await sdk.identify(userId: "a", identityToken: ta)
        try await sdk.track(event: "anon", anonymousId: "anon")
        try await sdk.identify(userId: "b")
        let failure = await flushFails(sdk)
        XCTAssertEqual(failure?.status, 403)
        let sent = await wire.sent
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[1].batch.compactMap { $0["userId"]?.string ?? $0["anonymousId"]?.string }, ["a", "anon"], "one separate request")
        XCTAssertEqual(sent[1].tokens, [ta])
        let queued = try loadState(directory: root, namespace: "default").queued
        XCTAssertEqual(queued.compactMap { $0["userId"]?.string }, ["b"], "only the held user's items wait")
        await sdk.shutdown()
    }
    func testARefusalThatNamesNoUserIsNotRepostedInATightLoop() async throws {
        let root = root(), clock = FakeClock(), sleeper = Sleeper(), reports = Reports()
        let wire = Wire([.failure(refused()), .failure(refused()), .failure(refused())])
        let sdk = try await sdk(root, wire, sleeper, clock, reports: reports, retries: 1)
        try await sdk.track(event: "anon", anonymousId: "anon")
        let flush = Task { await flushFails(sdk) }
        try await sleeper.fire(500)   // the queue's normal backoff
        let failure = await flush.value
        XCTAssertEqual(failure?.status, 403)
        let sent = await wire.sent
        XCTAssertEqual(sent.count, 2, "the normal retry budget, then it stops")
        // As for any retryable failure the durable queue keeps the batch and the flush reports it; nothing is dropped.
        XCTAssertTrue(reports.errors.isEmpty)
        XCTAssertEqual(try loadState(directory: root, namespace: "default").queued.count, 1)
        XCTAssertEqual(reports.notices.map(\.kind), [.identityRefused, .identityRefused])
        await sdk.shutdown()
    }
    func testWriteKeyRefusalsStayTerminal() async throws {
        for code in ["write_key_app_not_allowed", "write_key_origin_not_allowed"] {
            let root = root(), clock = FakeClock(), sleeper = Sleeper(), reports = Reports()
            let wire = Wire([.failure(DeliveryFailure(status: 403, message: "x", code: code))])
            let sdk = try await sdk(root, wire, sleeper, clock, reports: reports)
            try await sdk.track(event: "x", userId: "a")
            let failure = await flushFails(sdk)
            XCTAssertEqual(failure?.code, code)
            XCTAssertEqual(reports.errors.count, 1)
            XCTAssertTrue(try loadState(directory: root, namespace: "default").queued.isEmpty, "dropped, as a configuration error")
            await sdk.shutdown()
        }
    }

    // Identity settings the server could not read

    func testAnIdentity503IsHeldForRetryAfterUpToFiveMinutesAndNeverSpendsARetry() async throws {
        let cases: [(Double, Double)] = [(120_000, 120_000), (400_000, 300_000), (0, 30_000), (200, 1_000)]
        for (retryAfter, expected) in cases {
            let root = root(), clock = FakeClock(), sleeper = Sleeper(), reports = Reports()
            let unavailable = DeliveryFailure(status: 503, message: "x", retryAfterMs: retryAfter, code: "identity_secrets_unavailable")
            let wire = Wire([.failure(unavailable)])
            let sdk = try await sdk(root, wire, sleeper, clock, reports: reports, retries: 0)
            try await sdk.track(event: "x", userId: "a")
            let failure = await flushFails(sdk)
            XCTAssertEqual(failure?.status, 503)
            let waits = await sleeper.waits
            XCTAssertEqual(waits, [expected], "Retry-After \(retryAfter)")
            XCTAssertEqual(try loadState(directory: root, namespace: "default").queued.count, 1)
            XCTAssertTrue(reports.errors.isEmpty)
            XCTAssertEqual(reports.notices.map(\.kind), [.identityUnavailable])
            await sdk.shutdown()
        }
    }

    // Batching and notices

    func testNoRequestCarriesMoreThanTenUsersWhenIdentityIsInUse() async throws {
        let clock = FakeClock()
        for (usingIdentity, expected) in [(true, [10, 1]), (false, [11])] {
            let root = root(), wire = Wire(), sleeper = Sleeper()
            let provider = usingIdentity ? Provider([]) : nil
            let sdk = try await sdk(root, wire, sleeper, clock, provider: provider)
            for index in 1...11 { try await sdk.track(event: "e", userId: "u\(index)") }
            try await sdk.flush()
            let sent = await wire.sent
            XCTAssertEqual(sent.map { distinctUsers($0.batch).count }, expected)
            await sdk.shutdown()
        }
    }
    func testDroppedAndUnverifiedCountsAreSurfacedAsNotices() async throws {
        let root = root(), clock = FakeClock(), sleeper = Sleeper(), reports = Reports()
        let wire = Wire([.success(ResponseNotes(status: 204, dropped: 2, unverified: 0)), .success(ResponseNotes(status: 204, dropped: 0, unverified: 3))])
        let sdk = try await sdk(root, wire, sleeper, clock, reports: reports)
        try await sdk.identify(userId: "a")
        try await sdk.registerInstallation(token: "apns-token", appId: "com.example.app", environment: .development, permission: .granted)
        try await sdk.flush()
        try await sdk.track(event: "x", userId: "a")
        try await sdk.flush()
        XCTAssertEqual(reports.notices.map(\.kind), [.eventsDropped, .eventsUnverified])
        XCTAssertEqual(reports.notices.map(\.count), [2, 3])
        XCTAssertTrue(reports.errors.isEmpty, "notices are not errors")
        XCTAssertFalse(reports.notices.contains { $0.message.contains("apns-token") || $0.message.contains("\"a\"") })
        await sdk.shutdown()
    }


    // Review fixes

    func testWithoutAProviderOrATokenAnUnverifiedRefusalStillEndsInAReportedDrop() async throws {
        let root = root(), clock = FakeClock(), sleeper = Sleeper(), reports = Reports()
        let wire = Wire([.failure(refused(["a"], reason: "missing"))])
        let sdk = try await sdk(root, wire, sleeper, clock, reports: reports)
        try await sdk.track(event: "x", userId: "a")
        let failure = await flushFails(sdk)
        XCTAssertEqual(failure?.status, 403)
        XCTAssertEqual(reports.errors.count, 1, "reported, as before identity tokens existed")
        XCTAssertTrue(try loadState(directory: root, namespace: "default").queued.isEmpty, "and dropped")
        let waits = await sleeper.waits
        XCTAssertTrue(waits.isEmpty, "no hold")
        await sdk.shutdown()
    }
    func testANewTokenEndsAHoldAtOnce() async throws {
        let root = root(), clock = FakeClock(), sleeper = Sleeper()
        let wire = Wire([.failure(refused(["a"], reason: "missing"))])
        let sdk = try await sdk(root, wire, sleeper, clock, provider: Provider([]))
        try await sdk.identify(userId: "a")
        _ = await flushFails(sdk)
        let waits = await sleeper.waits
        XCTAssertEqual(waits, [60_000])
        let fresh = clock.token("a", expiresIn: 3600)
        try await sdk.identify(userId: "a", identityToken: fresh)
        try await waitForRequests(wire, 2)
        let sent = await wire.sent
        XCTAssertEqual(try XCTUnwrap(sent.dropFirst().first).tokens, [fresh])
        await sdk.shutdown()
    }
    func testSwitchingUserEndsAHoldAtOnce() async throws {
        let root = root(), clock = FakeClock(), sleeper = Sleeper()
        let wire = Wire([.failure(refused(["a"], reason: "missing"))])
        let sdk = try await sdk(root, wire, sleeper, clock, provider: Provider([]))
        try await sdk.identify(userId: "a")
        _ = await flushFails(sdk)
        try await sdk.identify(userId: "b", identityToken: clock.token("b", expiresIn: 3600))
        try await waitForRequests(wire, 2)
        await sdk.shutdown()
    }
    func testOptOutRemovesTheCurrentUsersTokenOnceNothingNeedsIt() async throws {
        let root = root(), clock = FakeClock(), wire = Wire(), sleeper = Sleeper()
        let sdk = try await sdk(root, wire, sleeper, clock)
        try await sdk.identify(userId: "a", identityToken: clock.token("a", expiresIn: 3600))
        try await sdk.flush()
        XCTAssertEqual(try tokens(root).keys.sorted(), ["a"])
        try await sdk.optOut()
        XCTAssertTrue(try tokens(root).isEmpty, "gone from disk")
        await sdk.shutdown()
    }
    func testStaleTokensAreEvictedAtLaunchAndLongAfterTheyExpire() async throws {
        let root = root(), clock = FakeClock(), sleeper = Sleeper()
        let first = try await sdk(root, Wire(), sleeper, clock)
        try await first.identify(userId: "a", identityToken: clock.token("a", expiresIn: 10))
        try await first.flush()
        await first.shutdown()
        // A token left by an earlier run for a user with nothing queued.
        let file = root.appendingPathComponent("sha256-" + "default".sha256Hex).appendingPathComponent("state.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var stored = try XCTUnwrap(object["identityTokens"] as? [String: String])
        stored["ghost"] = clock.token("ghost", expiresIn: 3600)
        object["identityTokens"] = stored
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        clock.advance(seconds: 200)   // a's token expired long ago
        let second = try await sdk(root, Wire(), sleeper, clock)
        XCTAssertTrue(try tokens(root).isEmpty, "the ghost has no events and no user, and a's token expired long ago")
        await second.shutdown()
    }
    func testAPreviousUsersRemovalIsRetriedThroughTheProviderAndNeverDroppedForLackOfAToken() async throws {
        for supplies in [true, false] {
            let root = root(), clock = FakeClock(), sleeper = Sleeper(), reports = Reports()
            let wire = Wire([.success(ResponseNotes()), .failure(refused(["a"], reason: "expired"))])
            let renewed = clock.token("a2", expiresIn: 3600)
            let provider = Provider(supplies ? [.token(renewed)] : [.nothing])
            let sdk = try await sdk(root, wire, sleeper, clock, provider: provider, reports: reports)
            try await sdk.identify(userId: "a", identityToken: clock.token("a1", expiresIn: 3600))
            try await sdk.registerInstallation(token: "apns-token", appId: "com.example.app", environment: .development, permission: .granted)
            try await sdk.flush()
            try await sdk.reset()
            if supplies {
                try await sdk.flush()
                let sent = await wire.sent
                XCTAssertEqual(sent.count, 3, "refused, renewed, sent again")
                XCTAssertEqual(sent.dropFirst(2).first?.tokens, [renewed])
                XCTAssertTrue(reports.errors.isEmpty)
                XCTAssertTrue(try loadState(directory: root, namespace: "default").queued.isEmpty)
            } else {
                let failure = await flushFails(sdk)
                XCTAssertEqual(failure?.status, 403)
                XCTAssertEqual(try loadState(directory: root, namespace: "default").queued.compactMap { $0["event"]?.string }, ["Installation Removed"], "kept")
                XCTAssertTrue(reports.errors.isEmpty, "nothing was given up, so onError stays silent")
                XCTAssertEqual(reports.notices.map(\.kind), [.identityRefused], "each failed attempt is a notice")
                XCTAssertFalse(String(describing: reports.notices).contains("apns-token"), "the push token is not in the notice")
                let waits = await sleeper.waits
                XCTAssertEqual(waits, [60_000], "tried again after the hold")
                try await sleeper.fire(60_000)
                for _ in 0..<5000 where !(try loadState(directory: root, namespace: "default").queued.isEmpty) { try await Task.sleep(for: .milliseconds(1)) }
                XCTAssertTrue(try loadState(directory: root, namespace: "default").queued.isEmpty, "delivered after the hold")
            }
            await sdk.shutdown()
        }
    }
    func testAnOptOutRemovalIsNeverDroppedForLackOfATokenAndIsRetriedAfterTheHold() async throws {
        let root = root(), clock = FakeClock(), sleeper = Sleeper(), reports = Reports()
        let wire = Wire([.success(ResponseNotes()), .failure(refused(["a"], reason: "expired"))])
        let sdk = try await sdk(root, wire, sleeper, clock, provider: Provider([.nothing]), reports: reports)
        try await sdk.identify(userId: "a", identityToken: clock.token("a", expiresIn: 3600))
        try await sdk.registerInstallation(token: "apns-token", appId: "com.example.app", environment: .development, permission: .granted)
        try await sdk.flush()
        try await sdk.optOut()
        for _ in 0..<5000 where await sleeper.waits.isEmpty { try await Task.sleep(for: .milliseconds(1)) }
        let waits = await sleeper.waits
        XCTAssertEqual(waits, [60_000], "a held removal is tried again after the provider backoff")
        XCTAssertEqual(try loadState(directory: root, namespace: "default").pendingRemovals.count, 1, "kept")
        XCTAssertTrue(reports.errors.isEmpty, "nothing was given up, so onError stays silent")
        XCTAssertEqual(reports.notices.map(\.kind), [.identityRefused], "the failed attempt is a notice")
        try await sleeper.fire(60_000)
        for _ in 0..<5000 where !(try loadState(directory: root, namespace: "default").pendingRemovals.isEmpty) { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(try loadState(directory: root, namespace: "default").pendingRemovals.isEmpty, "delivered after the hold")
        await sdk.shutdown()
    }

    // Cross-SDK rules

    func testATokenOnceSuppliedKeepsIdentityInUseEvenAfterARefusalEmptiesTheCache() async throws {
        let root = root(), clock = FakeClock(), sleeper = Sleeper(), reports = Reports()
        let wire = Wire([.failure(refused(["a"], reason: "signature")), .failure(refused(["a"], reason: "missing"))])
        let sdk = try await sdk(root, wire, sleeper, clock, reports: reports)
        try await sdk.identify(userId: "a", identityToken: clock.token("a", expiresIn: 3600))
        _ = await flushFails(sdk)
        XCTAssertTrue(try tokens(root).isEmpty, "the refusal removed the cached token")
        XCTAssertEqual(try loadState(directory: root, namespace: "default").queued.count, 1, "held, not dropped")
        _ = await flushFails(sdk)
        XCTAssertEqual(try loadState(directory: root, namespace: "default").queued.count, 1, "still held on the second refusal")
        XCTAssertTrue(reports.errors.isEmpty)
        await sdk.shutdown()
        let file = root.appendingPathComponent("sha256-" + "default".sha256Hex).appendingPathComponent("state.json")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(object["identityTokenSupplied"] as? Bool, true, "remembered across launches")
    }
    func testSigningTheSameUserInAgainSupersedesAHeldRemoval() async throws {
        let root = root(), clock = FakeClock(), sleeper = Sleeper(), reports = Reports()
        let wire = Wire([.success(ResponseNotes()), .failure(refused(["a"], reason: "expired"))])
        let sdk = try await sdk(root, wire, sleeper, clock, provider: Provider([.nothing]), reports: reports)
        try await sdk.identify(userId: "a", identityToken: clock.token("a1", expiresIn: 3600))
        try await sdk.registerInstallation(token: "apns-token", appId: "com.example.app", environment: .development, permission: .granted)
        try await sdk.flush()
        try await sdk.reset()
        _ = await flushFails(sdk)
        XCTAssertEqual(try loadState(directory: root, namespace: "default").queued.compactMap { $0["event"]?.string }, ["Installation Removed"])
        try await sdk.identify(userId: "a", identityToken: clock.token("a2", expiresIn: 3600))
        try await waitForRequests(wire, 3)
        let sent = await wire.sent
        let last = try XCTUnwrap(sent.last)
        XCTAssertFalse(last.batch.contains { $0["event"]?.string == "Installation Removed" }, "the new registration supersedes the removal")
        XCTAssertTrue(last.batch.contains { $0["event"]?.string == "Installation Registered" })
        await sdk.shutdown()
    }
    func testWhileAHoldIsActiveTheQueueKeepsAtMostAThousandEventsAndReportsTheOldestDropped() async throws {
        let root = root(), clock = FakeClock(), sleeper = Sleeper(), reports = Reports()
        let wire = Wire([.failure(refused(["a"], reason: "missing"))])
        let sdk = try await sdk(root, wire, sleeper, clock, provider: Provider([]), reports: reports)
        try await sdk.identify(userId: "a")
        _ = await flushFails(sdk)
        for index in 0..<1100 { try await sdk.track(event: "e\(index)", userId: "a") }
        XCTAssertEqual(try loadState(directory: root, namespace: "default").queued.count, 1000)
        await sdk.shutdown()
        let dropped = reports.errors.filter { $0.attempts == 0 }.reduce(0) { $0 + $1.events.count }
        XCTAssertEqual(dropped, 101, "the oldest are reported with attempts 0")
    }

    // Review round: holds, removals and restarts

    func testAFailedIdentifyWriteLeavesTheHoldArmed() async throws {
        let root = root(), clock = FakeClock(), sleeper = Sleeper(), writes = FailingWrites()
        let wire = Wire([.failure(refused(["a"], reason: "missing"))])
        let sdk = try await sdk(root, wire, sleeper, clock, provider: Provider([]), write: { try writes.write($0, $1) })
        try await sdk.identify(userId: "a")
        _ = await flushFails(sdk)
        let armed = await sdk.held
        XCTAssertTrue(armed)
        writes.setFailing(true)
        do { try await sdk.identify(userId: "a", identityToken: clock.token("a", expiresIn: 3600)); XCTFail("the write fails") } catch {}
        let held = await sdk.held, task = await sdk.holdTask
        XCTAssertTrue(held, "a failed identify does not end the hold")
        XCTAssertNotNil(task, "so the held events keep their automatic retry")
        writes.setFailing(false)
        await sdk.shutdown()
    }
    func testAFailedWriteDoesNotMakeAUserCurrent() async throws {
        let root = root(), clock = FakeClock(), sleeper = Sleeper(), writes = FailingWrites()
        let sdk = try await sdk(root, Wire(), sleeper, clock, write: { try writes.write($0, $1) })
        writes.setFailing(true)
        do { try await sdk.track(event: "x", userId: "b"); XCTFail("the write fails") } catch {}
        let observed = await sdk.observedUser
        XCTAssertNil(observed, "no event was stored for b")
        writes.setFailing(false)
        await sdk.shutdown()
    }
    func testEndingAHoldRearmsAParkedRemoval() async throws {
        let root = root(), clock = FakeClock(), sleeper = Sleeper()
        let sdk = try await sdk(root, Wire(), sleeper, clock)
        await sdk.parkRemovalHold([["type": "track", "event": "Installation Removed", "messageId": "m1", "timestamp": "2026-11-01T00:00:00.000Z",
                                   "userId": "a", "properties": ["token": "t", "appId": "x"]]])
        await sdk.endHold()
        let parked = await sdk.removalIsParked
        XCTAssertFalse(parked, "the removal is no longer rejected with no timer left")
        let timer = await sdk.pendingTimer
        XCTAssertNotNil(timer, "and automatic delivery is armed again, as when the hold's own timer ends it")
        await sdk.shutdown()
    }
    private func removal(_ user: String, _ id: String) -> JSONValue {
        ["type": "track", "event": "Installation Removed", "messageId": .string(id), "timestamp": "2026-11-01T00:00:00.000Z",
         "userId": .string(user), "properties": ["token": .string("t-" + user), "appId": "com.example.app", "platform": "ios"]]
    }
    @discardableResult
    private func rewriteStateReturning(_ root: URL, _ change: (inout [String: Any]) -> Void) throws -> [String: Any] {
        let file = root.appendingPathComponent("sha256-" + "default".sha256Hex).appendingPathComponent("state.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        change(&object)
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        return object
    }
    private func rewriteState(_ root: URL, _ change: (inout [String: Any]) -> Void) throws {
        let folder = root.appendingPathComponent("sha256-" + "default".sha256Hex)
        let file = folder.appendingPathComponent("state.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        change(&object)
        try JSONSerialization.data(withJSONObject: object).write(to: file)
    }
    func testATransientFailureDoesNotDropAnotherUsersRemovalWhileAnotherIsHeld() async throws {
        let root = root(), clock = FakeClock(), sleeper = Sleeper(), reports = Reports()
        let first = try await sdk(root, Wire(), sleeper, clock)
        await first.shutdown()
        try rewriteState(root) { object in
            object["optedOut"] = true; object["userId"] = "a"; object["identityTokenSupplied"] = true
            object["pendingRemovals"] = [self.removal("a", "m-a"), self.removal("b", "m-b")].compactMap { try? JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }
        }
        try Data(#"{"version":1,"optedOut":true}"#.utf8).write(to: root.appendingPathComponent("sha256-" + "default".sha256Hex).appendingPathComponent("consent.json"))
        let serverDown = DeliveryFailure(status: 500, message: "down")
        let wire = Wire([.failure(refused(["a"], reason: "expired")), .failure(serverDown), .failure(serverDown), .failure(serverDown)])
        let sdk = try await sdk(root, wire, sleeper, clock, provider: Provider([.nothing]), reports: reports, retries: 0)
        for _ in 0..<5000 where !(await sdk.held) { try await Task.sleep(for: .milliseconds(1)) }
        let held = await sdk.held
        XCTAssertTrue(held)
        XCTAssertEqual(try loadState(directory: root, namespace: "default").pendingRemovals.compactMap { $0["messageId"]?.string }.sorted(), ["m-a", "m-b"],
                       "b's removal met a transient failure and is kept, not dropped")
        await sdk.shutdown()
    }
    func testARefusedEventIsHeldAfterARestartEvenWhenNobodyIdentified() async throws {
        let root = root(), clock = FakeClock(), sleeper = Sleeper(), reports = Reports()
        let first = try await sdk(root, Wire(), sleeper, clock, provider: Provider([]))
        try await first.track(event: "x", userId: "a")
        await first.shutdown()
        let wire = Wire([.failure(refused(["a"], reason: "missing"))])
        let sdk = try await sdk(root, wire, sleeper, clock, provider: Provider([]), reports: reports)
        let failure = await flushFails(sdk)
        XCTAssertEqual(failure?.status, 403)
        XCTAssertEqual(try loadState(directory: root, namespace: "default").queued.count, 1, "held, not dropped as a previous user's")
        XCTAssertTrue(reports.errors.isEmpty)
        await sdk.shutdown()
    }
    func testTheHeldLimitAlsoTrimsWhenTheHoldStarts() async throws {
        let root = root(), clock = FakeClock(), sleeper = Sleeper(), reports = Reports()
        let wire = Wire([.failure(refused(["a"], reason: "missing"))])
        let sdk = try await sdk(root, wire, sleeper, clock, provider: Provider([]), reports: reports, batchSize: 5000)
        for index in 0..<1500 { try await sdk.track(event: "e\(index)", userId: "a") }
        _ = await flushFails(sdk)
        XCTAssertEqual(try loadState(directory: root, namespace: "default").queued.count, 1000, "trimmed when the hold started")
        await sdk.shutdown()
        XCTAssertEqual(reports.errors.filter { $0.attempts == 0 }.reduce(0) { $0 + $1.events.count }, 500)
    }
    func testTheTokenFlagSurvivesASalvagedStateAndADamagedFlag() async throws {
        let root = root(), clock = FakeClock(), sleeper = Sleeper()
        let first = try await sdk(root, Wire(), sleeper, clock)
        try await first.identify(userId: "a", identityToken: clock.token("a", expiresIn: 3600))
        await first.shutdown()
        // Only the flag is damaged: the cache is still there, so identity is still in use.
        try rewriteState(root) { $0["identityTokenSupplied"] = "yes" }
        XCTAssertTrue(try loadState(directory: root, namespace: "default").identityTokenSupplied)
        // The whole file is damaged: the identity is salvaged, and so is the flag.
        try rewriteState(root) { $0["identityTokenSupplied"] = true; $0.removeValue(forKey: "version") }
        XCTAssertTrue(try loadState(directory: root, namespace: "default").identityTokenSupplied)
    }

    func testAfterAResetALaunchDoesNotMakeTheOutgoingUserCurrent() async throws {
        let root = root(), clock = FakeClock(), sleeper = Sleeper(), reports = Reports()
        let first = try await sdk(root, Wire(), sleeper, clock, provider: Provider([]))
        try await first.track(event: "x", userId: "a")
        try await first.reset()
        await first.shutdown()
        let wire = Wire([.failure(refused(["a"], reason: "missing"))])
        let sdk = try await sdk(root, wire, sleeper, clock, provider: Provider([]), reports: reports)
        _ = await flushFails(sdk)
        XCTAssertTrue(try loadState(directory: root, namespace: "default").queued.isEmpty, "a is not the current user after a reset, so a's event is a previous user's")
        XCTAssertEqual(reports.errors.count, 1)
        await sdk.shutdown()
    }
    func testIdentifyingThatEndsAHoldIsNotHeldToTheHeldLimit() async throws {
        let root = root(), clock = FakeClock(), sleeper = Sleeper(), reports = Reports()
        let wire = Wire([.failure(refused(["a"], reason: "missing"))])
        let sdk = try await sdk(root, wire, sleeper, clock, provider: Provider([]), reports: reports)
        try await sdk.identify(userId: "a")
        _ = await flushFails(sdk)
        for index in 0..<999 { try await sdk.track(event: "e\(index)", userId: "a") }
        try await sdk.identify(userId: "a", identityToken: clock.token("a", expiresIn: 3600))
        await sdk.shutdown()
        XCTAssertTrue(reports.errors.filter { $0.attempts == 0 }.isEmpty, "nothing was dropped for the held limit")
    }

    // Review: removals without identity in use, and a stale restart marker

    func testARemovalIsKeptWhenIdentityIsNotInUse() async throws {
        for useReset in [false, true] {
            let root = root(), clock = FakeClock(), sleeper = Sleeper(), reports = Reports()
            let wire = Wire([.success(ResponseNotes()), .failure(refused(["a"], reason: "missing"))])
            let sdk = try await sdk(root, wire, sleeper, clock, reports: reports)   // no provider, no token ever supplied
            try await sdk.identify(userId: "a")
            try await sdk.registerInstallation(token: "apns-token", appId: "com.example.app", environment: .development, permission: .granted)
            try await sdk.flush()
            if useReset { try await sdk.reset(); _ = await flushFails(sdk) } else { try await sdk.optOut() }
            for _ in 0..<5000 where !(await sdk.held) { try await Task.sleep(for: .milliseconds(1)) }
            let held = await sdk.held
            XCTAssertTrue(held, "a refused removal is parked, not dropped")
            XCTAssertTrue(reports.errors.isEmpty, "nothing was given up")
            XCTAssertEqual(reports.notices.map(\.kind), [.identityRefused])
            let state = try loadState(directory: root, namespace: "default")
            XCTAssertEqual(state.pendingRemovals.count + state.queued.filter { $0["event"]?.string == "Installation Removed" }.count, 1)
            // The server accepts it later.
            try await sleeper.fire(60_000)
            for _ in 0..<5000 {
                let current = try loadState(directory: root, namespace: "default")
                if current.pendingRemovals.isEmpty && current.queued.isEmpty { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            let after = try loadState(directory: root, namespace: "default")
            XCTAssertTrue(after.pendingRemovals.isEmpty && after.queued.isEmpty, "delivered once the server accepts it")
            await sdk.shutdown()
        }
    }
    func testTheRestartMarkerSurvivesADrainedQueueAndRelaunches() async throws {
        let root = root(), clock = FakeClock(), sleeper = Sleeper(), reports = Reports()
        let first = try await sdk(root, Wire(), sleeper, clock, provider: Provider([]))
        try await first.track(event: "x", userId: "a")
        try await first.reset()
        try await first.flush()   // the queue is empty
        await first.shutdown()
        let second = try await sdk(root, Wire(), sleeper, clock, provider: Provider([]))
        await second.shutdown()
        let third = try await sdk(root, Wire(), sleeper, clock, provider: Provider([]))
        try await third.track(event: "y", userId: "a")   // after the reset: a is the first user seen again
        await third.shutdown()
        let wire = Wire([.failure(refused(["a"], reason: "missing"))])
        let fourth = try await sdk(root, wire, sleeper, clock, provider: Provider([]), reports: reports)
        _ = await flushFails(fourth)
        XCTAssertEqual(try loadState(directory: root, namespace: "default").queued.count, 1, "held, not dropped as a previous user's")
        XCTAssertTrue(reports.errors.isEmpty)
        await fourth.shutdown()
    }
    func testASalvagedStateDoesNotMakeASignedOutUserCurrentAgain() async throws {
        let root = root(), clock = FakeClock(), sleeper = Sleeper(), reports = Reports()
        let first = try await sdk(root, Wire(), sleeper, clock, provider: Provider([]))
        try await first.track(event: "x", userId: "a")
        try await first.reset()
        await first.shutdown()
        try rewriteState(root) { $0.removeValue(forKey: "version") }   // damaged: salvaged
        let wire = Wire([.failure(refused(["a"], reason: "missing"))])
        let second = try await sdk(root, wire, sleeper, clock, provider: Provider([]), reports: reports)
        _ = await flushFails(second)
        XCTAssertTrue(try loadState(directory: root, namespace: "default").queued.isEmpty, "a signed out before the damage: their event is a previous user's")
        XCTAssertEqual(reports.errors.count, 1)
        await second.shutdown()
    }

    func testASalvagedStateTreatsEveryQueuedEventAsASignedOutUsersWhateverItsMarkerSaid() async throws {
        for value in [-1.0, 2.5, 7.0, 0.0] {
            // Each case needs its own state file: loading a damaged one sets it aside.
            let root = root(), clock = FakeClock(), sleeper = Sleeper()
            let first = try await sdk(root, Wire(), sleeper, clock)
            try await first.track(event: "x", userId: "a")
            try await first.track(event: "y", userId: "a")
            await first.shutdown()
            try rewriteState(root) { $0["userEpochSequence"] = value; $0.removeValue(forKey: "version") }
            let state = try loadState(directory: root, namespace: "default")
            XCTAssertEqual(state.userEpochSequence, 3, "marker \(value): the next queue number, so neither queued event can make a user current")
            XCTAssertEqual(state.queued.count, 2)
        }
    }
    func testASalvagedStateKeepsThePendingRemovalsAndTheInstallation() async throws {
        let root = root(), clock = FakeClock(), sleeper = Sleeper()
        // The removal's request fails, so the opt-out leaves it pending (its retry waits on the sleeper).
        let first = try await sdk(root, Wire([.success(ResponseNotes()), .failure(DeliveryFailure(status: 500, message: "down"))]), sleeper, clock)
        try await first.identify(userId: "a")
        try await first.registerInstallation(token: "apns-token", appId: "com.example.app", environment: .development, permission: .granted)
        try await first.flush()
        try await first.optOut()   // leaves a removal to deliver
        await first.shutdown()
        let before = try rewriteStateReturning(root) { $0.removeValue(forKey: "version") }
        XCTAssertEqual((before["pendingRemovals"] as? [Any])?.count, 1)
        let state = try loadState(directory: root, namespace: "default")
        XCTAssertEqual(state.pendingRemovals.count, 1, "the opt-out removal survives the salvage")
        XCTAssertEqual(state.installation?.token, "apns-token", "and so does the installation record")
    }
    func testWithoutIdentityOnlyTheRefusedUsersEventsAreDroppedAndTheRestIsSent() async throws {
        let root = root(), clock = FakeClock(), sleeper = Sleeper(), reports = Reports()
        let wire = Wire([.failure(refused(["a"], reason: "missing"))])
        let sdk = try await sdk(root, wire, sleeper, clock, reports: reports)   // no provider, no token ever supplied
        try await sdk.track(event: "mine", userId: "a")
        try await sdk.track(event: "other", userId: "b")
        try await sdk.track(event: "anon", anonymousId: "anon-1")
        let failure = await flushFails(sdk)
        XCTAssertEqual(failure?.status, 403, "events were given up, so an explicit flush says so")
        XCTAssertEqual(reports.errors.count, 1)
        XCTAssertEqual(reports.errors.first?.events.compactMap { $0["event"]?.string }, ["mine"], "only the refused user's event is dropped and reported")
        let sent = await wire.sent
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent.last?.batch.compactMap { $0["event"]?.string }, ["other", "anon"], "the rest goes out as usual")
        XCTAssertTrue(try loadState(directory: root, namespace: "default").queued.isEmpty)
        await sdk.shutdown()
    }

    func testWithoutIdentityARefusedPreviousUsersEventsAreDroppedAndTheFlushSaysSo() async throws {
        let root = root(), clock = FakeClock(), sleeper = Sleeper(), reports = Reports()
        let wire = Wire([.failure(refused(["a"], reason: "missing"))])
        let sdk = try await sdk(root, wire, sleeper, clock, reports: reports)   // no provider, no token ever supplied
        try await sdk.track(event: "mine", userId: "a")
        try await sdk.reset()                                   // a is now a previous user, and nobody is current
        try await sdk.track(event: "anon", anonymousId: "anon-1")
        let failure = await flushFails(sdk)
        XCTAssertEqual(failure?.status, 403, "events were given up, so an explicit flush says so")
        XCTAssertEqual(reports.errors.count, 1, "reported once")
        XCTAssertEqual(reports.errors.flatMap(\.events).compactMap { $0["event"]?.string }, ["mine"], "and nothing else was reported")
        let sent = await wire.sent
        XCTAssertEqual(sent.last?.batch.compactMap { $0["event"]?.string }, ["anon"])
        await sdk.shutdown()
    }
    func testAHeldQueueNeverTrimsARemovalAndOnlyOrdinaryEventsGoFirst() async throws {
        let root = root(), clock = FakeClock(), sleeper = Sleeper(), reports = Reports()
        let wire = Wire([.failure(refused(["a"], reason: "missing"))])
        let sdk = try await sdk(root, wire, sleeper, clock, provider: Provider([]), reports: reports)
        try await sdk.identify(userId: "a")
        _ = await flushFails(sdk)
        let removals: [[String: JSONValue]] = (0..<1100).map { index in
            ["type": "track", "event": "Installation Removed", "messageId": .string("m\(index)"), "timestamp": "2026-11-01T00:00:00.000Z",
             "userId": "a", "properties": ["token": .string("t\(index)"), "appId": "com.example.app"]]
        }
        try await sdk.admit(removals)
        XCTAssertEqual(try loadState(directory: root, namespace: "default").queued.map { $0["event"]?.string }.filter { $0 == "Installation Removed" }.count, 1100,
                       "no removal was trimmed, even above the limit")
        try await sdk.admit([removals[0].merging(["messageId": "extra"]) { $1 }])
        XCTAssertEqual(try loadState(directory: root, namespace: "default").queued.count, 1101, "only removals are left: nothing more to trim")
        await sdk.shutdown()
        let dropped = reports.errors.filter { $0.attempts == 0 }.flatMap(\.events)
        XCTAssertEqual(dropped.compactMap { $0["type"]?.string }, ["identify"], "only the ordinary event was trimmed")
    }
    func testAFailedWriteWhileHeldDropsNothing() async throws {
        let root = root(), clock = FakeClock(), sleeper = Sleeper(), reports = Reports(), writes = FailingWrites()
        let wire = Wire([.failure(refused(["a"], reason: "missing"))])
        let sdk = try await sdk(root, wire, sleeper, clock, provider: Provider([]), reports: reports, write: { try writes.write($0, $1) })
        try await sdk.identify(userId: "a")
        _ = await flushFails(sdk)
        for index in 0..<999 { try await sdk.track(event: "e\(index)", userId: "a") }
        writes.setFailing(true)
        do { try await sdk.track(event: "one-too-many", userId: "a"); XCTFail("the write fails") } catch {}
        writes.setFailing(false)
        XCTAssertEqual(try loadState(directory: root, namespace: "default").queued.count, 1000, "the failed write trimmed nothing")
        await sdk.shutdown()
        XCTAssertTrue(reports.errors.filter { $0.attempts == 0 }.isEmpty)
    }
    func testWithoutIdentityTheOrdinaryEventsAreDroppedAndReportedAndARemovalInTheBatchIsParked() async throws {
        let root = root(), clock = FakeClock(), sleeper = Sleeper(), reports = Reports()
        let wire = Wire([.success(ResponseNotes()), .failure(refused(["a"], reason: "missing"))])
        let sdk = try await sdk(root, wire, sleeper, clock, reports: reports)   // no provider, no token ever supplied
        try await sdk.identify(userId: "a")
        try await sdk.registerInstallation(token: "apns-token", appId: "com.example.app", environment: .development, permission: .granted)
        try await sdk.flush()
        try await sdk.reset()                                    // queues the removal for a
        try await sdk.track(event: "ordinary", userId: "a")      // a is the first user seen again
        let failure = await flushFails(sdk)
        XCTAssertEqual(failure?.status, 403)
        XCTAssertEqual(reports.errors.count, 1, "the ordinary event is reported once")
        XCTAssertEqual(reports.errors.first?.events.compactMap { $0["event"]?.string }, ["ordinary"])
        XCTAssertEqual(try loadState(directory: root, namespace: "default").queued.compactMap { $0["event"]?.string }, ["Installation Removed"], "the removal is parked")
        XCTAssertEqual(reports.notices.map(\.kind), [.identityRefused])
        try await sleeper.fire(60_000)
        for _ in 0..<5000 where !(try loadState(directory: root, namespace: "default").queued.isEmpty) { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(try loadState(directory: root, namespace: "default").queued.isEmpty, "delivered once the server accepts it")
        await sdk.shutdown()
    }
    private func waitForRequests(_ wire: Wire, _ count: Int) async throws {
        for _ in 0..<5000 {
            if await wire.sent.count >= count { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Expected \(count) requests, saw \(await wire.sent.count)")
    }

    // Configuration

    func testAppIdDefaultsToTheBundleIdentifier() {
        XCTAssertEqual(Configuration(writeKey: "k").appId, Bundle.main.bundleIdentifier)
        XCTAssertEqual(Configuration(writeKey: "k", appId: "com.example.app").appId, "com.example.app")
        XCTAssertEqual(Configuration(writeKey: "k", appId: "").appId, Bundle.main.bundleIdentifier)
        XCTAssertEqual(Configuration(writeKey: "k").identityProviderTimeoutMs, 20_000)
        XCTAssertEqual(Configuration(writeKey: "k").identityProviderBackoffMs, 60_000)
        var tuned = Configuration(writeKey: "k")
        tuned.identityProviderTimeoutMs = 400
        tuned.identityProviderBackoffMs = 1500
        XCTAssertEqual([tuned.identityProviderTimeoutMs, tuned.identityProviderBackoffMs], [400, 1500])
        tuned.identityProviderTimeoutMs = -1; tuned.identityProviderBackoffMs = .nan
        XCTAssertEqual([tuned.identityProviderTimeoutMs, tuned.identityProviderBackoffMs], [400, 1500], "an unusable value keeps the last one")
    }
}

private final class FailingWrites: @unchecked Sendable {
    private let lock = NSLock()
    private var failing = false
    func setFailing(_ value: Bool) { lock.withLock { failing = value } }
    func write(_ data: Data, _ url: URL) throws {
        if lock.withLock({ failing }) { throw CocoaError(.fileWriteOutOfSpace) }
        try JSONStore.write(data, to: url)
    }
}

extension TranthorSDK {
    /// Test hooks: put the SDK in the state a removal hold leaves behind.
    func parkRemovalHold(_ removals: [[String: JSONValue]]) {
        state.pendingRemovals = removals
        removalParked = DeliveryFailure(status: 403, message: "x", code: "identity_not_verified")
        startHold(60_000)
    }
    var removalIsParked: Bool { removalParked != nil }
}

private final class ProtectedWrites: @unchecked Sendable {
    struct Entry { let url: URL; let text: String }
    private let lock = NSLock()
    private var all: [Entry] = []
    var entries: [Entry] { lock.withLock { all } }
    func record(_ data: Data, _ url: URL) throws {
        try JSONStore.write(data, to: url)
        lock.withLock { all.append(Entry(url: url, text: String(decoding: data, as: UTF8.self))) }
    }
}

private extension String {
    /// The folder name the store gives a namespace.
    var sha256Hex: String { SHA256.hash(data: Data(utf8)).map { String(format: "%02x", $0) }.joined() }
}
