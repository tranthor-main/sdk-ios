import Foundation
import XCTest
@testable import TranthorPushPayload

final class BadgeCounterTests: XCTestCase {
    private func make() throws -> (BadgeCounter, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("badge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return (BadgeCounter(directory: dir), dir)
    }
    func testStartsAtZeroAndIncrementsByOne() throws {
        let (counter, _) = try make()
        XCTAssertEqual(counter.value, 0)
        XCTAssertEqual(counter.increment(), 1)
        XCTAssertEqual(counter.increment(), 2)
        XCTAssertEqual(counter.value, 2)
    }
    func testSetResetsTheCountTheAppJustPutOnTheIcon() throws {
        let (counter, _) = try make()
        counter.increment(); counter.increment()
        XCTAssertTrue(counter.set(0))
        XCTAssertEqual(counter.value, 0)
        XCTAssertEqual(counter.increment(), 1)
        XCTAssertTrue(counter.set(7))
        XCTAssertEqual(counter.increment(), 8)
    }
    func testNegativeSetClampsToZeroAndTheCountSaturates() throws {
        let (counter, _) = try make()
        XCTAssertTrue(counter.set(-5)); XCTAssertEqual(counter.value, 0)
        XCTAssertTrue(counter.set(Int.max)); XCTAssertEqual(counter.increment(), BadgeCounter.maximum)
    }
    func testCorruptFileCountsAsZero() throws {
        let (counter, dir) = try make()
        counter.increment()
        try Data("not a number".utf8).write(to: dir.appendingPathComponent("badge-count"))
        XCTAssertEqual(counter.value, 0)
        XCTAssertEqual(counter.increment(), 1)
    }
    func testSeparateHandlesDoNotLoseIncrementsUnderContention() throws {
        let (_, dir) = try make()
        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            XCTAssertNotNil(BadgeCounter(directory: dir).increment()) // A new descriptor each time, like another process.
        }
        XCTAssertEqual(BadgeCounter(directory: dir).value, 200)
    }
    func testEmptyGroupGivesNoCounter() {
        XCTAssertNil(BadgeCounter(appGroupIdentifier: ""))
    }
    #if os(iOS)
    /// macOS hands out a container for any group name; iOS (device and Simulator) does so only for the entitled ones.
    func testGroupMissingFromTheEntitlementGivesNoCounter() {
        XCTAssertNil(BadgeCounter(appGroupIdentifier: "group.invalid.\(UUID().uuidString)"))
    }
    #endif
}

/// B2: the lock can be held across several steps, and nobody waits on it forever.
final class BadgeCounterLockTests: XCTestCase {
    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("badge-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }
    private actor Log { var items: [String] = []; func add(_ s: String) { items.append(s) } }

    func testAnIncrementWaitsForAnExclusiveHolderThenCountsFromItsValue() async throws {
        let dir = try directory(), log = Log()
        let holder = BadgeCounter(directory: dir)
        let other = Task.detached { () -> Int? in
            try await Task.sleep(nanoseconds: 50_000_000) // Start once the holder has the lock.
            let value = BadgeCounter(directory: dir).increment() // A separate handle, like the extension process.
            await log.add("increment")
            return value
        }
        try await holder.withExclusiveAccess { locked in
            XCTAssertTrue(locked.set(7))
            try await Task.sleep(for: .milliseconds(150))
            await log.add("holder done")
        }
        let result = try await other.value
        let items = await log.items
        XCTAssertEqual(items, ["holder done", "increment"], "The increment ran only after the holder released the lock")
        XCTAssertEqual(result, 8)
    }
    func testWaitingForTheLockIsBoundedAndLeavesTheCountAlone() async throws {
        let dir = try directory()
        let holder = BadgeCounter(directory: dir)
        try await holder.withExclusiveAccess { locked in
            XCTAssertTrue(locked.set(3))
            let impatient = BadgeCounter(directory: dir, lockTimeout: 0.1)
            let started = Date()
            XCTAssertNil(impatient.increment(), "An extension must not stall for its 30 seconds behind the app")
            XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        }
        XCTAssertEqual(BadgeCounter(directory: dir).value, 3)
    }
    func testAnExclusiveAccessThatCannotGetTheLockInTimeThrows() async throws {
        let dir = try directory()
        let holder = BadgeCounter(directory: dir)
        try await holder.withExclusiveAccess { _ in
            do {
                try await BadgeCounter(directory: dir, lockTimeout: 0.1).withExclusiveAccess { _ in XCTFail("Must not run unlocked") }
                XCTFail("Expected a timeout")
            } catch { XCTAssertEqual(error as? BadgeCounter.LockError, .timedOut) }
        }
    }
}
