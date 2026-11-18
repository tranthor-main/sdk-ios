import Foundation
import XCTest
import TranthorSDK
import TranthorPush
#if SWIFT_PACKAGE
@testable import ExampleModelSupport
#else
@testable import TranthorExample
#endif

@MainActor
final class ExampleModelTests: XCTestCase {
    override func setUp() { super.setUp(); executionTimeAllowance = 15 }
    func testSlowFlushPersistsAndReconfiguresWithoutSavingLaunchKey() async {
        let fixture = Fixture()
        let model = fixture.model(environment: ["TRANTHOR_WRITE_KEY": "fixture-launch", "TRANTHOR_FLUSH_INTERVAL_MS": "60000"])
        await model.configure()
        XCTAssertEqual(fixture.configurations.last?.flushIntervalMs, 60000)
        XCTAssertTrue(model.slowFlush)
        await model.setSlowFlush(false)
        XCTAssertEqual(fixture.configurations.last?.flushIntervalMs, 500)
        XCTAssertEqual(fixture.savedSlowFlush, [false])
        XCTAssertTrue(fixture.savedKeys.isEmpty)
        XCTAssertTrue(model.lines.contains { $0.contains("Reconnect auto-flush is disabled") })
    }
    func testForgetKeyDeletesSavedItemClearsFieldAndShutsDownClient() async {
        let fixture = Fixture(); let model = fixture.model()
        model.editKey("fixture-key"); await model.configure()
        model.enteredUserId = "fixture-user"; await model.identify(); await model.flush()
        let failure = BatchFailure(error: DeliveryFailure(status: 503, message: "fixture"), events: [], attempts: 1)
        fixture.configurations[0].onError?(failure)
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while model.errors.isEmpty, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertFalse(model.errors.isEmpty); XCTAssertEqual(model.lastFlush, "Succeeded")
        await model.forgetKey()
        fixture.configurations[0].onError?(failure)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(fixture.deletedKeys, 1)
        XCTAssertEqual(fixture.clients[0].shutdownCount, 1)
        XCTAssertEqual(model.writeKey, "")
        XCTAssertFalse(model.configured)
        XCTAssertEqual(model.anonymousId, "Not configured"); XCTAssertEqual(model.userId, "Anonymous")
        XCTAssertEqual(model.lastFlush, "Not requested"); XCTAssertTrue(model.errors.isEmpty)
    }
    func testForgetKeyAlsoDisablesOptionalPushCollection() async {
        let fixture = Fixture(), push = ExamplePushModel(bundleIdentifier: "com.example.tests")
        let model = fixture.model()
        model.attachPush(push)
        model.editKey("fixture-key")
        await model.configure()
        XCTAssertTrue(push.enabled)
        await model.forgetKey()
        XCTAssertFalse(push.enabled, "Forgetting credentials must disable the attached push client too")
    }
    func testCustomLaunchFlushIntervalIsDisplayedAsSlowAndToggleRestoresNormalInterval() async {
        let fixture = Fixture()
        let model = fixture.model(environment: ["TRANTHOR_FLUSH_INTERVAL_MS": "12000"])
        XCTAssertTrue(model.slowFlush); XCTAssertEqual(model.flushIntervalMs, 12000)
        XCTAssertEqual(model.flushIntervalText, "Flush interval: 12000 ms")
        await model.setSlowFlush(false)
        XCTAssertFalse(model.slowFlush); XCTAssertEqual(model.flushIntervalMs, 500)
    }
    func testLaunchCredentialOriginsAreCapturedBeforeFactorySuspends() async {
        let fixture = Fixture()
        fixture.factoryGateCall = 1
        let model = fixture.model(environment: ["TRANTHOR_WRITE_KEY": "fixture-launch", "TRANTHOR_HOST": "http://127.0.0.1:43189"])
        let configuring = Task { await model.configure() }
        await fixture.factoryGate.waitUntilEntered()
        model.editKey("fixture-edited")
        model.editHost("http://127.0.0.1:43190")
        fixture.factoryGate.release()
        await configuring.value
        XCTAssertEqual(fixture.configurations.first?.writeKey, "fixture-launch")
        XCTAssertEqual(fixture.configurations.first?.host, "http://127.0.0.1:43189")
        XCTAssertTrue(fixture.savedKeys.isEmpty, "Editing during a launch-only configuration must not save that configuration")
        XCTAssertTrue(fixture.savedHosts.isEmpty)
        XCTAssertFalse(model.lines.contains { $0.contains("fixture-launch") || $0.contains("fixture-edited") })
    }

