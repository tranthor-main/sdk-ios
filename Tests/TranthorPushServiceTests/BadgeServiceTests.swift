import Foundation
import UserNotifications
import XCTest
import TranthorPushPayload
@testable import TranthorPushService

/// `tranthor.badge == "increment"` makes the extension set the badge to the App Group count + 1.
final class BadgeServiceTests: XCTestCase {
    private func counter() throws -> BadgeCounter {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("badge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return BadgeCounter(directory: dir)
    }
    private func request(_ id: String = "d1", badge: Bool = true, image: String? = nil, title: String = "Hello") -> UNNotificationRequest {
        var marker: [String: Any] = ["version": 1, "deliveryId": id]
        if badge { marker["badge"] = "increment" }
        if let image { marker["imageUrl"] = image }
        let content = UNMutableNotificationContent(); content.title = title; content.userInfo = ["tranthor": marker]
        return UNNotificationRequest(identifier: id, content: content, trigger: nil)
    }
    private func service(_ counter: BadgeCounter?, load: @escaping @Sendable (URL, RichImageConfiguration) async throws -> URL = { _, _ in throw RichImageError.invalidResponse }) throws -> TranthorRichPush {
        TranthorRichPush(configuration: try RichImageConfiguration(allowedHosts: ["images.example.test"]), load: load, badgeCounter: counter)
    }
    private final class Box: @unchecked Sendable {
        private let lock = NSLock(); private var items: [UNNotificationContent] = []
        func add(_ c: UNNotificationContent) { lock.lock(); items.append(c); lock.unlock() }
        var all: [UNNotificationContent] { lock.lock(); defer { lock.unlock() }; return items }
    }

    func testBadgeOnlyPushIsHandledAndBadgeIsCountPlusOne() throws {
        let counter = try counter(); counter.set(4)
        let service = try service(counter), box = Box()
        XCTAssertTrue(service.didReceive(request()) { box.add($0) })
        XCTAssertEqual(box.all.count, 1)
        XCTAssertEqual(box.all.first?.badge, 5)
        XCTAssertEqual(box.all.first?.title, "Hello")
        XCTAssertEqual(counter.value, 5)
    }
    func testEachRequestIncrementsOnce() throws {
        let counter = try counter()
        let service = try service(counter), box = Box()
        for id in ["a", "b", "c"] { XCTAssertTrue(service.didReceive(request(id)) { box.add($0) }) }
        XCTAssertEqual(box.all.map { $0.badge?.intValue }, [1, 2, 3])
    }
    func testBadgeSurvivesAnImageFailure() async throws {
        let counter = try counter(); counter.set(9)
        let service = try service(counter), done = expectation(description: "delivered"), box = Box()
        XCTAssertTrue(service.didReceive(request(image: "https://images.example.test/a.png")) { box.add($0); done.fulfill() })
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(box.all.count, 1)
        XCTAssertEqual(box.all.first?.badge, 10, "A failed image download must still apply the badge")
        XCTAssertEqual(box.all.first?.title, "Hello")
    }
    func testAnInvalidAllowedImageHostStillAppliesTheBadgeAndShowsNoImage() throws {
        for host in ["https://cdn.x.com", "cdn.x.com:443"] {
            let counter = try counter()
            let service = TranthorNotificationServiceExtension.makeProcessor(allowedHosts: [host], badgeCounter: counter)
            let box = Box()
            XCTAssertTrue(service.didReceive(request(image: "https://cdn.x.com/a.png")) { box.add($0) })
            XCTAssertEqual(box.all.first?.badge, 1, "\(host): the badge +1 still applies")
            XCTAssertTrue(box.all.first?.attachments.isEmpty == true, "\(host): no image without a valid allow-list")
        }
    }
    func testBadgeSurvivesADisallowedImageHost() throws {
        let counter = try counter()
        let service = try service(counter), box = Box()
        XCTAssertTrue(service.didReceive(request(image: "https://evil.test/a.png")) { box.add($0) })
        XCTAssertEqual(box.all.first?.badge, 1)
    }
    func testBadgeSurvivesExpiryExactlyOnce() async throws {
        let counter = try counter()
        let gate = Gate()
        let service = try service(counter, load: { _, _ in await gate.wait(); throw CancellationError() }), box = Box()
        XCTAssertTrue(service.didReceive(request(image: "https://images.example.test/a.png")) { box.add($0) })
        service.serviceExtensionTimeWillExpire()
        XCTAssertEqual(box.all.count, 1)
        XCTAssertEqual(box.all.first?.badge, 1)
        XCTAssertEqual(counter.value, 1)
        await gate.open()
    }
    func testNoBadgeRequestLeavesTheBadgeAndCounterAlone() throws {
        let counter = try counter(); counter.set(3)
        let service = try service(counter), box = Box()
        XCTAssertFalse(service.didReceive(request(badge: false)) { box.add($0) }, "Nothing to do: the host or base class completes")
        XCTAssertEqual(counter.value, 3)
        XCTAssertEqual(box.all.count, 0)
    }
    func testNoAppGroupMeansNoBadgeChange() throws {
        let service = try service(nil), box = Box()
        XCTAssertFalse(service.didReceive(request()) { box.add($0) })
        XCTAssertEqual(box.all.count, 0)
    }
    func testForeignPayloadIsNotTouched() throws {
        let counter = try counter()
        let content = UNMutableNotificationContent(); content.userInfo = ["tranthor": ["version": 2, "deliveryId": "x", "badge": "increment"]]
        let service = try service(counter)
        XCTAssertFalse(service.didReceive(UNNotificationRequest(identifier: "x", content: content, trigger: nil)) { _ in })
        XCTAssertEqual(counter.value, 0)
    }
    func testBaseClassDefaultsToNoAppGroup() {
        XCTAssertNil(TranthorNotificationServiceExtension().appGroupIdentifier)
    }
}

private actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    func wait() async { if isOpen { return }; await withCheckedContinuation { waiters.append($0) } }
    func open() { isOpen = true; waiters.forEach { $0.resume() }; waiters = [] }
}
