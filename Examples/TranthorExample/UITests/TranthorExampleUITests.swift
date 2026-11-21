// Linking the system framework lets Xcode 27 inspect the empty App Intents metadata without a warning.
#if canImport(AppIntents)
import AppIntents
#endif
import Foundation
import XCTest

@MainActor
final class TranthorExampleUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
        executionTimeAllowance = 90
        let host = try XCTUnwrap(ProcessInfo.processInfo.environment["TRANTHOR_HOST"])
        XCTAssertTrue(host.hasPrefix("http://127.0.0.1:"))
        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(host)/control/reset")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    func testPushPreviewUsesRealNotificationDelegateAndTaggedIngestion() async throws {
        try await checkForegroundPreview(button: "pushPreview")
    }
    func testImagePreviewSchedulesAttachmentAndTaggedIngestion() async throws {
        try await checkForegroundPreview(button: "pushImagePreview")
    }
    private func checkForegroundPreview(button: String) async throws {
        let host = try XCTUnwrap(ProcessInfo.processInfo.environment["TRANTHOR_HOST"])
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment = ["TRANTHOR_HOST": host, "TRANTHOR_WRITE_KEY": "conformance-fixture", "TRANTHOR_FLUSH_INTERVAL_MS": "500"]
        app.launch()
        let status = app.staticTexts["configurationStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Configured"), object: status)], timeout: 10)
        let preview = app.buttons[button]
        for _ in 0..<10 { if preview.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(preview.isHittable)
        preview.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 4) { allow.tap() }
        // The 500ms core timer sends the observed event. Poll only the mock control API;
        // a successful empty flush or a visible alert alone cannot prove ingestion.
        let url = try XCTUnwrap(URL(string: "\(host)/control/requests"))
        var records: [Request] = []
        for _ in 0..<150 {
            let (data, _) = try await URLSession.shared.data(from: url)
            records = try JSONDecoder().decode(Records.self, from: data).requests
            if !records.isEmpty && records.allSatisfy({ $0.body != nil }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(records.count, 1)
        let event = try XCTUnwrap(records.first?.body?.batch.first)
        // The SDK reports a foreground observation as the reserved Push Received claim: only the deliveryId.
        XCTAssertEqual(event.event, "Push Received")
        XCTAssertTrue(event.properties.deliveryId?.hasPrefix("preview-") == true)
        XCTAssertNil(event.properties.liveTest)
        XCTAssertNotNil(event.messageId.flatMap(UUID.init(uuidString:)))
        if button == "pushImagePreview" {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "Rich image local notification"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        app.terminate()
    }

    func testPushOpenedFromHomeUsesResponseDelegateAndTaggedIngestion() async throws {
        let host = try XCTUnwrap(ProcessInfo.processInfo.environment["TRANTHOR_HOST"])
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment = ["TRANTHOR_HOST": host, "TRANTHOR_WRITE_KEY": "conformance-fixture", "TRANTHOR_FLUSH_INTERVAL_MS": "500"]
        app.launch()
        let status = app.staticTexts["configurationStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Configured"), object: status)], timeout: 10)
        let permission = app.buttons["pushPermission"]
        for _ in 0..<10 { if permission.isHittable { break }; app.swipeUp() }
        permission.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 4) { allow.tap() }
        app.buttons["pushPreview"].tap()
        let previewId = app.staticTexts["pushPreviewId"]
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", "Preview ID: preview-"), object: previewId)], timeout: 5)
        let deliveryId = String(previewId.label.dropFirst("Preview ID: ".count))
        XCUIDevice.shared.press(.home)
        let banner = springboard.staticTexts["Tranthor push preview \(deliveryId.suffix(8))"].firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 12), springboard.debugDescription)
        banner.tap()
        let url = try XCTUnwrap(URL(string: "\(host)/control/requests"))
        var records: [Request] = []
        for _ in 0..<150 {
            let (data, _) = try await URLSession.shared.data(from: url)
            records = try JSONDecoder().decode(Records.self, from: data).requests
            if !records.isEmpty && records.allSatisfy({ $0.body != nil }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(records.count, 1)
        let event = try XCTUnwrap(records.first?.body?.batch.first)
        XCTAssertEqual(event.event, "Push Opened")
        XCTAssertEqual(event.properties.deliveryId, deliveryId)
        XCTAssertNil(event.properties.actionIdentifier)
        app.terminate()
    }

    /// The SDK registers the TRANTHOR_PUSH category (customDismissAction) in the real notification center, merged
    /// with the example's own category. (Driving a real dismissal from Notification Center is not automated.)
    func testBoundPushRegistersTheDismissCategoryMergedWithTheHostsCategory() async throws {
        let host = try XCTUnwrap(ProcessInfo.processInfo.environment["TRANTHOR_HOST"])
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment = ["TRANTHOR_HOST": host, "TRANTHOR_WRITE_KEY": "conformance-fixture", "TRANTHOR_FLUSH_INTERVAL_MS": "500"]
        app.launch()
        let status = app.staticTexts["configurationStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Configured"), object: status)], timeout: 10)
        let category = app.staticTexts["pushCategoryStatus"]
        for _ in 0..<10 { if category.exists && category.isHittable { break }; app.swipeUp() }
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "TRANTHOR_PUSH registered with customDismissAction; host category kept"), object: category)], timeout: 10)
        app.terminate()
    }

    func testTaggedTrackBackgroundFlushWithSlowInterval() async throws {
        let host = try XCTUnwrap(ProcessInfo.processInfo.environment["TRANTHOR_HOST"],
                                 "Run scripts/test-example-simulator.sh to forward the mock host with TEST_RUNNER_.")
        XCTAssertTrue(host.hasPrefix("http://127.0.0.1:"))
        var reset = URLRequest(url: try XCTUnwrap(URL(string: "\(host)/control/reset")))
        reset.httpMethod = "POST"
        reset.setValue("application/json", forHTTPHeaderField: "Content-Type")
        reset.httpBody = Data("{}".utf8)
        let (_, resetResponse) = try await URLSession.shared.data(for: reset)
        XCTAssertEqual((resetResponse as? HTTPURLResponse)?.statusCode, 200)
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment["TRANTHOR_HOST"] = host
        app.launchEnvironment["TRANTHOR_FLUSH_INTERVAL_MS"] = "60000"
        app.launchEnvironment["TRANTHOR_WRITE_KEY"] = "conformance-fixture"
        app.launch()
        let status = app.staticTexts["configurationStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        let configured = NSPredicate(format: "label == %@", "Configured")
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: configured, object: status)], timeout: 10)
        app.activate()
        let slow = app.switches["slowFlush"]
        if !slow.exists { app.swipeUp() }
        XCTAssertTrue(slow.waitForExistence(timeout: 5), "The checklist needs the visible Slow flush toggle")
        XCTAssertEqual(slow.value as? String, "1")
        let track = app.buttons["track"]
        if !track.isHittable { app.swipeUp() }
        XCTAssertTrue(track.isHittable)
        XCTAssertEqual(app.staticTexts["flushInterval"].label, "Flush interval: 60000 ms")
        track.tap()
        // A successful empty flush alone cannot prove that the button action ran.
        let accepted = app.staticTexts["acceptedCalls"]
        let oneCall = NSPredicate(format: "label == %@", "Accepted event calls this launch: 1")
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: oneCall, object: accepted)], timeout: 10)
        // With the interval at 60 s, delivery within this 10 s window comes from lifecycle.
        let requestsURL = try XCTUnwrap(URL(string: "\(host)/control/requests"))
        let (beforeHome, _) = try await URLSession.shared.data(from: requestsURL)
        XCTAssertTrue(try JSONDecoder().decode(Records.self, from: beforeHome).requests.isEmpty,
                      "The slow interval must prevent foreground delivery before Home")
        XCUIDevice.shared.press(.home)
        let url = try XCTUnwrap(URL(string: "\(host)/control/requests"))
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var records: [Request] = []
        repeat {
            let (data, response) = try await URLSession.shared.data(from: url)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            records = try JSONDecoder().decode(Records.self, from: data).requests
            if !records.isEmpty && records.allSatisfy({ $0.body != nil }) { break }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        XCTAssertEqual(records.count, 1)
        let request = try XCTUnwrap(records.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/public/apps/batch")
        XCTAssertEqual(request.body?.batch.count, 1)
        let event = try XCTUnwrap(request.body?.batch.first)
        XCTAssertEqual(event.type, "track")
        XCTAssertEqual(event.event, "iOS Example Tagged Event")
        XCTAssertEqual(event.properties.liveTest, true)
        XCTAssertEqual(event.properties.source, "ios-example")
        XCTAssertNotNil(event.properties.runId.flatMap(UUID.init(uuidString:)))
        app.terminate()
    }
    /// Page and Screen share one form row. Each tap must run only its own action: one accepted call per tap.
    func testPageAndScreenEachCountOneCall() async throws {
        let host = try XCTUnwrap(ProcessInfo.processInfo.environment["TRANTHOR_HOST"])
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment = ["TRANTHOR_HOST": host, "TRANTHOR_WRITE_KEY": "conformance-fixture", "TRANTHOR_FLUSH_INTERVAL_MS": "60000"]
        app.launch()
        let status = app.staticTexts["configurationStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Configured"), object: status)], timeout: 10)
        let page = app.buttons["page"]
        for _ in 0..<10 { if page.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(page.isHittable)
        let accepted = app.staticTexts["acceptedCalls"]
        page.tap()
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Accepted event calls this launch: 1"), object: accepted)], timeout: 10)
        app.buttons["screen"].tap()
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Accepted event calls this launch: 2"), object: accepted)], timeout: 10)
        // A late second action would move the count past 2.
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(accepted.label, "Accepted event calls this launch: 2")
        app.terminate()
    }
    func testTaggedTrackAndFlush() async throws {
        let host = try XCTUnwrap(ProcessInfo.processInfo.environment["TRANTHOR_HOST"],
                                 "Run scripts/test-example-simulator.sh to forward the mock host with TEST_RUNNER_.")
        XCTAssertTrue(host.hasPrefix("http://127.0.0.1:"))
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment["TRANTHOR_FLUSH_INTERVAL_MS"] = "500"
        app.launchEnvironment["TRANTHOR_HOST"] = host
        app.launchEnvironment["TRANTHOR_WRITE_KEY"] = "conformance-fixture"
        app.launch()
        let status = app.staticTexts["configurationStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        let configured = NSPredicate(format: "label == %@", "Configured")
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: configured, object: status)], timeout: 10)
        app.activate()
        let track = app.buttons["track"]
        for _ in 0..<10 { if track.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(track.isHittable)
        track.tap()
        // A successful empty flush alone cannot prove that the button action ran.
        let accepted = app.staticTexts["acceptedCalls"]
        let oneCall = NSPredicate(format: "label == %@", "Accepted event calls this launch: 1")
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: oneCall, object: accepted)], timeout: 10)
        let flush = app.buttons["flush"]
        for _ in 0..<10 { if flush.isHittable { break }; app.swipeUp() }
        flush.tap()
        let result = app.staticTexts["flushResult"]
        for _ in 0..<10 { if result.isHittable { break }; app.swipeUp() }
        let succeeded = NSPredicate(format: "label == %@", "Last flush: Succeeded")
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: succeeded, object: result)], timeout: 15)
        let url = try XCTUnwrap(URL(string: "\(host)/control/requests"))
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let records = try JSONDecoder().decode(Records.self, from: data).requests
        XCTAssertEqual(records.count, 1)
        let request = try XCTUnwrap(records.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/public/apps/batch")
        XCTAssertEqual(request.body?.batch.count, 1)
        let event = try XCTUnwrap(request.body?.batch.first)
        XCTAssertEqual(event.type, "track")
        XCTAssertEqual(event.event, "iOS Example Tagged Event")
        XCTAssertEqual(event.properties.liveTest, true)
        XCTAssertEqual(event.properties.source, "ios-example")
        XCTAssertNotNil(event.properties.runId.flatMap(UUID.init(uuidString:)))
        app.terminate()
    }
    private struct Records: Decodable { let requests: [Request] }
    // The control API publishes a record when headers arrive, before its body is parsed.
    // Poll until body is present; a request that never completes still fails the test.
    private struct Request: Decodable { let method: String; let path: String; let body: Body? }
    private struct Body: Decodable { let batch: [Event] }
    private struct Event: Decodable { let type: String; let event: String; let messageId: String?; let properties: Properties }
    private struct Properties: Decodable {
        // Example Track/Page/Screen events carry these tags; the SDK's own Push events carry only deliveryId.
        let liveTest: Bool?; let runId: String?; let source: String?
        let deliveryId: String?; let actionIdentifier: String?
    }
}