    func testManualConfigurationPersistsItsSnapshotNotLaterFieldEdits() async {
        let fixture = Fixture()
        fixture.factoryGateCall = 1
        let model = fixture.model()
        model.editKey("fixture-first")
        model.editHost("http://127.0.0.1:43189")
        let configuring = Task { await model.configure() }
        await fixture.factoryGate.waitUntilEntered()
        model.editKey("fixture-later")
        model.editHost("http://127.0.0.1:43190")
        fixture.factoryGate.release()
        await configuring.value
        XCTAssertEqual(fixture.savedKeys, ["fixture-first"])
        XCTAssertEqual(fixture.savedHosts, ["http://127.0.0.1:43189"])
        XCTAssertEqual(fixture.configurations.first?.writeKey, "fixture-first")
        XCTAssertEqual(model.writeKey, "fixture-later", "The user's new edit remains available for the next configuration")
    }

    func testReconfigurationSnapshotsBeforeOldSDKShutdownSuspends() async {
        let fixture = Fixture()
        let model = fixture.model(environment: ["TRANTHOR_WRITE_KEY": "fixture-launch", "TRANTHOR_HOST": "http://127.0.0.1:43189"])
        await model.configure()
        let old = fixture.clients[0]
        old.shutdownGate = Suspension()
        let configuring = Task { await model.configure() }
        await old.shutdownGate?.waitUntilEntered()
        model.editKey("fixture-edited")
        model.editHost("http://127.0.0.1:43190")
        old.shutdownGate?.release()
        await configuring.value
        XCTAssertEqual(fixture.configurations.last?.writeKey, "fixture-launch")
        XCTAssertEqual(fixture.configurations.last?.host, "http://127.0.0.1:43189")
        XCTAssertTrue(fixture.savedKeys.isEmpty)
        XCTAssertTrue(fixture.savedHosts.isEmpty)
    }

    func testReconfigureWaitsForWholeBurstBeforeStoppingCapturedSDK() async {
        let fixture = Fixture()
        let model = fixture.model()
        model.editKey("fixture-first")
        await model.configure()
        let old = fixture.clients[0]
        old.actionGate = Suspension()
        fixture.factoryGateCall = 2
        let burst = Task { await model.send(.track, count: 3) }
        await old.actionGate?.waitUntilEntered()
        model.editKey("fixture-second")
        let configuring = Task { await model.configure() }
        await waitForConfigurationStart(model)
        XCTAssertEqual(old.shutdownCount, 0, "Reconfigure must wait for the active burst")
        old.actionGate?.release()
        await burst.value
        await fixture.factoryGate.waitUntilEntered()
        fixture.factoryGate.release()
        await configuring.value
        XCTAssertEqual(old.sentCount, 3)
        XCTAssertEqual(old.callsAfterStop, 0)
        XCTAssertEqual(model.acceptedCalls, 3)
        XCTAssertEqual(old.shutdownCount, 1)
        XCTAssertEqual(fixture.clients[1].sentCount, 0)
    }

    func testReconfigureWaitsForIdentifyResetAndConsentMutations() async {
        for operation in ["identify", "reset", "consent"] {
            let fixture = Fixture()
            let model = fixture.model()
            model.editKey("fixture-first")
            model.enteredUserId = "disposable-user"
            await model.configure()
            let old = fixture.clients[0]
            old.actionGate = Suspension()
            fixture.factoryGateCall = 2
            let action = Task {
                switch operation {
                case "identify": await model.identify()
                case "reset": await model.reset()
                default: await model.changeConsent()
                }
            }
            await old.actionGate?.waitUntilEntered()
            let configuring = Task { await model.configure() }
            await waitForConfigurationStart(model)
            XCTAssertEqual(old.shutdownCount, 0, operation)
            old.actionGate?.release()
            await action.value
            await fixture.factoryGate.waitUntilEntered()
            fixture.factoryGate.release()
            await configuring.value
            XCTAssertEqual(old.callsAfterStop, 0, operation)
            XCTAssertEqual(old.mutationCount, 1, operation)
            XCTAssertEqual(old.shutdownCount, 1, operation)
        }
    }

