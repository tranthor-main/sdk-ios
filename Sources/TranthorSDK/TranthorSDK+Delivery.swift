import Foundation
import os

/// Delivery: the flush timer, attempt cycles and retries, the opt-out removal queue, and the background and foreground hooks.
extension TranthorSDK {
    /// One new attempt cycle for undelivered opt-out removals (app start, return from the background, optIn, optOut).
    func triggerRemovals() {
        guard !state.pendingRemovals.isEmpty else { return }
        removalTriggers &+= 1
        removalParked = nil
        beginCycle()
    }
    /// The delivery cycle's work: undelivered removals always, ordinary events only while opted in and
    /// only once no removal is waiting.
    var hasDeliverableWork: Bool {
        state.pendingRemovals.isEmpty ? (!state.optedOut && !queue.events.isEmpty && !pause.isRunning && !held) : removalParked == nil
    }
    func startExhaustionPause() {
        let sleep = sleep
        pause.start { generation, delay in
            Task { [weak self] in
                do { try await sleep(delay) } catch { return }
                await self?.exhaustionPauseEnded(generation)
            }
        }
    }
    func exhaustionPauseEnded(_ generation: Int) {
        guard pause.finish(generation) else { return }
        beginCycle()
    }
    func cancelTimer() {
        timerGeneration &+= 1
        timer?.cancel(); timer = nil
    }
    func armTimer() {
        guard timer == nil, cycle == nil, hasDeliverableWork, !stopped, !paused, !held else { return }
        timerGeneration &+= 1
        let generation = timerGeneration
        let delay = configuration.flushIntervalMs
        let sleep = sleep
        timer = Task { [weak self] in
            do { try await sleep(Double(delay)) } catch { return }
            await self?.timerFired(generation)
        }
    }
    func timerFired(_ generation: Int) {
        guard generation == timerGeneration else { return }
        timer = nil
        beginCycle()
    }
    func beginCycle() {
        guard cycle == nil, !stopped, !paused, !held, hasDeliverableWork else { return }
        cancelTimer()
        cycle = Task { await runCycle() }
    }
    func persistDeliveryState() {
        do { try store.save(state) }
        catch { Self.logger.debug("Unable to save delivery state") }
    }
    func reportDropped(_ events: [[String: JSONValue]]) {
        guard !events.isEmpty, !state.optedOut else { return }
        dropped += events
        guard dropNotification == nil else { return }
        let sleep = sleep
        dropNotification = Task { [weak self] in
            do { try await sleep(500) } catch { return }
            await self?.emitDropped()
        }
    }
    func emitDropped() {
        dropNotification?.cancel(); dropNotification = nil
        guard !dropped.isEmpty else { return }
        let events = dropped; dropped = []
        configuration.onError?(BatchFailure(error: DeliveryFailure(status: nil, message: "Queue capacity exceeded; oldest queued events dropped"), events: Self.redactingToken(events), attempts: 0))
    }
    /// Gives every waiter that has no failure yet this one, so its `flush()` throws it.
    func failWaiters(with failure: DeliveryFailure) {
        for index in waiters.indices where waiters[index].failure == nil { waiters[index].failure = failure }
    }
    /// Deletes queue files. Any that cannot be deleted are remembered and deleted by a later cycle.
    func deleteFiles(_ sequences: [UInt64]) {
        pendingDeletion.formUnion(store.remove(sequences))
    }
    func retryPendingDeletions() {
        guard !pendingDeletion.isEmpty else { return }
        pendingDeletion = Set(store.remove(Array(pendingDeletion)))
    }
    func runCycle() async {
        retryPendingDeletions()
        let triggersAtStart = removalTriggers
        let removalsDelivered = state.pendingRemovals.isEmpty ? true : await deliverRemovals()
        var exhausted = false
        var unacknowledged = false
        var holdMs: Double?
        while removalsDelivered && !queue.events.isEmpty && !Task.isCancelled && !stopped && !state.optedOut && !pause.isRunning {
            let batch = Array(queue.events.prefix(takeCount(queue.events.lazy.map(\.event))))
            inFlightCount = batch.count
            var terminal: DeliveryFailure?
            var acknowledged = false
            switch await deliver(batch.map(\.event), source: .queue).result {
            case .acknowledged: acknowledged = true; pause.reset()
            case .failed(let failure):
                terminal = failure
                failWaiters(with: failure)
            case .exhausted(let failure):
                exhausted = true; unacknowledged = true
                failWaiters(with: failure)
            case .held(let failure, let ms):
                // The batch stays at the head of the queue; a flush that asked for it is told why it was not delivered.
                holdMs = ms; unacknowledged = true
                failWaiters(with: failure)
            case .interrupted: unacknowledged = true
            }
            inFlightCount = 0
            if acknowledged || terminal != nil {
                // Items dropped for an unverified previous user are already gone from the queue and from disk.
                let present = Set(queue.events.map(\.sequence))
                let finished = Set(batch.map(\.sequence)).intersection(present)
                queue.events.removeAll { finished.contains($0.sequence) }
                deleteFiles(Array(finished))
                if pruneTokens() { persistDeliveryState() }
            }
            // Never advance to another batch while this one remains unacknowledged.
            if !acknowledged && terminal == nil { break }
            if Task.isCancelled || stopped || state.optedOut || paused { break }
            if terminal?.retryable == true { break }
        }
        // An unacknowledged batch is still queued (and on disk), so it is the head of the next cycle. Cancellation
        // is cycle-local and cannot be undone by a foreground notification or flush await.
        let cancelled = Task.isCancelled || stopped || paused || unacknowledged
        backoff = nil
        cycle = nil
        if exhausted && !Task.isCancelled && !stopped && !paused && !state.optedOut { startExhaustionPause() }
        if let holdMs, !stopped, !state.optedOut { startHold(holdMs) }
        else if let removalHold = removalHoldMs, !stopped, !state.pendingRemovals.isEmpty { startHold(removalHold) }
        removalHoldMs = nil
        if let failure = removalParked, !state.pendingRemovals.isEmpty {
            failWaiters(with: failure)
        }
        let completions = waiters; waiters = []
        for waiter in completions {
            if let failure = waiter.failure { waiter.continuation.resume(throwing: failure) }
            else if cancelled { waiter.continuation.resume(throwing: CancellationError()) }
            else { waiter.continuation.resume() }
        }
        // A trigger that arrived during this cycle still gets a cycle of its own.
        if removalTriggers != triggersAtStart, removalParked != nil, !state.pendingRemovals.isEmpty {
            removalParked = nil
            beginCycle()
        }
        armTimer()
    }
    enum DeliverySource { case queue, removals }
    enum DeliveryResult { case acknowledged, failed(DeliveryFailure), exhausted(DeliveryFailure), interrupted, held(DeliveryFailure, Double) }
    /// What a delivery left: its result, and the items still in the batch (those not dropped for an unverified user).
    struct Delivered {
        var result: DeliveryResult
        var remaining: [[String: JSONValue]]
    }
    /// Sends one batch, retrying retryable failures with backoff. A rejection is reported to `onError` once. When the
    /// retries run out the result is `.exhausted` for the queue (the caller keeps the events and `onError` stays
    /// silent); opt-out removals (`.removals`) do not keep an exhausted batch because they have their own retry rule:
    /// one failed cycle parks them until the next trigger, with no timed pause. Removals are delivered after consent is
    /// withdrawn, so they do not stop on opt-out.
    ///
    /// Identity tokens: the current user's token is renewed first when it is missing or about to expire, and the batch
    /// is then sent with the tokens held, because the server decides. A `403 identity_not_verified` renews and retries
    /// once, drops only previous users' items, and holds the batch when no token can be had; an identity `503` holds the
    /// batch. Neither counts against the retry budget.
    func deliver(_ initial: [[String: JSONValue]], source: DeliverySource) async -> Delivered {
        defer { backoff = nil }
        let stopsOnOptOut = source == .queue
        let keepsExhaustedBatch = source == .queue
        var batch = initial
        var attempt = 0
        var requests = 0
        var renewedForCurrent = false
        var renewedUsers = Set<String>()
        while !batch.isEmpty {
            do {
                try Task.checkCancellation()
                // A token the provider just gave counts as this send's one renewal: refused again, it is held, not renewed again.
                if await renewCurrentUserIfNeeded(batch) { renewedForCurrent = true }
                try Task.checkCancellation()
                guard !stopped, !(stopsOnOptOut && state.optedOut) else { return Delivered(result: .interrupted, remaining: batch) }
                requests += 1
                for item in batch { if let id = item["messageId"]?.string { requestsPerEvent[id, default: 0] += 1 } }
                let notes = try await transport.send(batch, identityTokens: tokens(for: batch))
                // A 2xx acknowledges the batch even if cancellation raced with the response.
                conclude(batch)
                reportResponseNotes(notes)
                return Delivered(result: .acknowledged, remaining: batch)
            } catch {
                guard !Task.isCancelled, !stopped, !(stopsOnOptOut && state.optedOut) else { return Delivered(result: .interrupted, remaining: batch) }
                let failure = (error as? DeliveryFailure) ?? DeliveryFailure(status: nil, message: "Delivery failed", retryAfterMs: 0)
                var retryable = failure.retryable
                if failure.status == 503, let code = failure.code, unavailableCodes.contains(code) {
                    // The server could not read its identity settings. Nothing is wrong with the batch: keep it.
                    let requested = failure.retryAfterMs > 0 ? failure.retryAfterMs : unavailableHoldDefaultMs
                    notify(.identityUnavailable, message: "The server could not read its identity settings; the batch is kept and sent again later")
                    return Delivered(result: .held(failure, min(unavailableHoldMaxMs, max(unavailableHoldMinMs, requested))), remaining: batch)
                }
                if failure.status == 403, failure.code == "identity_not_verified" {
                    let inBatch = distinctUsers(batch)
                    let named = failure.userIds.map { ids in inBatch.filter { ids.contains($0) } } ?? []
                    // A 403 that names nobody we can match means every user in the batch.
                    let refused = named.isEmpty ? inBatch : named
                    let current = currentUser
                    if refused.isEmpty {
                        // Nothing to renew, drop or hold: a failed send with the normal backoff, never a tight loop.
                        notify(.identityRefused, reason: failure.reason, message: "The server refused the identity token and named no user to renew; the send is retried with the normal backoff")
                        retryable = true
                    } else if let current, refused.contains(current), !identityInUse {
                        // An app that never supplied a token provider or a token keeps the ordinary 403: reported and dropped below.
                    } else {
                        for user in refused { state.identityTokens.remove(user) }
                        persistDeliveryState()
                        var parkedRemovals = Set<String>()
                        for user in refused where user != current {
                            let items = batch.filter { itemUser($0) == user }
                            // An `Installation Removed` is never dropped for lack of a token: without it the phone keeps
                            // receiving push. The provider is asked once for that user's token; if it cannot help, the
                            // removal stays parked and is tried again after the hold, one notice per failed attempt. The user's other events are dropped.
                            let removals = items.filter(Self.isInstallationRemoval)
                            if !removals.isEmpty, !renewedUsers.contains(user), await renew(user) {
                                renewedUsers.insert(user)
                                continue
                            }
                            parkedRemovals.formUnion(removals.compactMap { $0["messageId"]?.string })
                            let dropped = items.filter { !Self.isInstallationRemoval($0) }
                            if dropped.isEmpty { continue }
                            let attempts = dropped.compactMap { $0["messageId"]?.string }.map { requestsPerEvent[$0] ?? 0 }.max() ?? 0
                            let droppedIDs = Set(dropped.compactMap { $0["messageId"]?.string })
                            batch.removeAll { $0["messageId"]?.string.map { droppedIDs.contains($0) } == true }
                            removeFromSource(dropped, source)
                            let dropFailure = DeliveryFailure(status: 403, message: "identity not verified", code: "identity_not_verified", reason: failure.reason)
                            configuration.onError?(BatchFailure(error: dropFailure, events: Self.redactingToken(dropped), attempts: attempts))
                        }
                        if let current, refused.contains(current) {
                            // Renew once. A token the server refuses again cannot be fixed by renewing: hold the batch.
                            let renewed = renewedForCurrent ? false : await renew(current)
                            if !renewed {
                                return await holdBatch(batch, current: current, parked: parkedRemovals, source: source, failure: failure)
                            }
                            renewedForCurrent = true
                        } else if !parkedRemovals.isEmpty {
                            return await holdBatch(batch, current: current, parked: parkedRemovals, source: source, failure: failure)
                        }
                        continue
                    }
                }
                // A background window makes one attempt, never sleeps through a retry.
                if backgroundToken != nil && retryable { paused = true; return Delivered(result: .interrupted, remaining: batch) }
                if attempt >= configuration.retries && retryable && keepsExhaustedBatch {
                    return Delivered(result: .exhausted(failure), remaining: batch)
                }
                if attempt >= configuration.retries || !retryable {
                    configuration.onError?(BatchFailure(error: failure, events: Self.redactingToken(batch), attempts: requests))
                    conclude(batch)
                    return Delivered(result: .failed(failure), remaining: batch)
                }
                let sleep = sleep
                let delay = retryDelay(base: configuration.baseDelay, attempt: attempt, requested: failure.retryAfterMs)
                attempt += 1
                let pending = Task { try await sleep(delay) }
                backoff = pending
                do {
                    try await withTaskCancellationHandler { try await pending.value } onCancel: { pending.cancel() }
                } catch {
                    // Cancelling only the sleeper on background entry permits an immediate attempt.
                    if Task.isCancelled || stopped || (stopsOnOptOut && state.optedOut) || backgroundToken == nil { return Delivered(result: .interrupted, remaining: batch) }
                }
                backoff = nil
            }
        }
        // Every item was dropped for an unverified previous user: nothing is left to send.
        return Delivered(result: .acknowledged, remaining: batch)
    }
    /// Delivers the opt-out removals with the ordinary retry policy. True when none is left. One retryable
    /// failure cycle parks them: there is no timer and no background retry loop. 2xx and other 4xx end a
    /// removal for good.
    func deliverRemovals() async -> Bool {
        while !state.pendingRemovals.isEmpty {
            guard !Task.isCancelled, !stopped else { return false }
            let batch = Array(state.pendingRemovals.prefix(takeCount(state.pendingRemovals)))
            let delivery = await deliver(batch, source: .removals)
            switch delivery.result {
            case .acknowledged:
                removeFromSource(delivery.remaining, .removals)
                pruneTokens()
                persistDeliveryState()
            case .failed(let failure):
                if failure.retryable { removalParked = failure; return false }
                removeFromSource(delivery.remaining, .removals)
                pruneTokens()
                persistDeliveryState()
            case .held(let failure, let ms):
                // The current user's removal is never dropped for lack of a token: it is tried again after the hold.
                removalParked = failure
                removalHoldMs = ms
                return false
            case .exhausted, .interrupted: return false
            }
        }
        return true
    }
    func flushForInactivity(_ token: UUID = UUID()) async {
        await flushForBackground(token, pauseOnFailure: false)
    }
    func pauseForBackgroundExpiry() async {
        paused = true
        cancelTimer()
        let pending = cycle
        pending?.cancel(); backoff?.cancel()
        await pending?.value
    }
    func expireBackground(_ token: UUID) async {
        guard lifecycleToken == token else { return }
        await pauseForBackgroundExpiry()
    }
    func enterBackground(_ token: UUID) {
        guard lifecycleToken == token else { return }
        sawBackground = true
        backgroundToken = token
        backoff?.cancel()
    }
    func flushForBackground(_ token: UUID, pauseOnFailure: Bool = true) async {
        sawBackground = true
        guard !stopped, !state.optedOut else { return }
        lifecycleToken = token
        backgroundToken = pauseOnFailure ? token : nil
        paused = false
        if pauseOnFailure { backoff?.cancel() }
        try? await flush()
        if backgroundToken == token { backgroundToken = nil }
        if lifecycleToken == token { lifecycleToken = nil }
    }
    func resumeOnForeground() {
        lifecycleToken = nil; backgroundToken = nil; paused = false
        // A return from the background (not a launch) retries an opt-out removal parked by a failure.
        if sawBackground { sawBackground = false; triggerRemovals() }
        // The app is in use again, so a kept batch is tried now rather than after the rest of the pause.
        if pause.isRunning { pause.end(); beginCycle() }
        armTimer()
    }
}

