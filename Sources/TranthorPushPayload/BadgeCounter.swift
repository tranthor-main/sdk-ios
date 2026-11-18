import Foundation

/// The app-icon badge count that a Notification Service Extension needs and iOS does not expose to it.
///
/// There is no package API that tells an app extension the current badge, so the SDK keeps its own
/// count in a small file in the shared **App Group container**. The extension adds one
/// (``increment()``) and sets `UNMutableNotificationContent.badge` to the result; the app calls
/// ``set(_:)`` (through `TranthorBadge`) whenever it changes the icon badge, e.g. to clear it.
///
/// A plain file under `flock(2)` is used rather than shared `UserDefaults`, because a
/// read-modify-write on `UserDefaults` is not atomic across the app and extension processes.
package struct BadgeCounter: Sendable {
    /// The largest count the counter stores: it saturates here instead of growing without bound.
    package static let maximum = 99_999
    private let fileURL: URL
    private let lockTimeout: TimeInterval

    /// The counter in `appGroupIdentifier`'s container, or nil when the group is empty, not in the
    /// process's App Groups entitlement, or its container cannot be created.
    package init?(appGroupIdentifier: String) {
        guard !appGroupIdentifier.isEmpty,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else { return nil }
        let directory = container.appendingPathComponent("TranthorPush", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else { return nil }
        fileURL = directory.appendingPathComponent("badge-count")
        lockTimeout = 2
    }
    /// For tests in this package: a counter in an ordinary directory.
    package init(directory: URL, lockTimeout: TimeInterval = 2) {
        fileURL = directory.appendingPathComponent("badge-count"); self.lockTimeout = lockTimeout
    }

    package enum LockError: Error, Sendable, Equatable { case timedOut }

    /// The count read and written while the lock is held by `withExclusiveAccess`.
    package struct Locked {
        let descriptor: Int32
        package var value: Int { BadgeCounter.read(descriptor) }
        package func set(_ count: Int) -> Bool { BadgeCounter.write(descriptor, max(0, min(count, BadgeCounter.maximum))) }
    }
    /// Runs `body` while holding the counter's lock, so an increment from the extension waits until it returns.
    /// The app uses it to change the count and the icon badge as one step. Throws `LockError.timedOut` (without
    /// running `body`) if another process keeps the lock for more than the lock timeout, or if the calling Task
    /// is cancelled while it waits for the lock (a `CancellationError` thrown by `body` itself passes through).
    package func withExclusiveAccess<T>(_ body: (Locked) async throws -> T) async throws -> T {
        let deadline = Date().addingTimeInterval(lockTimeout)
        while true {
            if let descriptor = tryLock() {
                defer { flock(descriptor, LOCK_UN); close(descriptor) }
                return try await body(Locked(descriptor: descriptor))
            }
            guard Date() < deadline else { throw LockError.timedOut }
            // A Task cancelled while it waits has stopped waiting: the lock was not had, like a timeout.
            do { try await Task.sleep(nanoseconds: 2_000_000) } catch { throw LockError.timedOut }
        }
    }

    /// The stored count; 0 when nothing is stored, the file is damaged or the lock could not be had in time.
    package var value: Int { locked { $1 } ?? 0 }
    /// Adds one and returns the new count, or nil if the file could not be locked (within the lock timeout,
    /// so an extension never waits out its 30 seconds behind the app) or written.
    @discardableResult
    package func increment() -> Int? { update { min($0 + 1, Self.maximum) } }
    /// Replaces the count (negative values become 0). Returns whether it was stored.
    @discardableResult
    package func set(_ count: Int) -> Bool { update { _ in max(0, min(count, Self.maximum)) } != nil }

    private func update(_ change: (Int) -> Int) -> Int? {
        var result: Int?
        _ = locked { descriptor, current in
            let next = change(current)
            if Self.write(descriptor, next) { result = next }
            return current
        }
        return result
    }

    /// Opens the file and takes the exclusive lock without blocking. Nil if another handle holds it.
    private func tryLock() -> Int32? {
        let descriptor = open(fileURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); return nil }
        return descriptor
    }
    /// Takes the lock, polling until `lockTimeout`, parses the count, runs `body` and unlocks.
    private func locked(_ body: (Int32, Int) -> Int) -> Int? {
        let deadline = Date().addingTimeInterval(lockTimeout)
        var held = tryLock()
        while held == nil, Date() < deadline { usleep(2_000); held = tryLock() }
        guard let descriptor = held else { return nil }
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        return body(descriptor, Self.read(descriptor))
    }
    fileprivate static func read(_ descriptor: Int32) -> Int {
        var buffer = [UInt8](repeating: 0, count: 32)
        let count = pread(descriptor, &buffer, buffer.count, 0)
        let stored = count > 0 ? String(decoding: buffer.prefix(count), as: UTF8.self) : ""
        return Int(stored).map { max(0, min($0, maximum)) } ?? 0
    }
    fileprivate static func write(_ descriptor: Int32, _ value: Int) -> Bool {
        let bytes = Array(String(value).utf8)
        return ftruncate(descriptor, 0) == 0 && pwrite(descriptor, bytes, bytes.count, 0) == bytes.count
    }
}