    func testOptOutCanInterruptAnInFlightFlush() async {
        let fixture = Fixture()
        let model = fixture.model()
        model.editKey("fixture")
        await model.configure()
        let client = fixture.clients[0]
        client.flushGate = Suspension()
        let flush = Task { await model.flush() }
        await client.flushGate?.waitUntilEntered()
        let consent = Task { await model.changeConsent() }
        for _ in 0..<1000 {
            if client.optedOut { break }
            await Task.yield()
        }
        // Release the gate in every case so a failure is reported instead of hanging; this test protects that opt-out does not wait for an in-flight flush.
        let interrupted = client.optedOut
        client.flushGate?.release()
        await flush.value
        await consent.value
        XCTAssertTrue(interrupted, "Opt out must reach the SDK without waiting for delivery")
        XCTAssertTrue(model.optedOut)
        XCTAssertFalse(model.flushing)
    }

    func testLogIsBoundedAndOnlyContainsLatestTwoHundredLines() {
        let fixture = Fixture()
        let model = fixture.model()
        for index in 0..<201 { model.log("line-\(index)") }
        XCTAssertEqual(model.lines.count, 200)
        XCTAssertTrue(model.lines.first?.hasSuffix("line-1") == true)
        XCTAssertTrue(model.lines.last?.hasSuffix("line-200") == true)
    }

    private func waitForConfigurationStart(_ model: ExampleModel) async {
        for _ in 0..<1000 {
            if model.configuring { return }
            await Task.yield()
        }
        XCTFail("Configuration did not enter its deterministic gate")
    }
}

/// Explicit continuation gates make suspension ordering deterministic; no sleeping or transport.
@MainActor
private final class Suspension {
    private var continuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var entered = false
    private var released = false
    func pause() async {
        entered = true
        let waiting = observers
        observers = []
        waiting.forEach { $0.resume() }
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class Fixture {
    var configurations: [Configuration] = []
    var clients: [FakeClient] = []
    var savedKeys: [String] = []
    var savedHosts: [String] = []
    var savedSlowFlush: [Bool] = []
    var deletedKeys = 0
    var factoryGateCall: Int?
    let factoryGate = Suspension()
    func model(environment: [String: String] = [:]) -> ExampleModel {
        ExampleModel(environment: environment, arguments: [], services: ExampleServices(
            makeClient: { [self] config in
                configurations.append(config)
                if configurations.count == factoryGateCall { await factoryGate.pause() }
                let client = FakeClient()
                clients.append(client)
                return client
            }, readKey: { nil }, saveKey: { [self] in savedKeys.append($0) },
            readHost: { nil }, saveHost: { [self] in savedHosts.append($0) }, monitorsNetwork: false, deleteKey: { [self] in deletedKeys += 1 },
            readSlowFlush: { false }, saveSlowFlush: { [self] in savedSlowFlush.append($0) }))
    }
}

@MainActor
private final class FakeClient: ExampleClient {
    var actionGate: Suspension?
    var shutdownGate: Suspension?
    var flushGate: Suspension?
    var optedOut = false
    var sentCount = 0
    var mutationCount = 0
    var shutdownCount = 0
    var callsAfterStop = 0
    private var stopped = false
    private var currentUser: String?
    func identity() async -> ExampleIdentity {
        ExampleIdentity(anonymousId: "fixture-anonymous", userId: currentUser, optedOut: optedOut)
    }
    private func admit() async -> Bool {
        await actionGate?.pause()
        if stopped { callsAfterStop += 1; return false }
        return true
    }
    func identify(userId: String, tags: [String: JSONValue]) async throws {
        if await admit() { mutationCount += 1; currentUser = userId }
    }
    func send(_ event: ExampleEvent, tags: [String: JSONValue]) async throws {
        if await admit(), !optedOut { sentCount += 1 }
    }
    func reset() async throws {
        if await admit() { mutationCount += 1; currentUser = nil }
    }
    func optOut() async throws {
        if await admit() { mutationCount += 1; optedOut = true; flushGate?.release() }
    }
    func optIn() async throws {
        if await admit() { mutationCount += 1; optedOut = false }
    }
    func flush() async throws { await flushGate?.pause() }
    func shutdown() async {
        shutdownCount += 1
        await shutdownGate?.pause()
        stopped = true
    }
}