/// Identity tokens, the hold, and the bookkeeping around them.
extension TranthorSDK {
    /// Whether identity tokens are in use: the app configured a provider, or has handed over a token through `identify`
    /// (remembered in the state file, because a refusal empties the cache). Without them the SDK
    /// batches exactly as it did before identity tokens existed.
    var identityInUse: Bool { configuration.identityTokenProvider != nil || state.identityTokenSupplied }
    /// The user whose events the app is producing now: the last identify, else the first user seen on an event.
    var currentUser: String? { state.userId ?? observedUser }
    /// How many of `queued` the next request takes. With identity in use no request carries more than ten users.
    func takeCount<S: Sequence>(_ queued: S) -> Int where S.Element == [String: JSONValue] {
        requestCut(queued, batchSize: configuration.batchSize, limitUsers: identityInUse)
    }
    /// The tokens for the users of a batch, one per user in the order they first appear, while the server would still
    /// accept them (it allows `exp` + 120 s). Anonymous events need none.
    func tokens(for batch: [[String: JSONValue]]) -> [String] {
        let nowMs = now()
        return distinctUsers(batch).compactMap { state.identityTokens.fresh(for: $0, nowMs: nowMs, minValidityMs: -tokenGraceMs) }
    }
    /// Keeps a token while its user is the current user (unless `keepCurrent` is false) or still has events queued, in
    /// flight or waiting as a removal, and while the server would still accept it (`exp` + 120 s). True when a token was
    /// removed, so the caller saves the state.
    @discardableResult
    func pruneTokens(keeping extra: [String] = [], keepCurrent: Bool = true) -> Bool {
        guard !state.identityTokens.isEmpty else { return false }
        var keep = Set(extra)
        if keepCurrent, let current = currentUser { keep.insert(current) }
        for queued in queue.events { if let user = itemUser(queued.event) { keep.insert(user) } }
        for item in state.pendingRemovals { if let user = itemUser(item) { keep.insert(user) } }
        let evicted = state.identityTokens.retain(keep)
        return state.identityTokens.evictExpired(nowMs: now()) || evicted
    }
    /// An `Installation Removed` the SDK itself queues: it names the push token it removes.
    static func isInstallationRemoval(_ item: [String: JSONValue]) -> Bool {
        item["event"]?.string == "Installation Removed" && item["properties"]?["token"]?.string?.isEmpty == false
    }
    func conclude(_ batch: [[String: JSONValue]]) {
        for item in batch { if let id = item["messageId"]?.string { requestsPerEvent.removeValue(forKey: id) } }
    }
    /// Takes items out of the queue (the batch in flight, at its head) or out of the opt-out removals, for good: their
    /// files are deleted, so a restart does not bring them back.
    func removeFromSource(_ items: [[String: JSONValue]], _ source: DeliverySource) {
        switch source {
        case .queue:
            var gone: [UInt64] = []
            for item in items {
                guard let id = item["messageId"]?.string,
                      let index = queue.events.prefix(inFlightCount).firstIndex(where: { $0.event["messageId"]?.string == id }) else { continue }
                gone.append(queue.events.remove(at: index).sequence)
                inFlightCount -= 1
            }
            deleteFiles(gone)
        case .removals:
            for item in items {
                if let id = item["messageId"]?.string, let index = state.pendingRemovals.firstIndex(where: { $0["messageId"]?.string == id }) {
                    state.pendingRemovals.remove(at: index)
                }
            }
            persistDeliveryState()
        }
        conclude(items)
    }
    /// Renews the current user's token through the provider before a batch that holds their events is sent, when it
    /// is missing or has less than a minute left. Whatever happens the batch is then sent with the tokens held.
    /// True when the provider supplied a token.
    func renewCurrentUserIfNeeded(_ batch: [[String: JSONValue]]) async -> Bool {
        guard configuration.identityTokenProvider != nil, let current = currentUser, distinctUsers(batch).contains(current),
              state.identityTokens.fresh(for: current, nowMs: now(), minValidityMs: renewBelowMs) == nil else { return false }
        return await renew(current)
    }
    /// Asks the provider for the user's token, waiting at most the timeout. True when it gave one. Any failure (an
    /// error, a timeout, nil) starts the backoff, during which the provider is not called. The token is never logged.
    func renew(_ user: String) async -> Bool {
        guard let provider = configuration.identityTokenProvider, now() >= providerBackoffUntilMs else { return false }
        let answer = await askProvider(provider, user: user)
        guard !stopped else { return false }
        guard let token = answer, !token.isEmpty else {
            // A wait ended by cancellation (background expiry, opt-out) is not a provider failure: no backoff.
            if Task.isCancelled { return false }
            providerBackoffUntilMs = now() + configuration.identityProviderBackoffMs
            return false
        }
        state.identityTokens.set(token, for: user)
        persistDeliveryState()
        return true
    }
    private func askProvider(_ provider: @escaping @Sendable (String) async throws -> String?, user: String) async -> String? {
        let wait = ProviderWait()
        let timeoutMs = configuration.identityProviderTimeoutMs
        let sleep = sleep
        // Unstructured tasks, not a task group: a group would wait for a provider that never answers.
        wait.add(Task.detached { wait.finish((try? await provider(user)) ?? nil) })
        wait.add(Task.detached { try? await sleep(timeoutMs); wait.finish(nil) })
        return await withTaskCancellationHandler {
            await withCheckedContinuation { wait.attach($0) }
        } onCancel: { wait.finish(nil) }
    }
    func notify(_ kind: Notice.Kind, count: Int? = nil, reason: String? = nil, message: String) {
        configuration.onNotice?(Notice(kind: kind, count: count, reason: reason, message: message))
    }
    static func refusalMessage(_ reason: String?) -> String {
        let unfixable: Set<String> = ["lifetime", "malformed", "audience", "workspace", "unknown_key", "signature"]
        if let reason, unfixable.contains(reason) {
            return "The server refused the identity token (\(reason)). Renewing cannot fix this: check the code that signs tokens"
        }
        return "The server refused the identity token\(reason.map { " (\($0))" } ?? ""), and no valid token could be had for the current user; the batch is held"
    }
    /// A batch held for the current user's missing token, or for a removal that cannot be sent: the items of other users,
    /// and anonymous ones, are sent separately first in one request, so one user's token does not keep back anyone
    /// else's events. The held items (the current user's, and the removals in `parked`) keep their place at the head of
    /// the queue and are tried again after the provider backoff. Each hold is one `identity-refused` notice, a held removal's included: nothing is given up,
    /// so `onError` stays silent.
    func holdBatch(_ batch: [[String: JSONValue]], current: String?, parked: Set<String>, source: DeliverySource, failure: DeliveryFailure) async -> Delivered {
        notify(.identityRefused, reason: failure.reason, message: Self.refusalMessage(failure.reason))
        func isHeld(_ item: [String: JSONValue]) -> Bool {
            (current != nil && itemUser(item) == current) || item["messageId"]?.string.map { parked.contains($0) } == true
        }
        let heldItems = batch.filter(isHeld)
        let others = batch.filter { !isHeld($0) }
        let holdResult = Delivered(result: .held(failure, configuration.identityProviderBackoffMs), remaining: heldItems)
        guard !others.isEmpty else { return holdResult }
        let sent = await deliver(others, source: source)
        switch sent.result {
        case .acknowledged, .failed:
            // Delivered, or reported as failed for good: either way they leave the queue.
            removeFromSource(sent.remaining, source)
            return holdResult
        case .interrupted, .held, .exhausted:
            let waiting = Set(sent.remaining.compactMap { $0["messageId"]?.string })
            let remaining = batch.filter { item in item["messageId"]?.string.map { waiting.contains($0) } == true || isHeld(item) }
            return Delivered(result: sent.result, remaining: remaining)
        }
    }
    /// Takes out of the queue and the opt-out removals every `Installation Removed` for `user` and `target` that is not in
    /// flight: the registration that was just queued replaces it.
    func supersedeRemovals(target: String, user: String) {
        func superseded(_ item: [String: JSONValue]) -> Bool {
            Self.isInstallationRemoval(item) && Self.installationTarget(item) == target && itemUser(item) == user
        }
        let gone = queue.events.enumerated().filter { $0.offset >= inFlightCount && superseded($0.element.event) }
        if !gone.isEmpty {
            let sequences = Set(gone.map(\.element.sequence))
            queue.events.removeAll { sequences.contains($0.sequence) }
            deleteFiles(Array(sequences))
        }
        if state.pendingRemovals.contains(where: superseded) {
            state.pendingRemovals.removeAll(where: superseded)
            persistDeliveryState()
        }
    }
    /// Ends the hold: the next attempt is made by an explicit flush or the hold's own wake-up.
    func startHold(_ ms: Double) {
        held = true
        holdGeneration &+= 1
        let generation = holdGeneration
        holdTask?.cancel()
        let sleep = sleep
        holdTask = Task { [weak self] in
            do { try await sleep(ms) } catch { return }
            await self?.holdEnded(generation)
        }
    }
    func holdEnded(_ generation: Int) {
        guard generation == holdGeneration, held else { return }
        held = false; holdTask = nil
        // A removal parked by the hold gets its new cycle too.
        if !state.pendingRemovals.isEmpty { removalParked = nil }
        beginCycle()
        armTimer()
    }
    func endHold() {
        held = false
        holdGeneration &+= 1
        holdTask?.cancel(); holdTask = nil
    }
    /// A 2xx can carry the server's counts of events it dropped or could not verify (Required and Monitor). They are
    /// surfaced once per response, with no token or user ID, so a dropped registration is not silent.
    func reportResponseNotes(_ notes: ResponseNotes) {
        if notes.dropped > 0 {
            notify(.eventsDropped, count: notes.dropped, message: "The server dropped \(notes.dropped) events. In Required mode this includes anonymous events that could change a customer: identify the user, with an identity token, before registering push or sending traits")
        }
        if notes.unverified > 0 {
            notify(.eventsUnverified, count: notes.unverified, message: "The server accepted \(notes.unverified) events that had no valid identity token")
        }
    }
}

