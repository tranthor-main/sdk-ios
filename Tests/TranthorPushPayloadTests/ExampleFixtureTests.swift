import Foundation
import XCTest
@testable import TranthorPushPayload

/// Every checked-in simulator fixture must be a payload the SDK recognises and only use keys the
/// Tranthor server can produce.
final class ExampleFixtureTests: XCTestCase {
    private static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Examples/TranthorExample/Fixtures")
    private func rawText(_ name: String) throws -> String {
        try String(contentsOf: Self.directory.appendingPathComponent(name), encoding: .utf8)
    }
    private func fixtures() throws -> [(String, [String: Any])] {
        try FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "apns" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { ($0.lastPathComponent, try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: $0)) as? [String: Any])) }
    }
    func testEveryFixtureIsRecognisedAndUsesOnlyServerKeys() throws {
        let all = try fixtures()
        XCTAssertGreaterThanOrEqual(all.count, 4)
        let apsKeys: Set = ["alert", "mutable-content", "sound", "interruption-level", "category"]
        let alertKeys: Set = ["title", "subtitle", "body"]
        let markerKeys: Set = ["version", "deliveryId", "imageUrl", "badge", "test"]
        for (name, payload) in all {
            XCTAssertNotNil(PushNotification(userInfo: payload), name)
            let aps = try XCTUnwrap(payload["aps"] as? [String: Any], name)
            XCTAssertTrue(Set(aps.keys).isSubset(of: apsKeys), "\(name): \(aps.keys)")
            XCTAssertTrue(Set((aps["alert"] as? [String: Any] ?? [:]).keys).isSubset(of: alertKeys), name)
            // The server always sends the category, as the last key inside aps, so a dismissal is reported (customDismissAction).
            XCTAssertEqual(aps["category"] as? String, "TRANTHOR_PUSH", name)
            XCTAssertNotNil(try rawText(name).range(of: #""category":\s*"TRANTHOR_PUSH"\s*\}"#, options: .regularExpression), "\(name): category is the last aps key")
            XCTAssertNil(aps["badge"], "\(name): the server never sets aps.badge; the extension does the +1")
            let marker = try XCTUnwrap(payload["tranthor"] as? [String: Any], name)
            XCTAssertTrue(Set(marker.keys).isSubset(of: markerKeys), name)
            if marker["imageUrl"] != nil || marker["badge"] != nil { XCTAssertEqual(aps["mutable-content"] as? Int, 1, "\(name): needs the service extension") }
        }
    }
    func testFullFixtureExposesEveryNewKey() throws {
        let payload = try XCTUnwrap(try fixtures().first { $0.0 == "full-preview.apns" }?.1)
        let note = try XCTUnwrap(PushNotification(userInfo: payload))
        XCTAssertEqual(note.url, "tranthorexample://orders/42")
        XCTAssertEqual(note.data, ["orderId": "42", "campaign": "spring"])
        XCTAssertTrue(note.incrementsBadge)
        XCTAssertNotNil(note.imageURL)
    }
    func testBadgeFixtureAsksForTheIncrementOnly() throws {
        let payload = try XCTUnwrap(try fixtures().first { $0.0 == "badge-preview.apns" }?.1)
        let note = try XCTUnwrap(PushNotification(userInfo: payload))
        XCTAssertTrue(note.incrementsBadge); XCTAssertNil(note.imageURL); XCTAssertNil(note.url)
    }

    /// The server emits aps keys in a fixed order (buildApnsPayload: alert, sound, mutable-content,
    /// interruption-level, category), so a fixture that keeps that order is byte-faithful to what it sends.
    func testApsKeysFollowTheServersOrder() throws {
        let serverOrder = ["alert", "sound", "mutable-content", "interruption-level", "category"]
        var files = try fixtures().map { ($0.0, try rawText($0.0)) }
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        for name in ["full-server-payload.apns", "minimal-server-payload.apns"] {
            files.append((name, try String(contentsOf: tests.appendingPathComponent(name), encoding: .utf8)))
        }
        for (name, text) in files {
            let aps = try XCTUnwrap(text.range(of: #""aps""#), name)
            let end = try XCTUnwrap(text.range(of: #""tranthor""#), name)
            let block = String(text[aps.upperBound..<end.lowerBound])
            let positions = serverOrder.compactMap { key in block.range(of: "\"\(key)\"")?.lowerBound }
            XCTAssertEqual(positions, positions.sorted(), "\(name): aps keys must be in the server's order \(serverOrder)")
            XCTAssertGreaterThanOrEqual(positions.count, 3, name)
        }
    }
}
