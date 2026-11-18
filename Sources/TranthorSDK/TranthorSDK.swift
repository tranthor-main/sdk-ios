import Foundation
import os

/// Sends events to Tranthor from an app. Events are queued on disk, sent in batches, and retried while the
/// network or server is unavailable. Create one instance with ``configure(_:)`` and keep it for the app's lifetime.
/// Await each call to keep events in the order they were made.
public actor TranthorSDK {
    nonisolated let configuration: Configuration
    let store: JSONStore
    let transport: any SDKTransport
    let sleep: @Sendable (Double) async throws -> Void
    let lease: NamespaceLease
    var state: StoredState
    let context: [String: JSONValue]
    var timer: Task<Void, Never>?
    var cycle: Task<Void, Never>?
    private(set) var stopped = false
    private var shutdownTask: Task<Void, Never>?
    var paused = false
    var timerGeneration = 0
    var backoff: Task<Void, any Error>?
    var backgroundToken: UUID?
    var lifecycleToken: UUID?
    var dropped: [[String: JSONValue]] = []
    var dropNotification: Task<Void, Never>?
    /// What the last Installation event said (token, owner, permission, versions). In memory only, so each
    /// app start registers once: the server expires an Installation that is not re-registered for 90 days.
    var sentInstallation: [String]?
    var installationClockMs = Int64.min
    /// The retryable failure that ended the opt-out removals' attempt cycle. While set, nothing is sent and no
    /// timer runs: only app start, a return to the foreground, optIn() and optOut() start one new cycle.
    var removalParked: DeliveryFailure?
    var removalTriggers: UInt64 = 0
    var sawBackground = false
    struct Waiter {
        var continuation: CheckedContinuation<Void, any Error>
        var failure: DeliveryFailure?
    }
    var waiters: [Waiter] = []
    #if canImport(UIKit)
    private var lifecycle: LifecycleObserver?
    #endif
    static let logger = Logger(subsystem: "com.tranthor.sdk", category: "delivery")

    /// Construction is async so no disk I/O or unstructured start task runs in a synchronous initializer.
    init(configuration: Configuration) async throws {
        try await self.init(configuration: configuration, transport: Transport(configuration: configuration), sleep: sleepMilliseconds)
    }

    init(configuration: Configuration, transport: any SDKTransport,
         sleep: @escaping @Sendable (Double) async throws -> Void,
         storeWrite: @escaping @Sendable (Data, URL) throws -> Void = { try JSONStore.write($0, to: $1) },
         storeMove: @escaping @Sendable (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }) async throws {
        let acquired = try await NamespaceRegistry.shared.acquire(directory: configuration.storageDirectory, namespace: configuration.storageNamespace)
        let loaded: (JSONStore, StoredState, [[String: JSONValue]])
        do {
            loaded = try await Task.detached {
                var store = try JSONStore(directory: configuration.storageDirectory, namespace: configuration.storageNamespace, write: storeWrite, move: storeMove)
                var restored = try store.load()
                restored.queued = restored.active + restored.queued
                restored.active = []
                if restored.optedOut { restored.queued = [] }
                // An opt-out interrupted after its consent write never recorded its removal: leave it now, before
                // the first save below hides that it happened.
                if store.interruptedOptOut, let installation = restored.installation, restored.userId != nil {
                    let target = "\(installation.appId)|\(installation.token)"
                    restored.pendingRemovals.removeAll { TranthorSDK.installationTarget($0) == target }
                    restored.pendingRemovals.append(optOutRemovalItem(restored, installation))
                }
                let overflow = max(0, restored.queued.count - configuration.maxQueueSize)
                let removed = Array(restored.queued.prefix(overflow))
                restored.queued.removeFirst(overflow)
                // Persist fail-closed consent recovery independently of routine state writes.
                try store.saveConsent(restored.optedOut)
                try store.save(restored)
                return (store, restored, removed)
            }.value
        } catch {
            await NamespaceRegistry.shared.release(acquired)
            transport.shutdown()
            if case TranthorError.storeTemporarilyUnavailable = error { throw error }
            throw TranthorError.storeTemporarilyUnavailable(underlying: error)
        }
        self.configuration = configuration
        self.transport = transport
        self.sleep = sleep
        lease = acquired
        store = loaded.0
        state = loaded.1
        context = configuration.automaticContext ? automaticContext() : [:]
        #if canImport(UIKit)
        lifecycle = await LifecycleObserver(sdk: self)
        #endif
        reportDropped(loaded.2)
        armTimer()
        // An opt-out removal left undelivered by a previous run gets one cycle at app start.
        triggerRemovals()
    }

    deinit {
        timer?.cancel()
        cycle?.cancel()
        backoff?.cancel()
        dropNotification?.cancel()
        transport.shutdown()
        let lease = lease
        Task { await NamespaceRegistry.shared.release(lease) }
        #if canImport(UIKit)
        let observer = lifecycle
        Task { @MainActor in observer?.dispose() }
        #endif
    }

    /// Creates the SDK, restores the queue and identity from disk, and starts delivery.
    /// - Throws: ``TranthorError/invalidHost`` for an unusable host, ``TranthorError/namespaceInUse`` when another
    ///   instance uses the same storage, or ``TranthorError/storeTemporarilyUnavailable(underlying:)`` when the
    ///   disk cannot be read or written.
    public static func configure(_ configuration: Configuration) async throws -> TranthorSDK {
        try await TranthorSDK(configuration: configuration)
    }

    var deliveryCycleActive: Bool { cycle != nil }
    var pendingTimer: Task<Void, Never>? { timer }
    var flushWaiterCount: Int { waiters.count }
    var deliveryPaused: Bool { paused }
    var isStopped: Bool { stopped }

    /// The identifier of this installation until a user is identified. Replaced by `reset()` and when a different user identifies.
    public var anonymousId: String { state.anonymousId }
    /// The user ID of the last `identify(userId:)`, or nil when nobody is identified.
    public var userId: String? { state.userId }
    /// Whether the user opted out of collection with `optOut()`. Persists across launches.
    public var isOptedOut: Bool { state.optedOut }

    /// Signs `userId` in and records `traits`. The event also carries the stored anonymous ID, so earlier anonymous
    /// events link to the user. A different user than the stored one gets a new anonymous ID first; an empty
    /// `userId` is ignored. An explicit `anonymousId` is sent instead and is not stored.
    public func identify(userId: String? = nil, anonymousId: String? = nil,
                         traits: [String: JSONValue]? = nil, messageId: String? = nil,
                         timestamp: String? = nil, context: [String: JSONValue]? = nil) throws {
        guard !state.optedOut, !stopped else { return }
        let previousUserId = state.userId
        let previousAnonymousId = state.anonymousId
        // "" is not a user: storing it would hide the previous user from the rotation check below.
        let user = userId.flatMap { $0.isEmpty ? nil : $0 }
        // Saved together with the new user ID (and the event) by the single state write in enqueue().
        if let user, let previousUserId, !previousUserId.isEmpty, previousUserId != user {
            state.anonymousId = UUID().uuidString
        }
        if let user { state.userId = user }
        var data = payload(userId: user, anonymousId: anonymousId ?? (user != nil ? state.anonymousId : nil),
                           messageId: messageId, timestamp: timestamp, context: context)
        if let traits { data["traits"] = .object(traits) }
        // A signed-in customer's push Installation follows the identity; the server moves the token to its new
        // owner. An identify that signs nobody in (traits only, or an empty user id) leaves a held token held.
        var registration: [String: JSONValue]?
        var fingerprint: [String]?
        if let installation = state.installation, state.userId != nil {
            fingerprint = installationFingerprint(installation)
            if fingerprint != sentInstallation { registration = installationItem("Installation Registered", installation, details: true) }
        }
        do {
            try enqueue("identify", data, alongside: registration.map { [$0] } ?? [])
            if registration != nil { sentInstallation = fingerprint }
        } catch { state.userId = previousUserId; state.anonymousId = previousAnonymousId; throw error }
    }
    /// Queues an event with a name and optional properties. Ignored while opted out.
    public func track(event: String, userId: String? = nil, anonymousId: String? = nil,
                      properties: [String: JSONValue]? = nil, files: [JSONValue]? = nil,
                      messageId: String? = nil, timestamp: String? = nil, context: [String: JSONValue]? = nil) throws {
        var data = payload(userId: userId, anonymousId: anonymousId, messageId: messageId, timestamp: timestamp, context: context)
        data["event"] = .string(event)
        if let properties { data["properties"] = .object(properties) }
        if let files { data["files"] = .array(files) }
        try enqueue("track", data)
    }
    /// Queues a page view, for apps that show web-style pages. Ignored while opted out.
    public func page(name: String? = nil, userId: String? = nil, anonymousId: String? = nil,
                     properties: [String: JSONValue]? = nil, messageId: String? = nil,
                     timestamp: String? = nil, context: [String: JSONValue]? = nil) throws {
        try named("page", name, userId, anonymousId, properties, messageId, timestamp, context)
    }
    /// Queues a screen view. Ignored while opted out.
    public func screen(name: String? = nil, userId: String? = nil, anonymousId: String? = nil,
                       properties: [String: JSONValue]? = nil, messageId: String? = nil,
                       timestamp: String? = nil, context: [String: JSONValue]? = nil) throws {
        try named("screen", name, userId, anonymousId, properties, messageId, timestamp, context)
    }
    private func named(_ type: String, _ name: String?, _ userId: String?, _ anonymousId: String?,
                       _ properties: [String: JSONValue]?, _ messageId: String?, _ time: String?,
                       _ context: [String: JSONValue]?) throws {
        var data = payload(userId: userId, anonymousId: anonymousId, messageId: messageId, timestamp: time, context: context)
        if let name { data["name"] = .string(name) }
        if let properties { data["properties"] = .object(properties) }
        try enqueue(type, data)
    }
    func payload(userId: String?, anonymousId: String?, messageId: String?, timestamp time: String?,
                         context caller: [String: JSONValue]?) -> [String: JSONValue] {
        var data: [String: JSONValue] = ["messageId": .string(messageId ?? UUID().uuidString),
                                       "timestamp": .string(time ?? timestamp())]
        if let userId { data["userId"] = .string(userId) }
        if let anonymousId { data["anonymousId"] = .string(anonymousId) }
        if userId == nil && anonymousId == nil {
            if let stored = state.userId { data["userId"] = .string(stored) }
            else { data["anonymousId"] = .string(state.anonymousId) }
        }
        let merged = context.merging(caller ?? [:], uniquingKeysWith: { _, caller in caller })
        if caller != nil || !merged.isEmpty { data["context"] = .object(merged) }
        return data
    }
    private func enqueue(_ type: String, _ payload: [String: JSONValue], alongside extra: [[String: JSONValue]] = []) throws {
        guard !state.optedOut, !stopped else { return }
        var item = payload
        item["type"] = .string(type)
        // Reject non-finite numeric payloads before they can poison a batch.
        do { _ = try JSONEncoder().encode(item) }
        catch {
            configuration.onError?(BatchFailure(
                error: DeliveryFailure(status: nil, message: "Invalid JSON payload", retryAfterMs: 0),
                events: Self.redactingToken([item]), attempts: 0))
            throw error
        }
        try admit([item] + extra)
    }
    /// Appends items in one durable write, dropping the oldest ordinary events if the queue is over capacity.
    /// An `Installation Registered/Removed` goes last: it is dropped only when nothing else can be, and then
    /// the oldest one that a newer event for the same token supersedes goes first.
    func admit(_ items: [[String: JSONValue]]) throws {
        let previous = state.queued
        state.queued.append(contentsOf: items)
        let waitingCapacity = max(0, configuration.maxQueueSize - state.active.count)
        var removed: [[String: JSONValue]] = []
        while state.queued.count > waitingCapacity { removed.append(state.queued.remove(at: Self.overflowIndex(state.queued))) }
        do { try store.save(state) }
        catch { state.queued = previous; throw error }
        reportDropped(removed)
        if state.queued.count >= configuration.batchSize { beginCycle() }
        else { armTimer() }
    }
    private static func overflowIndex(_ queue: [[String: JSONValue]]) -> Int {
        if let ordinary = queue.firstIndex(where: { installationTarget($0) == nil }) { return ordinary }
        for index in queue.indices {
            let target = installationTarget(queue[index])
            if queue[(index + 1)...].contains(where: { installationTarget($0) == target }) { return index }
        }
        return 0
    }
    /// Clears the stored user ID and generates a new anonymous UUID. Queued items keep their identities. A
    /// signed-in customer's push Installation is removed under the outgoing identity, in the same durable write
    /// as the rotation, and is not registered again until the next `identify`.
    public func reset() throws {
        guard !stopped else { return }
        // Only a signed-in customer's phone is registered, so only then is there a binding to remove.
        let installation = state.optedOut || state.userId == nil ? nil : state.installation
        // Built before the rotation, so it carries the outgoing identity.
        let removal = installation.map { installationItem("Installation Removed", $0, details: false) }
        state.userId = nil
        state.anonymousId = UUID().uuidString
        sentInstallation = nil
        // The token stays held: the next identify() registers it to that customer. Nothing is registered now.
        guard let removal else { try store.save(state); return }
        try admit([removal])
    }
    /// Stops collection and discards queued events. Persists across launches until `optIn()`. A registered push
    /// token is still removed from the server.
    public func optOut() async throws {
        guard !stopped else { return }
        // The one exception to "opt-out discards everything": the server must stop pushing to this phone.
        if !state.optedOut { state.pendingRemovals = optOutRemovals() }
        sentInstallation = nil
        state.optedOut = true
        state.queued = []
        state.active = []
        dropped = []
        dropNotification?.cancel(); dropNotification = nil
        cancelTimer()
        let pending = cycle
        pending?.cancel(); backoff?.cancel()
        // Consent must be durable before any queue/identity state can reopen it.
        let saveResult = Result { try store.saveConsent(true); try store.save(state) }
        await pending?.value
        triggerRemovals()
        try saveResult.get()
    }
    /// Resumes collection after `optOut()`.
    public func optIn() throws {
        guard !stopped else { return }
        try store.saveConsent(false)
        state.optedOut = false
        try store.save(state)
        // Opt-out discarded the queue and cleared the fingerprint, so a signed-in customer's Installation
        // registers again. A held token waits for identify().
        if let installation = state.installation, state.userId != nil {
            let fingerprint = installationFingerprint(installation)
            if fingerprint != sentInstallation {
                try admit([installationItem("Installation Registered", installation, details: true)])
                sentInstallation = fingerprint
            }
        }
        if state.pendingRemovals.isEmpty { armTimer() } else { triggerRemovals() }
    }
    /// Sends queued events now and returns when they are delivered.
    /// - Throws: The `DeliveryFailure` that ended delivery, or `CancellationError` if the SDK was shut down.
    public func flush() async throws {
        guard !stopped else { throw CancellationError() }
        guard !state.optedOut else { return }
        // A removal that could not be delivered holds the queue back until a trigger delivers it.
        if !state.pendingRemovals.isEmpty, let failure = removalParked { throw failure }
        emitDropped()
        paused = false
        if cycle == nil && state.queued.isEmpty { return }
        try await withCheckedThrowingContinuation { continuation in
            waiters.append(Waiter(continuation: continuation))
            beginCycle()
        }
    }
    /// Stops without flushing. No later mutator can write this instance's store.
    public func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        stopped = true
        let cleanup = Task { await completeShutdown() }
        shutdownTask = cleanup
        await cleanup.value
    }
    private func completeShutdown() async {
        cancelTimer()
        let pending = cycle
        pending?.cancel(); backoff?.cancel()
        // The delivery under way ends first (its request is cancelled with it), so nothing starts a request on the
        // transport after it is shut down.
        await pending?.value
        transport.shutdown()
        emitDropped()
        persistDeliveryState()
        #if canImport(UIKit)
        await lifecycle?.dispose(); lifecycle = nil
        #endif
        await NamespaceRegistry.shared.release(lease)
    }
}
