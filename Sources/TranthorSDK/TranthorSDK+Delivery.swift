import Foundation
import os

/// Delivery: the flush timer, attempt cycles and retries, the opt-out removal queue, and the background and foreground hooks.
extension TranthorSDK {
    /// One new attempt cycle for undelivered opt-out removals (app start, foreground, optIn, optOut).
    func triggerRemovals() {
        guard !state.pendingRemovals.isEmpty else { return }
        removalTriggers &+= 1
        removalParked = nil
        beginCycle()
    }
    /// The delivery cycle's work: undelivered removals always, ordinary events only while opted in and
    /// only once no removal is waiting.
    var hasDeliverableWork: Bool {
        state.pendingRemovals.isEmpty ? (!state.optedOut && !state.queued.isEmpty) : removalParked == nil
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
    func runCycle() async {
        let triggersAtStart = removalTriggers
        let removalsDelivered = state.pendingRemovals.isEmpty ? true : await deliverRemovals()
        while removalsDelivered && !state.queued.isEmpty && !Task.isCancelled && !stopped && !state.optedOut {
            state.active = Array(state.queued.prefix(configuration.batchSize))
            state.queued.removeFirst(state.active.count)
            persistDeliveryState()
            var terminal: DeliveryFailure?
            var acknowledged = false
            switch await deliver(state.active, stopsOnOptOut: true) {
            case .acknowledged: acknowledged = true
            case .failed(let failure):
                terminal = failure
                for index in waiters.indices { if waiters[index].failure == nil { waiters[index].failure = failure } }
            case .interrupted: break
            }
            if acknowledged || terminal != nil {
                state.active = []
                persistDeliveryState()
            }
            // Never advance to another batch while this one remains unacknowledged.
            if !acknowledged && terminal == nil { break }
            if Task.isCancelled || stopped || state.optedOut || paused { break }
            if terminal?.retryable == true { break }
        }
        // This is the sole recovery point for an unacknowledged batch. Cancellation is
        // cycle-local and cannot be undone by a foreground notification or flush await.
        let cancelled = Task.isCancelled || stopped || paused || !state.active.isEmpty
        if !state.active.isEmpty && !state.optedOut {
            state.queued = state.active + state.queued
            state.active = []
            persistDeliveryState()
        }
        backoff = nil
        cycle = nil
        if let failure = removalParked, !state.pendingRemovals.isEmpty {
            for index in waiters.indices where waiters[index].failure == nil { waiters[index].failure = failure }
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
    enum DeliveryResult { case acknowledged, failed(DeliveryFailure), interrupted }
    /// Sends one batch, retrying retryable failures with backoff. A failure that ends the attempts is reported to
    /// `onError` once. `stopsOnOptOut` is false for opt-out removals, which are delivered after consent is withdrawn.
    func deliver(_ batch: [[String: JSONValue]], stopsOnOptOut: Bool) async -> DeliveryResult {
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
            case .interrupted: return false
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
        // A return to the foreground (not a launch) retries an opt-out removal parked by a failure.
        if sawBackground { sawBackground = false; triggerRemovals() }
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
