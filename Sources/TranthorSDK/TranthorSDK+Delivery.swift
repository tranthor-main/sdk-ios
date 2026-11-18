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
        state.pendingRemovals.isEmpty ? (!state.optedOut && !queue.events.isEmpty && !pause.isRunning) : removalParked == nil
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
        guard timer == nil, cycle == nil, hasDeliverableWork, !stopped, !paused else { return }
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
        guard cycle == nil, !stopped, !paused, hasDeliverableWork else { return }
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
        while removalsDelivered && !queue.events.isEmpty && !Task.isCancelled && !stopped && !state.optedOut && !pause.isRunning {
            let batch = Array(queue.events.prefix(configuration.batchSize))
            inFlightCount = batch.count
            var terminal: DeliveryFailure?
            var acknowledged = false
            switch await deliver(batch.map(\.event), stopsOnOptOut: true, keepsExhaustedBatch: true) {
            case .acknowledged: acknowledged = true; pause.reset()
            case .failed(let failure):
                terminal = failure
                failWaiters(with: failure)
            case .exhausted(let failure):
                exhausted = true; unacknowledged = true
                failWaiters(with: failure)
            case .interrupted: unacknowledged = true
            }
            inFlightCount = 0
            if acknowledged || terminal != nil {
                let finished = Set(batch.map(\.sequence))
                queue.events.removeAll { finished.contains($0.sequence) }
                deleteFiles(Array(finished))
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
    enum DeliveryResult { case acknowledged, failed(DeliveryFailure), exhausted(DeliveryFailure), interrupted }
    /// Sends one batch, retrying retryable failures with backoff. A rejection is reported to `onError` once. When the
    /// retries run out the result is `.exhausted` if `keepsExhaustedBatch` (the caller keeps the events and `onError`
    /// stays silent), otherwise it is reported like a rejection. Opt-out removals do not keep an exhausted batch because
    /// they have their own retry rule: one failed cycle parks them until the next trigger, with no timed pause.
    /// `stopsOnOptOut` is false for opt-out removals, which are delivered after consent is withdrawn.
    func deliver(_ batch: [[String: JSONValue]], stopsOnOptOut: Bool, keepsExhaustedBatch: Bool = false) async -> DeliveryResult {
        defer { backoff = nil }
        for attempt in 0...configuration.retries {
            do {
                try Task.checkCancellation()
                try await transport.send(batch)
                // A 2xx acknowledges the batch even if cancellation raced with the response.
                return .acknowledged
            } catch {
                guard !Task.isCancelled, !stopped, !(stopsOnOptOut && state.optedOut) else { return .interrupted }
                let failure = (error as? DeliveryFailure) ?? DeliveryFailure(status: nil, message: "Delivery failed", retryAfterMs: 0)
                // A background window makes one attempt, never sleeps through a retry.
                if backgroundToken != nil && failure.retryable { paused = true; return .interrupted }
                if attempt >= configuration.retries && failure.retryable && keepsExhaustedBatch { return .exhausted(failure) }
                if attempt >= configuration.retries || !failure.retryable {
                    configuration.onError?(BatchFailure(error: failure, events: Self.redactingToken(batch), attempts: attempt + 1))
                    return .failed(failure)
                }
                let sleep = sleep
                let delay = retryDelay(base: configuration.baseDelay, attempt: attempt, requested: failure.retryAfterMs)
                let pending = Task { try await sleep(delay) }
                backoff = pending
                do {
                    try await withTaskCancellationHandler { try await pending.value } onCancel: { pending.cancel() }
                } catch {
                    // Cancelling only the sleeper on background entry permits an immediate attempt.
                    if Task.isCancelled || stopped || (stopsOnOptOut && state.optedOut) || backgroundToken == nil { return .interrupted }
                }
                backoff = nil
            }
        }
        return .interrupted
    }
    /// Delivers the opt-out removals with the ordinary retry policy. True when none is left. One retryable
    /// failure cycle parks them: there is no timer and no background retry loop. 2xx and other 4xx end a
    /// removal for good.
    func deliverRemovals() async -> Bool {
        while !state.pendingRemovals.isEmpty {
            guard !Task.isCancelled, !stopped else { return false }
            let batch = Array(state.pendingRemovals.prefix(configuration.batchSize))
            switch await deliver(batch, stopsOnOptOut: false) {
            case .acknowledged:
                state.pendingRemovals.removeFirst(min(batch.count, state.pendingRemovals.count))
                persistDeliveryState()
            case .failed(let failure):
                if failure.retryable { removalParked = failure; return false }
                state.pendingRemovals.removeFirst(min(batch.count, state.pendingRemovals.count))
                persistDeliveryState()
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