/// Resolves once with the first answer, from either the provider or the timeout, and cancels the other.
private final class ProviderWait: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var continuation: CheckedContinuation<String?, Never>?
    private var early: String?
    private var tasks: [Task<Void, Never>] = []
    func attach(_ waiting: CheckedContinuation<String?, Never>) {
        let ready: (Bool, String?) = lock.withLock {
            if done { return (true, early) }
            continuation = waiting
            return (false, nil)
        }
        if ready.0 { waiting.resume(returning: ready.1) }
    }
    func add(_ task: Task<Void, Never>) {
        let cancelNow = lock.withLock { () -> Bool in
            if done { return true }
            tasks.append(task)
            return false
        }
        if cancelNow { task.cancel() }
    }
    func finish(_ value: String?) {
        let pending: (CheckedContinuation<String?, Never>?, [Task<Void, Never>])? = lock.withLock {
            guard !done else { return nil }
            done = true
            let waiting = continuation; continuation = nil
            if waiting == nil { early = value }
            let running = tasks; tasks = []
            return (waiting, running)
        }
        guard let pending else { return }
        pending.0?.resume(returning: value)
        for task in pending.1 { task.cancel() }
    }
}

func sleepMilliseconds(_ ms: Double) async throws {
    var remaining = ms
    while remaining > 0 {
        let part = min(remaining, 3_600_000)
        try await Task.sleep(nanoseconds: UInt64(part * 1_000_000))
        remaining -= part
    }
    try Task.checkCancellation()
}

