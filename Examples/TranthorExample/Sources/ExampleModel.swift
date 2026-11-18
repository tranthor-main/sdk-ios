import Foundation
import Network
import SwiftUI
import TranthorSDK
import TranthorPush

@MainActor
final class ExampleModel: ObservableObject {
    @Published var writeKey = ""
    @Published var host = "https://api.tranthor.com"
    @Published var enteredUserId = ""
    @Published var burstCount = 25
    @Published var offlineInstructions = false
    @Published private(set) var slowFlush = false
    private var launchFlushInterval: Double?
    var flushIntervalMs: Double { launchFlushInterval ?? (slowFlush ? 60_000 : 500) }
    var flushIntervalText: String { "Flush interval: \(Int(flushIntervalMs)) ms" }
    @Published private(set) var reachable: Bool?
    @Published private(set) var configured = false
    @Published private(set) var configuring = false
    @Published private(set) var flushing = false
    @Published private(set) var anonymousId = "Not configured"
    @Published private(set) var userId = "Anonymous"
    @Published private(set) var optedOut = false
    @Published private(set) var lastFlush = "Not requested"
    @Published private(set) var acceptedCalls = 0
    @Published private(set) var errors: [String] = []
    @Published private(set) var lines: [String] = []
    let runId = UUID().uuidString
    private(set) var keyFromLaunch = false
    private var hostFromLaunch = false
    private var sdk: (any ExampleClient)?
    private var pushModel: ExamplePushModel?
    private let monitor = NWPathMonitor()
    private let namespace: String
    private let services: ExampleServices
    private var configurationGeneration = 0
    private var mutating = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    init(environment: [String: String] = ProcessInfo.processInfo.environment,
         arguments: [String] = ProcessInfo.processInfo.arguments,
         services: ExampleServices = .live) {
        self.services = services
        // UI tests isolate their disk state; normal relaunches share the durable SDK namespace.
        namespace = arguments.contains("--ui-testing") ? "ui-test-\(UUID().uuidString)" : "ios-example"
        func launchValue(_ name: String) -> String? {
            if let value = environment[name] { return value }
            if let index = arguments.firstIndex(of: "--\(name)"), index + 1 < arguments.count {
                return arguments[index + 1]
            }
            return nil
        }
        slowFlush = services.readSlowFlush()
        if let value = launchValue("TRANTHOR_FLUSH_INTERVAL_MS"), let interval = Double(value),
           interval.isFinite, interval > 0, interval.rounded(.down) == interval, interval < Double(Int.max) {
            launchFlushInterval = interval
            slowFlush = interval > 500
        }
        if let value = launchValue("TRANTHOR_HOST") { host = value; hostFromLaunch = true }
        else if let value = services.readHost() { host = value }
        if let value = launchValue("TRANTHOR_WRITE_KEY") { writeKey = value; keyFromLaunch = true }
        else {
            do { writeKey = try services.readKey() ?? "" }
            catch { log("Could not read the device Keychain; enter the key again.") }
        }
        if services.monitorsNetwork {
            monitor.pathUpdateHandler = { [weak self] path in
                let online = path.status == .satisfied
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let previous = self.reachable
                    self.reachable = online
                    if previous != online { self.log(online ? "Network route available (delivery still requires a successful request)." : "Network unreachable. Events are kept and retried when the network is back.") }
                    // Reconnect never forces a flush: the SDK retry schedule remains observable.
                }
            }
            monitor.start(queue: DispatchQueue(label: "TranthorExample.network"))
        }
        log("Reconnect auto-flush is disabled; SDK retries run on their own schedule.")
        log("Launch runId: \(runId)")
    }

    var properties: [String: JSONValue] {
        ["liveTest": .bool(true), "runId": .string(runId), "source": .string("ios-example")]
    }
    func log(_ text: String) {
        let time = Date.now.formatted(date: .omitted, time: .standard)
        lines.append("[\(time)] \(text)")
        if lines.count > 200 { lines.removeFirst(lines.count - 200) }
    }
    func start() async { if !writeKey.isEmpty { await configure() } }
    func attachPush(_ push: ExamplePushModel) {
        pushModel = push
        push.onLog = { [weak self] line in self?.log(line) }
        push.onEvent = { [weak self] event in
            guard let self else { return }
            await self.acquireMutation()
            defer { self.releaseMutation() }
            guard let sdk = self.sdk, self.configured, !self.configuring, !self.optedOut else { throw CancellationError() }
            _ = (sdk, event) // The SDK already queued Push Received/Opened/Dismissed under its own identity and consent.
            self.acceptedCalls += 1
        }
    }
    func editKey(_ key: String) { writeKey = key; keyFromLaunch = false }
    func editHost(_ value: String) { host = value; hostFromLaunch = false }
    func setSlowFlush(_ enabled: Bool) async {
        slowFlush = enabled; launchFlushInterval = nil
        services.saveSlowFlush(enabled)
        log(enabled ? "Slow flush enabled (60 s); use Home to exercise lifecycle delivery." : "Normal flush interval restored (500 ms).")
        if configured { await configure() }
    }
    func forgetKey() async {
        await acquireMutation(); defer { releaseMutation() }
        await pushModel?.disable()
        if let sdk { await sdk.shutdown() }
        configurationGeneration += 1
        sdk = nil; configured = false; writeKey = ""; keyFromLaunch = false
        anonymousId = "Not configured"; userId = "Anonymous"; optedOut = false
        lastFlush = "Not requested"; errors = []; flushing = false
        do { try services.deleteKey(); log("Saved write key forgotten; configure with a new key to resume.") }
        catch { log("Keychain deletion failed; the field is cleared, but try Forget key again.") }
    }

    // MainActor methods can reenter at awaits. Hold this FIFO gate across a whole mutation,
    // including a burst, so reconfiguration cannot shut down an SDK captured by an action.
    private func acquireMutation() async {
        if !mutating { mutating = true; return }
        await withCheckedContinuation { mutationWaiters.append($0) }
    }
    private func releaseMutation() {
        if mutationWaiters.isEmpty { mutating = false }
        else { mutationWaiters.removeFirst().resume() }
    }

    func configure() async {
        guard !configuring else { return }
        // Capture values AND their origins before the first await. Editing fields while the
        // factory/shutdown suspends must neither configure nor persist a different credential.
        let key = writeKey, selectedHost = host
        let saveKey = !keyFromLaunch, saveHost = !hostFromLaunch
        guard !key.isEmpty else { log("Enter a write key before configuring."); return }
        guard let url = URL(string: selectedHost), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            log("Host must be an HTTP(S) origin without credentials, query or fragment."); return
        }
        configuring = true
        defer { configuring = false }
        await acquireMutation()
        defer { releaseMutation() }
        configurationGeneration += 1
        let generation = configurationGeneration
        await pushModel?.disable()
        if let sdk { await sdk.shutdown() }
        configured = false
        lastFlush = "Not requested"
        do {
            let configuration = Configuration(writeKey: key, host: selectedHost, flushIntervalMs: flushIntervalMs, storageNamespace: namespace,
                onError: { [weak self] failure in
                    let status = failure.error.status.map(String.init) ?? "transport"
                    let entry = "\(failure.events.count) event(s), \(failure.attempts) attempt(s), error: \(status) / \(failure.error.message)"
                    Task { @MainActor [weak self] in
                        guard let self, self.configurationGeneration == generation else { return }
                        self.recordFailure(entry)
                    }
                })
            sdk = try await services.makeClient(configuration)
            configured = true
            if saveKey {
                do { try services.saveKey(key) }
                catch { log("Configured, but Keychain saving failed. Re-enter the key next launch.") }
            }
            if saveHost { services.saveHost(selectedHost) }
            await refresh()
            log("Flush interval: \(Int(flushIntervalMs)) ms. Track does not explicitly flush.")
            log("Configured. Credentials are hidden; queued state restored from this app's durable namespace.")
        } catch { sdk = nil; log("Configuration failed. Check the host and local storage.") }
    }
    private func recordFailure(_ entry: String) {
        errors.append(entry)
        if errors.count > 200 { errors.removeFirst(errors.count - 200) }
        log("Terminal batch error: \(entry)")
    }
    private func refresh() async {
        guard let sdk else { return }
        let identity = await sdk.identity()
        anonymousId = identity.anonymousId
        userId = identity.userId ?? "Anonymous"
        optedOut = identity.optedOut
        await pushModel?.synchronize(optedOut: identity.optedOut, sdk: sdk.tranthor)
    }
    func identify() async {
        await acquireMutation()
        defer { releaseMutation() }
        guard let sdk, configured, !configuring else { return }
        let selectedUser = enteredUserId
        guard !selectedUser.isEmpty else { log("Enter a user ID before Identify."); return }
        do {
            try await sdk.identify(userId: selectedUser, tags: properties)
            await refresh()
            log(optedOut ? "Identify discarded: opted out." : "Identify accepted with live-test tags in traits/context.")
        } catch { log("Identify could not be persisted.") }
    }
    typealias Event = ExampleEvent
    func send(_ event: Event, count: Int = 1) async {
        await acquireMutation()
        defer { releaseMutation() }
        guard let sdk, configured, !configuring, count > 0 else { return }
        let tags = properties
        do {
            for _ in 0..<count {
                try await sdk.send(event, tags: tags)
                if !optedOut { acceptedCalls += 1 }
            }
            log(optedOut ? "Call discarded: opted out." : "\(count) \(event) call(s) accepted. This is not a delivery acknowledgement.")
        } catch { log("Event could not be persisted.") }
    }
    func flush() async {
        guard let sdk, configured, !flushing, !configuring else { return }
        let generation = configurationGeneration
        flushing = true
        lastFlush = "Waiting for delivery…"
        log("Flush started.")
        defer { flushing = false }
        // Delivery deliberately does not hold the mutation gate: optOut must interrupt it.
        do {
            try await sdk.flush()
            guard generation == configurationGeneration else { return }
            lastFlush = optedOut ? "Succeeded (opted out; no request)" : "Succeeded"
            log("Flush: \(lastFlush).")
        } catch {
            guard generation == configurationGeneration else { return }
            lastFlush = "Failed or cancelled; see terminal errors"
            log("Flush failed or was cancelled. Terminal errors below describe delivery failures.")
        }
    }
    func changeConsent() async {
        await acquireMutation()
        defer { releaseMutation() }
        guard let sdk, configured, !configuring else { return }
        do {
            if optedOut { try await sdk.optIn() } else { try await sdk.optOut() }
            await refresh()
            log(optedOut ? "Opted out: queued events discarded and retries cancelled." : "Opted in: new events will be accepted.")
        } catch { await refresh(); log("Consent change could not be saved.") }
    }
    func reset() async {
        await acquireMutation()
        defer { releaseMutation() }
        guard let sdk, configured, !configuring else { return }
        do { try await sdk.reset(); await refresh(); enteredUserId = ""; log("Identity reset; a new anonymous ID is active.") }
        catch { log("Identity reset could not be saved.") }
    }
}
