import Foundation
import XCTest
@testable import TranthorPush

final class TranthorBadgeTests: XCTestCase {
    private func counter() throws -> BadgeCounter {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("badge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return BadgeCounter(directory: dir)
    }
    private actor Icon { var values: [Int] = []; func apply(_ v: Int) { values.append(v) } }

    func testSetUpdatesTheIconAndTheExtensionsCount() async throws {
        let counter = try counter(), icon = Icon()
        counter.set(6)
        try await TranthorBadge.set(0, counter: counter) { await icon.apply($0) }
        XCTAssertEqual(counter.value, 0)
        let values = await icon.values
        XCTAssertEqual(values, [0])
        XCTAssertEqual(counter.increment(), 1, "The next push the extension badges is 1")
    }
    func testNegativeCountBecomesZero() async throws {
        let counter = try counter(), icon = Icon()
        try await TranthorBadge.set(-3, counter: counter) { await icon.apply($0) }
        let values = await icon.values
        XCTAssertEqual(values, [0]); XCTAssertEqual(counter.value, 0)
    }
    func testMissingCounterStillUpdatesTheIconThenReports() async {
        let icon = Icon()
        do { try await TranthorBadge.set(2, counter: nil) { await icon.apply($0) }; XCTFail("Expected an error") }
        catch { XCTAssertEqual(error as? TranthorBadgeError, .counterUnavailable) }
        let values = await icon.values
        XCTAssertEqual(values, [2])
    }
    func testIconFailureSurfaces() async throws {
        struct Boom: Error {}
        let counter = try counter()
        do { try await TranthorBadge.set(1, counter: counter) { _ in throw Boom() }; XCTFail("Expected an error") }
        catch { XCTAssertTrue(error is Boom) }
    }
}

/// B2: a push landing while the icon is being set must not leave the extension's count ahead of the icon.
final class TranthorBadgeWindowTests: XCTestCase {
    private actor Log { var items: [String] = []; var raced: Int?; func add(_ s: String) { items.append(s) }; func race(_ v: Int?) { raced = v } }
    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("badge-window-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testAPushThatLandsWhileTheIconIsBeingSetCountsFromTheNewValueAfterwards() async throws {
        let dir = try directory(), log = Log()
        let counter = BadgeCounter(directory: dir)
        counter.set(9)
        // The extension process increments while the app is between the counter write and the icon write.
        let push = Task.detached { () -> Int? in
            try await Task.sleep(nanoseconds: 50_000_000)
            let count = BadgeCounter(directory: dir).increment()
            await log.add("extension increments")
            return count
        }
        try await TranthorBadge.set(0, counter: counter) { value in
            try await Task.sleep(for: .milliseconds(200))
            await log.add("icon set to \(value)")
        }
        let raced = try await push.value
        let items = await log.items
        XCTAssertEqual(items, ["icon set to 0", "extension increments"], "The extension's +1 waited for the icon write")
        XCTAssertEqual(raced, 1, "It badges the push 1, consistent with the icon the app just cleared")
        XCTAssertEqual(counter.value, 1)
    }
    func testIfTheCounterCannotBeLockedTheIconIsStillSetAndTheErrorIsReported() async throws {
        let dir = try directory(), log = Log()
        let holder = BadgeCounter(directory: dir)
        try await holder.withExclusiveAccess { _ in
            let impatient = BadgeCounter(directory: dir, lockTimeout: 0.1)
            do {
                try await TranthorBadge.set(4, counter: impatient) { await log.add("icon \($0)") }
                XCTFail("Expected an error")
            } catch { XCTAssertEqual(error as? TranthorBadgeError, .counterUnavailable) }
        }
        let items = await log.items
        XCTAssertEqual(items, ["icon 4"])
    }
    func testACancelledSetThatWaitsForTheLockStillSetsTheIconAndReportsCounterUnavailable() async throws {
        let dir = try directory(), log = Log()
        let holder = BadgeCounter(directory: dir)
        try await holder.withExclusiveAccess { _ in
            // The lock is held and the timeout is long, so only the cancellation ends this set's wait.
            let waiting = BadgeCounter(directory: dir, lockTimeout: 60)
            let set = Task { try await TranthorBadge.set(4, counter: waiting) { await log.add("icon \($0)") } }
            set.cancel()
            do { try await set.value; XCTFail("Expected an error") }
            catch { XCTAssertEqual(error as? TranthorBadgeError, .counterUnavailable, "Cancellation while waiting is a lock that could not be had") }
        }
        let items = await log.items
        XCTAssertEqual(items, ["icon 4"], "The icon is set even though the waiting Task was cancelled")
        XCTAssertEqual(BadgeCounter(directory: dir).value, 0, "The count was not stored, as the error says")
    }
}