/// The wait after consecutive exhausted cycles: 30 s, doubling each time, at most 5 minutes. Only an explicit
/// `flush()` or a return from the background attempts earlier. The count, the sleeping task and its generation
/// change together, so a pause cannot be ended without its late completion being ignored.
struct ExhaustionPause {
    /// How many cycles in a row ran out of retries.
    private var exhaustedCycles = 0
    private(set) var task: Task<Void, Never>?
    private var generation = 0
    var isRunning: Bool { task != nil }
    /// Counts one more exhausted cycle and starts its pause. `makeTask` returns the task that sleeps `delay`
    /// milliseconds and then reports `generation` to `finish`.
    mutating func start(_ makeTask: (_ generation: Int, _ delay: Double) -> Task<Void, Never>) {
        exhaustedCycles += 1
        generation &+= 1
        task = makeTask(generation, min(30_000 * Double(1 << min(exhaustedCycles - 1, 8)), 300_000))
    }
    /// True if the pause that ended is the current one; a pause that was ended earlier is ignored.
    mutating func finish(_ generation: Int) -> Bool {
        guard generation == self.generation else { return false }
        task = nil
        return true
    }
    /// Cancels a running pause. The count stays, so the next exhausted cycle waits longer.
    mutating func end() {
        generation &+= 1
        task?.cancel(); task = nil
    }
    /// Ends the pause and forgets the count: the next exhausted cycle waits 30 s again.
    mutating func reset() {
        end()
        exhaustedCycles = 0
    }
}
