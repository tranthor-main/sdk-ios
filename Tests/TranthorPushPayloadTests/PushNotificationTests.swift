import Foundation
import XCTest
@testable import TranthorPushPayload

/// The wire shape is the payload the Tranthor server sends for an iPhone.
final class PushNotificationTests: XCTestCase {
    static func fixture(_ name: String) throws -> [AnyHashable: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "apns", subdirectory: "Fixtures"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [AnyHashable: Any])
    }

    func testFullServerPayloadExposesLinkDataImageAndBadge() throws {
        let note = try XCTUnwrap(PushNotification(userInfo: Self.fixture("full-server-payload")))
        XCTAssertEqual(note.deliveryID, "8c0fAbC_123-xyz")
        XCTAssertEqual(note.imageURL, "https://images.example.test/a.png")
        XCTAssertEqual(note.url, "myapp://orders/42")
        XCTAssertTrue(note.incrementsBadge)
        XCTAssertEqual(note.data, ["orderId": "42", "campaign": "spring"])
    }
    func testMinimalPayloadHasNoOptionalParts() throws {
        let note = try XCTUnwrap(PushNotification(userInfo: Self.fixture("minimal-server-payload")))
        XCTAssertEqual(note.deliveryID, "d1")
        XCTAssertNil(note.imageURL); XCTAssertNil(note.url)
        XCTAssertFalse(note.incrementsBadge)
        XCTAssertEqual(note.data, [:])
    }
    func testBadgeIsOnlyTheExactIncrementValue() throws {
        for value in [1, true, "set", "INCREMENT", ""] as [Any] {
            let note = try XCTUnwrap(PushNotification(userInfo: ["tranthor": ["version": 1, "deliveryId": "d", "badge": value]]))
            XCTAssertFalse(note.incrementsBadge, "\(value)")
        }
    }
    func testReservedAndNonStringKeysNeverBecomeData() throws {
        let note = try XCTUnwrap(PushNotification(userInfo: [
            "aps": ["alert": "x"], "tranthor": ["version": 1, "deliveryId": "d"], "url": "https://x.test",
            "title": "t", "body": "b", "channelId": "c", "from": "f", "message_type": "m",
            "google.c.a.e": "1", "gcm.n.e": "1", "count": 3, "flag": true, "nested": ["a": "b"], "kept": "yes",
        ]))
        XCTAssertEqual(note.data, ["kept": "yes"])
        XCTAssertEqual(note.url, "https://x.test")
    }
    func testNonStringOrEmptyUrlIsIgnored() throws {
        for value in [42, ["a"], ""] as [Any] {
            let note = try XCTUnwrap(PushNotification(userInfo: ["tranthor": ["version": 1, "deliveryId": "d"], "url": value]))
            XCTAssertNil(note.url, "\(value)")
        }
    }
    func testMarkerRulesAreUnchanged() {
        for marker in [["version": true, "deliveryId": "d"], ["version": "1", "deliveryId": "d"], ["version": 2, "deliveryId": "d"],
                       ["version": 1, "deliveryId": " "], ["version": 1, "deliveryId": "a b"],
                       ["version": 1, "deliveryId": String(repeating: "a", count: 129)]] as [[String: Any]] {
            XCTAssertNil(PushNotification(userInfo: ["tranthor": marker]), "\(marker)")
        }
        XCTAssertNil(PushNotification(userInfo: ["url": "https://x.test"]))
    }
}
