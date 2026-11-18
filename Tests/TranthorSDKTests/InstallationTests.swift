import Foundation
import XCTest
@testable import TranthorSDK

/// The SDK registers the push Installation through its own queue as `Installation Registered`/`Removed` events.
@MainActor
final class InstallationTests: XCTestCase {
    private actor Recorder: SDKTransport {
        var batches: [[[String: JSONValue]]] = []
        var script: [Int?] = []   // One entry per request: nil succeeds, a number fails with that HTTP status.
        func setScript(_ value: [Int?]) { script = value }
        nonisolated func shutdown() {}
        func send(_ batch: [[String: JSONValue]]) async throws {
            batches.append(batch)
            if !script.isEmpty, let status = script.removeFirst() { throw DeliveryFailure(status: status, message: "scripted") }
        }
        var events: [[String: JSONValue]] { batches.flatMap { $0 }.filter { !InstallationTests.isSignIn($0) } }
    }
    private let token = "00ab" + String(repeating: "cd", count: 30)

    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tranthor-install-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func config(_ root: URL, maxQueueSize: Int = 10_000, retries: Int = 2) -> Configuration {
        Configuration(writeKey: "fixture", host: "http://127.0.0.1:1", batchSize: 100, flushIntervalMs: 3_600_000, retries: retries,
                      baseDelay: 0, storageNamespace: "installation", storageDirectory: root, maxQueueSize: maxQueueSize)
    }
    /// A phone is registered only to an identified customer, so most tests start with one signed in. The sign-in's
    /// own identify event is left out of `queued` and `Recorder.events`. `signedIn: false` is the app before sign-in.
    nonisolated private static let customer = "customer-1"
    private func make(_ root: URL, _ transport: Recorder = Recorder(), maxQueueSize: Int = 10_000,
                      signedIn: Bool = true) async throws -> TranthorSDK {
        let sdk = try await TranthorSDK(configuration: config(root, maxQueueSize: maxQueueSize), transport: transport, sleep: sleepMilliseconds)
        if signedIn, await sdk.userId == nil, await !sdk.isOptedOut { try await sdk.identify(userId: Self.customer) }
        return sdk
    }
    nonisolated fileprivate static func isSignIn(_ event: [String: JSONValue]) -> Bool {
        event["type"] == "identify" && event["userId"] == .string(customer)
    }
    private func stored(_ root: URL) throws -> LoadedStore {
        var store = try JSONStore(directory: root, namespace: "installation")
        return try store.load()
    }
    private func queued(_ root: URL) throws -> [[String: JSONValue]] { try stored(root).queued.filter { !Self.isSignIn($0) } }
    private func register(_ sdk: TranthorSDK, token: String? = nil, permission: InstallationPermission = .granted,
                          environment: InstallationEnvironment = .development) async throws {
        try await sdk.registerInstallation(token: token ?? self.token, appId: "com.example.app", environment: environment, permission: permission)
    }
    private func names(_ events: [[String: JSONValue]]) -> [String] { events.map { $0["event"]?.string ?? "\($0["type"]?.string ?? "?")" } }
    private func eventually(_ what: String, _ check: () async -> Bool) async throws {
        for _ in 0..<500 { if await check() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Timed out waiting for \(what)")
    }
    private func item(_ events: [[String: JSONValue]], _ index: Int) throws -> [String: JSONValue] {
        try XCTUnwrap(events.indices.contains(index) ? events[index] : nil, "No event at index \(index) of \(events.count)")
    }
    private func time(_ event: [String: JSONValue]) -> String { event["timestamp"]?.string ?? "" }

    func testATokenForwardedBeforeSignInIsHeldAndRegisteredToTheCustomerAtIdentify() async throws {
        let root = directory(), sdk = try await make(root, signedIn: false)
        try await register(sdk, permission: .denied, environment: .production)
        // Nobody is signed in: a phone is registered only to an identified customer.
        XCTAssertEqual(names(try queued(root)), [])
        try await sdk.identify(userId: "user-1")
        await sdk.shutdown()
        let events = try queued(root).filter { $0["type"] == "track" }
        XCTAssertEqual(events.count, 1)
        let event = (try item(events, 0))
        XCTAssertEqual(event["type"], "track")
        XCTAssertEqual(event["event"], "Installation Registered")
        XCTAssertEqual(event["userId"], "user-1")
        XCTAssertFalse((event["messageId"]?.string ?? "").isEmpty)
        let properties = try XCTUnwrap(event["properties"]?.object)
        XCTAssertEqual(properties["platform"], "ios")
        XCTAssertEqual(properties["appId"], "com.example.app")
        XCTAssertEqual(properties["environment"], "production", "The wire key is `environment`, not `apnsEnvironment`")
        XCTAssertEqual(properties["token"], .string(token))
        XCTAssertEqual(properties["permissionState"], "denied")
        XCTAssertEqual(properties["sdkVersion"], .string(TranthorSDKVersion.current))
        let os = try XCTUnwrap(properties["osVersion"]?.string)
        XCTAssertTrue(os.split(separator: ".").count == 3, os)
        XCTAssertNil(properties["apnsEnvironment"])
    }
    func testRegisteredUsesTheStoredUserWhenIdentified() async throws {
        let root = directory(), sdk = try await make(root, signedIn: false)
        try await sdk.identify(userId: "user-1")
        try await register(sdk)
        await sdk.shutdown()
        let registered = try XCTUnwrap(queued(root).last)
        XCTAssertEqual(registered["userId"], "user-1")
    }
    func testSameBindingIsSentOncePerAppStartNotOnEveryCall() async throws {
        let root = directory(), sdk = try await make(root)
        try await register(sdk); try await register(sdk); try await register(sdk)
        await sdk.shutdown()
        XCTAssertEqual(names(try queued(root)), ["Installation Registered"])
        // A new process re-registers once: the server expires an Installation that is not re-registered for 90 days.
        let next = try await make(root)
        try await register(next); try await register(next)
        await next.shutdown()
        XCTAssertEqual(names(try queued(root)), ["Installation Registered", "Installation Registered"])
    }
    func testPermissionChangeReRegisters() async throws {
        let root = directory(), sdk = try await make(root)
        try await register(sdk, permission: .unknown)
        try await register(sdk, permission: .granted)
        try await register(sdk, permission: .granted)
        await sdk.shutdown()
        let events = try queued(root)
        XCTAssertEqual(events.compactMap { $0["properties"]?["permissionState"]?.string }, ["unknown", "granted"])
    }
    func testTokenChangeRemovesTheOldTokenThenRegistersTheNewOneInOrder() async throws {
        let root = directory(), sdk = try await make(root)
        try await register(sdk)
        try await register(sdk, token: "feed")
        await sdk.shutdown()
        let events = try queued(root)
        XCTAssertEqual(names(events), ["Installation Registered", "Installation Removed", "Installation Registered"])
        let removed = try XCTUnwrap((try item(events, 1))["properties"]?.object)
        XCTAssertEqual(removed["token"], .string(token))
        XCTAssertEqual(Set(removed.keys), ["platform", "appId", "environment", "token"],
                       "iOS removals need `environment` too: the server ignores an iOS event without it")
        XCTAssertEqual((try item(events, 2))["properties"]?["token"], "feed")
        let t = try (0..<3).map { time(try item(events, $0)) }
        XCTAssertTrue(t[0] < t[1] && t[1] < t[2], "Strictly increasing: the server orders a token's events by time")
    }
    func testEnvironmentChangeIsADifferentInstallation() async throws {
        let root = directory(), sdk = try await make(root)
        try await register(sdk, environment: .development)
        try await register(sdk, environment: .production)
        await sdk.shutdown()
        let events = try queued(root)
        XCTAssertEqual(names(events), ["Installation Registered", "Installation Removed", "Installation Registered"])
        XCTAssertEqual((try item(events, 1))["properties"]?["environment"], "development")
    }
    func testIdentifyRegistersTheHeldTokenToTheCustomerOnlyWhenTheIdentityChanges() async throws {
        let root = directory(), sdk = try await make(root, signedIn: false)
        try await register(sdk)
        try await sdk.identify(userId: "user-1")
        try await sdk.identify(userId: "user-1")
        await sdk.shutdown()
        let events = try queued(root)
        XCTAssertEqual(events.map { $0["event"]?.string ?? $0["type"]?.string ?? "" },
                       ["identify", "Installation Registered", "identify"])
        XCTAssertEqual((try item(events, 1))["userId"], "user-1")
    }
    func testResetRemovesUnderTheOutgoingCustomerAndDoesNotRegisterTheSignedOutPhone() async throws {
        let root = directory(), sdk = try await make(root, signedIn: false)
        try await sdk.identify(userId: "user-1")
        try await register(sdk)
        try await sdk.reset()
        // The once-per-app-start registration must not bring the signed-out phone back either.
        try await register(sdk)
        await sdk.shutdown()
        let events = try queued(root)
        XCTAssertEqual(names(events), ["identify", "Installation Registered", "Installation Removed"])
        XCTAssertEqual((try item(events, 2))["userId"], "user-1")
        let t = try [1, 2].map { time(try item(events, $0)) }
        XCTAssertTrue(t[0] < t[1])
    }
    func testIdentifyWithoutAUserIdDoesNotRegisterTheHeldToken() async throws {
        let root = directory(), sdk = try await make(root, signedIn: false)
        try await register(sdk)
        // Traits for a visitor, and an empty user id, sign nobody in.
        try await sdk.identify(traits: ["plan": "trial"])
        try await sdk.identify(userId: "")
        await sdk.shutdown()
        XCTAssertEqual(names(try queued(root)), ["identify", "identify"])
    }
    func testResetWhileNobodyIsSignedInSendsNoInstallationEvent() async throws {
        let root = directory(), sdk = try await make(root, signedIn: false)
        try await register(sdk)
        try await sdk.reset()
        await sdk.shutdown()
        XCTAssertEqual(names(try queued(root)), [])
    }
    func testResetWithoutAnInstallationSendsNothingExtra() async throws {
        let root = directory(), sdk = try await make(root)
        try await sdk.reset()
        await sdk.shutdown()
        XCTAssertEqual(try queued(root).count, 0)
    }
    func testInvalidInputIsIgnored() async throws {
        let root = directory(), sdk = try await make(root)
        try await sdk.registerInstallation(token: "", appId: "com.example.app", environment: .development, permission: .granted)
        try await sdk.registerInstallation(token: "aa", appId: "", environment: .development, permission: .granted)
        await sdk.shutdown()
        XCTAssertEqual(try queued(root).count, 0)
    }

    // MARK: Opt-out removal
    func testOptOutDeliversOneRemovalEvenThoughNothingElseIsSent() async throws {
        let root = directory(), transport = Recorder(), sdk = try await make(root, transport)
        try await register(sdk)
        try await sdk.track(event: "ordinary")
        try await sdk.optOut()
        try await eventually("the removal") { await transport.batches.count == 1 }
        let batch = await transport.batches.first ?? []
        XCTAssertEqual(names(batch), ["Installation Removed"], "The queue is discarded, only the removal is delivered")
        let removal = try item(batch, 0)
        XCTAssertEqual(Set(removal["properties"]?.object?.keys.map { $0 } ?? []), ["platform", "appId", "environment", "token"])
        XCTAssertNil(removal["context"], "No automatic context for an opted-out user")
        try await eventually("the removal to be cleared") { (try? self.stored(root).pendingRemovals.isEmpty) == true }
        try await sdk.track(event: "ignored while opted out")
        try await sdk.flush()
        let count = await transport.batches.count
        XCTAssertEqual(count, 1)
        await sdk.shutdown()
    }
    func testOptOutWhileNobodyIsSignedInSendsNoRemovalBecauseNoPhoneWasRegistered() async throws {
        let root = directory(), transport = Recorder(), sdk = try await make(root, transport, signedIn: false)
        try await register(sdk)
        try await sdk.optOut()
        try await Task.sleep(for: .milliseconds(100))
        await sdk.shutdown()
        let sent = await transport.events
        XCTAssertEqual(names(sent), [])
    }
    func testOptInWhileNobodyIsSignedInRegistersNothing() async throws {
        let root = directory(), transport = Recorder(), sdk = try await make(root, transport, signedIn: false)
        try await register(sdk)
        try await sdk.optOut()
        try await sdk.optIn()
        try await sdk.track(event: "Viewed")
        try await sdk.flush()
        await sdk.shutdown()
        let sent = await transport.events
        XCTAssertEqual(names(sent), ["Viewed"])
    }
    func testOptOutWithoutAnInstallationSendsNothing() async throws {
        let root = directory(), transport = Recorder(), sdk = try await make(root, transport)
        try await sdk.track(event: "ordinary")
        try await sdk.optOut()
        try await sdk.flush()
        try await Task.sleep(for: .milliseconds(50))
        let count = await transport.batches.count
        XCTAssertEqual(count, 0)
        await sdk.shutdown()
    }
    func testRegisteringWhileOptedOutStoresTheTokenAndOptInRegistersIt() async throws {
        let root = directory(), transport = Recorder(), sdk = try await make(root, transport)
        try await sdk.optOut()
        try await register(sdk)
        try await sdk.track(event: "ignored")
        XCTAssertEqual(try stored(root).queued.count, 0)
        try await sdk.optIn()
        await sdk.shutdown()
        XCTAssertEqual(names(try queued(root)), ["Installation Registered"])
        let count = await transport.batches.count
        XCTAssertEqual(count, 0)
    }
    func testRetryableFailureParksTheRemovalUntilATriggerAndTheQueueWaitsBehindIt() async throws {
        let root = directory(), transport = Recorder()
        await transport.setScript([503, 503, 503]) // retries: 2 -> three attempts exhaust one cycle.
        let sdk = try await make(root, transport)
        try await register(sdk)
        try await sdk.optOut()
        try await eventually("a full attempt cycle") { await transport.batches.count == 3 }
        try await Task.sleep(for: .milliseconds(100))
        var count = await transport.batches.count
        XCTAssertEqual(count, 3, "No timer and no background retry loop after the cycle ends")
        XCTAssertEqual(try stored(root).pendingRemovals.count, 1, "The removal is kept, durably")
        try await sdk.optIn() // A trigger: one new cycle. The registration queued by optIn waits behind the removal.
        try await eventually("removal then registration") { await transport.batches.count == 5 }
        count = await transport.batches.count
        XCTAssertEqual(count, 5)
        let events = await transport.events
        XCTAssertEqual(names(Array(events.suffix(2))), ["Installation Removed", "Installation Registered"])
        let t = try [3, 4].map { time(try item(events, $0)) }
        XCTAssertTrue(t[0] < t[1], "Registered is stamped after the removal, so the server ends active")
        await sdk.shutdown()
    }
    func testNonRetryableRejectionEndsTheRemovalForGood() async throws {
        let root = directory(), transport = Recorder()
        await transport.setScript([400])
        let sdk = try await make(root, transport)
        try await register(sdk)
        try await sdk.optOut()
        try await eventually("the rejected removal") { await transport.batches.count == 1 }
        try await eventually("cleared") { (try? self.stored(root).pendingRemovals.isEmpty) == true }
        await sdk.shutdown()
    }
    func testAPendingRemovalSurvivesRestartAndIsDeliveredAtStart() async throws {
        let root = directory(), transport = Recorder()
        await transport.setScript([503, 503, 503])
        let first = try await make(root, transport)
        try await register(first)
        try await first.optOut()
        try await eventually("a full attempt cycle") { await transport.batches.count == 3 }
        await first.shutdown()
        let second = Recorder()
        let restarted = try await make(root, second)
        try await eventually("the removal after restart") { await second.batches.count == 1 }
        let events = await second.events
        XCTAssertEqual(names(events), ["Installation Removed"])
        await restarted.shutdown()
    }
    func testAnotherOptOutRetriesTheSameRemovalAndOptOutAfterOptInReissuesIt() async throws {
        let root = directory(), transport = Recorder()
        await transport.setScript([503, 503, 503, 503, 503, 503])
        let sdk = try await make(root, transport)
        try await register(sdk)
        try await sdk.optOut()
        try await eventually("a full attempt cycle") { await transport.batches.count == 3 }
        try await sdk.optIn() // A trigger: three more failed attempts of the same removal.
        try await eventually("a second attempt cycle") { await transport.batches.count == 6 }
        var ids = Set((await transport.events).compactMap { $0["messageId"]?.string })
        XCTAssertEqual(ids.count, 1, "Six attempts of one removal share one messageId; the opt-in registration waits behind it, unsent")
        try await sdk.optOut() // The removal is still undelivered: reissued once, with a new id, to one token.
        try await eventually("the reissued removal") { await transport.batches.count == 7 }
        let events = await transport.events
        XCTAssertEqual(names(Array(events.suffix(1))), ["Installation Removed"])
        ids = Set(events.filter { $0["event"] == "Installation Removed" }.compactMap { $0["messageId"]?.string })
        XCTAssertEqual(ids.count, 2)
        await sdk.shutdown()
    }

    // MARK: The host's onError never receives the push token
    private final class Failures: @unchecked Sendable {
        private let lock = NSLock(); private var items: [BatchFailure] = []
        func add(_ f: BatchFailure) { lock.lock(); items.append(f); lock.unlock() }
        var all: [BatchFailure] { lock.lock(); defer { lock.unlock() }; return items }
    }
    private func makeReporting(_ root: URL, _ transport: Recorder, _ failures: Failures, maxQueueSize: Int = 10_000) async throws -> TranthorSDK {
        var configuration = config(root, maxQueueSize: maxQueueSize)
        configuration = Configuration(writeKey: "fixture", host: "http://127.0.0.1:1", batchSize: 100, flushIntervalMs: 3_600_000, retries: 2,
                                      baseDelay: 0, storageNamespace: "installation", storageDirectory: root, maxQueueSize: maxQueueSize,
                                      onError: { failures.add($0) })
        let sdk = try await TranthorSDK(configuration: configuration, transport: transport, sleep: sleepMilliseconds)
        try await sdk.identify(userId: Self.customer)
        return sdk
    }
    private func tokens(_ events: [[String: JSONValue]]) -> [String] { events.compactMap { $0["properties"]?["token"]?.string } }

    func testATerminalFailureReportsInstallationEventsWithoutTheTokenButSendsItToTheServer() async throws {
        let root = directory(), transport = Recorder(), failures = Failures()
        await transport.setScript([400])
        let sdk = try await makeReporting(root, transport, failures)
        try await register(sdk)
        try await sdk.track(event: "ordinary", properties: ["token": "keep-me"])
        do { try await sdk.flush(); XCTFail("Expected a rejection") } catch {}
        let sent = await transport.events
        XCTAssertEqual(tokens(sent).first, token, "The server still gets the real token")
        let reported = try XCTUnwrap(failures.all.first).events
        let installation = try XCTUnwrap(reported.first { $0["event"] == "Installation Registered" })
        XCTAssertEqual(installation["properties"]?["token"], "<redacted>")
        XCTAssertEqual(installation["properties"]?["appId"], "com.example.app", "Only the token is redacted")
        XCTAssertEqual(installation["messageId"], try item(sent, 0)["messageId"], "type, messageId and the rest are intact")
        XCTAssertEqual(reported.first { $0["event"] == "ordinary" }?["properties"]?["token"], "keep-me", "Ordinary events are untouched")
        XCTAssertFalse(tokens(reported).contains(token))
        await sdk.shutdown()
    }
    func testARejectedOptOutRemovalAndDroppedInstallationEventsAreReportedWithoutTheToken() async throws {
        let root = directory(), transport = Recorder(), failures = Failures()
        await transport.setScript([400])
        let sdk = try await makeReporting(root, transport, failures)
        try await register(sdk)
        try await sdk.optOut()
        try await eventually("the rejected removal") { failures.all.count == 1 }
        let removal = try XCTUnwrap(failures.all.first?.events.first)
        XCTAssertEqual(removal["event"], "Installation Removed")
        XCTAssertEqual(removal["properties"]?["token"], "<redacted>")
        await sdk.shutdown()
        // Overflow: the dropped events go to onError too.
        let other = directory(), dropped = Failures()
        let small = try await makeReporting(other, Recorder(), dropped, maxQueueSize: 1)
        try await register(small)
        try await register(small, token: "feed")
        try await small.flush()
        XCTAssertFalse(dropped.all.isEmpty)
        for failure in dropped.all {
            XCTAssertFalse(tokens(failure.events).contains(token), "Dropped events are reported without the token")
            XCTAssertFalse(tokens(failure.events).contains("feed"))
        }
        await small.shutdown()
    }

    // MARK: Interrupted opt-out
    func testAnOptOutInterruptedBetweenTheConsentAndStateWritesStillLeavesItsRemoval() async throws {
        let root = directory()
        let first = try await make(root)
        try await register(first)
        await first.shutdown()
        // optOut() writes consent first, then state. A crash between them leaves consent "out" and state "in".
        var store = try JSONStore(directory: root, namespace: "installation")
        _ = try store.load()
        try store.saveConsent(true)
        let transport = Recorder(), restarted = try await make(root, transport)
        let isOptedOut = await restarted.isOptedOut
        XCTAssertTrue(isOptedOut)
        try await eventually("the removal at app start") { await transport.batches.count == 1 }
        let events = await transport.events
        XCTAssertEqual(names(events), ["Installation Removed"], "The queued registration is discarded; the server must end up removed")
        XCTAssertEqual(Set(events.first?["properties"]?.object?.keys.map { $0 } ?? []), ["platform", "appId", "environment", "token"])
        XCTAssertEqual(events.first?["properties"]?["token"], .string(token))
        XCTAssertNil(events.first?["context"])
        try await eventually("cleared") { (try? self.stored(root).pendingRemovals.isEmpty) == true }
        await restarted.shutdown()
    }
    func testANormalRestartSendsNoRemoval() async throws {
        let root = directory()
        let first = try await make(root)
        try await register(first)
        await first.shutdown()
        let transport = Recorder(), restarted = try await make(root, transport)
        try await Task.sleep(for: .milliseconds(150))
        let count = await transport.batches.count
        XCTAssertEqual(count, 0)
        await restarted.shutdown()
        XCTAssertEqual(try stored(root).pendingRemovals.count, 0)
    }
    func testACompletedOptOutIsNotRemovedAgainAtTheNextStart() async throws {
        let root = directory(), transport = Recorder()
        let first = try await make(root, transport)
        try await register(first)
        try await first.optOut()
        try await eventually("the removal") { await transport.batches.count == 1 }
        try await eventually("cleared") { (try? self.stored(root).pendingRemovals.isEmpty) == true }
        await first.shutdown()
        let second = Recorder(), restarted = try await make(root, second)
        try await Task.sleep(for: .milliseconds(150))
        let count = await second.batches.count
        XCTAssertEqual(count, 0)
        await restarted.shutdown()
    }

    // MARK: Queue overflow
    func testOverflowDropsOrdinaryEventsBeforeAnInstallationEvent() async throws {
        let root = directory(), sdk = try await make(root, maxQueueSize: 3)
        try await register(sdk)
        for index in 0..<4 { try await sdk.track(event: "ordinary-\(index)") }
        await sdk.shutdown()
        let events = try queued(root)
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events.first?["event"], "Installation Registered")
        XCTAssertEqual(names(events), ["Installation Registered", "ordinary-2", "ordinary-3"])
    }
}
