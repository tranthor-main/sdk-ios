import XCTest
import Foundation
@testable import TranthorSDK

@MainActor
final class RunnerValidationTests: XCTestCase {
    func testMissingHostFailsUnlessExplicitMacDeveloperOptOut() throws {
        XCTAssertThrowsError(try conformanceHost(environment: [:], allowDeveloperSkip: true)) { error in
            XCTAssertTrue(error is CheckFailure, "Missing host must fail, not throw XCTSkip")
        }
        XCTAssertThrowsError(try conformanceHost(environment: ["CONFORMANCE_HOST": ""], allowDeveloperSkip: true)) { error in
            XCTAssertTrue(error is CheckFailure)
        }
        XCTAssertNil(try conformanceHost(environment: ["CONFORMANCE_ALLOW_SKIP": "1"], allowDeveloperSkip: true))
        XCTAssertThrowsError(try conformanceHost(environment: ["CONFORMANCE_ALLOW_SKIP": "1"], allowDeveloperSkip: false)) { error in
            XCTAssertTrue(error is CheckFailure, "Simulator cannot opt out")
        }
        XCTAssertEqual(try conformanceHost(environment: ["CONFORMANCE_HOST": "http://127.0.0.1:43189", "CONFORMANCE_ALLOW_SKIP": "1"], allowDeveloperSkip: false), "http://127.0.0.1:43189")
    }
    func testEnvelopeRejectsContextAndOtherWrapperKeys() throws {
        try validateEnvelope(["batch": []])
        XCTAssertThrowsError(try validateEnvelope(["batch": [], "context": ["library": "wrong"]]))
        XCTAssertThrowsError(try validateEnvelope(["batch": [], "unexpected": true]))
        try validateEnvelope(["batch": [], "identityTokens": ["a.b.c"]])
        XCTAssertThrowsError(try validateEnvelope(["batch": [], "identityTokens": []]), "An empty list is omitted instead")
        XCTAssertThrowsError(try validateEnvelope(["batch": [], "identityTokens": [1]]))
        XCTAssertThrowsError(try validateEnvelope(["batch": [:]]))
        XCTAssertThrowsError(try validateEnvelope(nil))
    }
    func testASchemaFaultInsideNotOrIfIsNotSwallowed() {
        let schema = Schema(root: [:])
        XCTAssertThrowsError(try schema.validate("a@b", schema: ["not": ["format": "email"]]))
        XCTAssertThrowsError(try schema.validate("a", schema: ["if": ["unknownKeyword": 1], "then": ["type": "string"]]))
        XCTAssertThrowsError(try schema.validate("a", schema: ["anyOf": [["format": "email"], ["type": "string"]]]))
        // An ordinary mismatch inside them is still a mismatch, not a fault.
        XCTAssertNoThrow(try schema.validate("a", schema: ["not": ["type": "number"]]))
        XCTAssertThrowsError(try schema.validate("a", schema: ["not": ["type": "string"]]))
    }
    func testAnAbsentIdentityTokensExpectationMeansNone() throws {
        try checkIdentityTokens(expected: nil, sent: [], minted: [:], index: 0)
        XCTAssertThrowsError(try checkIdentityTokens(expected: nil, sent: ["a.b.c"], minted: ["t1": "a.b.c"], index: 0))
        try checkIdentityTokens(expected: ["t1"], sent: ["a.b.c"], minted: ["t1": "a.b.c"], index: 0)
        XCTAssertThrowsError(try checkIdentityTokens(expected: [], sent: ["a.b.c"], minted: [:], index: 0))
    }
    func testFailureDiagnosticsIncludeEveryRequestIndexTimeAndMessageId() throws {
        let records: [J] = [
            ["index": 0, "receivedAtMs": 1200, "headers": ["authorization": "never-log-header"],
             "body": ["batch": [["messageId": "a"], ["messageId": "b"]]]],
            ["index": 1, "receivedAtMs": 1510, "body": ["batch": [["messageId": "a"]]]]
        ]
        let reason = scenarioFailureReason(CheckFailure("Delay outside band"), records: records)
        XCTAssertTrue(reason.hasPrefix("Delay outside band; requests="))
        let encoded = try XCTUnwrap(reason.components(separatedBy: "; requests=").last)
        let actual = try JSONDecoder().decode(J.self, from: Data(encoded.utf8))
        XCTAssertEqual(actual, [["index": 0, "receivedAtMs": 1200, "messageIds": ["a", "b"]],
                                ["index": 1, "receivedAtMs": 1510, "messageIds": ["a"]]])
        XCTAssertFalse(reason.contains("never-log-header"))
    }
    func testCallbackSnapshotDrainsFIFOWithoutUncheckedSendable() async {
        let log = ErrorLog()
        for index in 0..<100 {
            log.append(BatchFailure(error: DeliveryFailure(status: 400, message: "fixture", retryAfterMs: 0),
                                    events: [["messageId": .string(String(index))]], attempts: 1))
        }
        let snapshot = await log.snapshot()
        XCTAssertEqual(snapshot.count, 100)
        XCTAssertEqual(snapshot.compactMap { $0.events.first?["messageId"]?.string }, (0..<100).map(String.init))
        let again = await log.snapshot()
        XCTAssertEqual(again.count, 100)
    }
    func testSchemaRejectsUnknownFieldsAndMalformedSteps() throws {
        guard let folder = Bundle.module.url(forResource: "Fixtures", withExtension: nil) else { throw CheckFailure("Missing fixtures") }
        let schema = Schema(root: try JSONDecoder().decode(J.self, from: Data(contentsOf: folder.appendingPathComponent("scenario.schema.json"))))
        let original = try JSONDecoder().decode(J.self, from: Data(contentsOf: folder.appendingPathComponent("scenarios/anonymous-track.json")))
        try schema.validate(original)
        var unknown = original.object ?? [:]; unknown["unexpected"] = true
        XCTAssertThrowsError(try schema.validate(.object(unknown)))
        var config = original["config"]?.object ?? [:]; config["batchSize"] = 1.5
        var badConfig = original.object ?? [:]; badConfig["config"] = .object(config)
        XCTAssertThrowsError(try schema.validate(.object(badConfig)))
        var badResponse = original.object ?? [:]; badResponse["server"] = ["responses": [["status": 429, "retryAfter": "1\n"]]]
        XCTAssertThrowsError(try schema.validate(.object(badResponse)))
        var badStep = original.object ?? [:]; badStep["steps"] = [["op": "emit", "call": "a", "method": "track", "data": ["userId": "u"]], ["op": "assert", "expect": ["requests": [], "errors": []]]]
        XCTAssertThrowsError(try schema.validate(.object(badStep)))
    }
    func testInvalidReferencesAndDeclarationFail() throws {
        let scenario: J = ["id": "case", "capabilities": ["core"], "steps": [["op": "assert", "expect": ["requests": [["batch": [["call": "absent"]]]], "errors": []]]]]
        XCTAssertThrowsError(try validateReferences(scenario))
        let valid = Declaration(name: "test", capabilities: ["core"], suiteVersion: "1", lifecycleSource: nil, knownFailures: [])
        try valid.validate(scenarios: [scenario], version: "1")
        XCTAssertThrowsError(try Declaration(name: "test", capabilities: ["core", "core"], suiteVersion: "1", lifecycleSource: nil, knownFailures: []).validate(scenarios: [scenario], version: "1"))
        XCTAssertThrowsError(try Declaration(name: "test", capabilities: ["lifecycle"], suiteVersion: "1", lifecycleSource: nil, knownFailures: []).validate(scenarios: [scenario], version: "1"))
        XCTAssertThrowsError(try Declaration(name: "test", capabilities: ["core"], suiteVersion: "1", lifecycleSource: nil, knownFailures: [KnownFailure(id: "absent", reason: "r", tracking: "issue-1")]).validate(scenarios: [scenario], version: "1"))
    }
    func testIdentityLinkStepsAndRefsRequireTheCapability() throws {
        guard let folder = Bundle.module.url(forResource: "Fixtures", withExtension: nil) else { throw CheckFailure("Missing fixtures") }
        let schema = Schema(root: try JSONDecoder().decode(J.self, from: Data(contentsOf: folder.appendingPathComponent("scenario.schema.json"))))
        let linked = try JSONDecoder().decode(J.self, from: Data(contentsOf: folder.appendingPathComponent("scenarios/identify-links-anonymous-id.json")))
        try schema.validate(linked)
        try validateReferences(linked)
        var unlinked = linked.object ?? [:]; unlinked["capabilities"] = ["core"]
        XCTAssertThrowsError(try validateReferences(.object(unlinked)))
        let refOnly: J = ["id": "case", "capabilities": ["core"], "steps": [
            ["op": "emit", "call": "a", "method": "identify", "data": ["userId": "u"]],
            ["op": "assert", "expect": ["requests": [["batch": [["call": "a", "anonymousIdRef": "v"]]]], "errors": []]]]]
        XCTAssertThrowsError(try validateReferences(refOnly))
        let explicit: J = ["id": "case", "capabilities": ["core", "identity-link"], "steps": [
            ["op": "emit", "call": "a", "method": "identify", "data": ["userId": "u", "anonymousId": "x"]],
            ["op": "assert", "expect": ["requests": [["batch": [["call": "a", "anonymousIdRef": "v"]]]], "errors": []]]]]
        XCTAssertThrowsError(try validateReferences(explicit))
        try Declaration(name: "test", capabilities: ["core", "identity-link"], suiteVersion: "1", lifecycleSource: nil, knownFailures: [])
            .validate(scenarios: [linked], version: "1")
    }
    func testSubsetChecksNestedObjectsButArraysExactly() throws {
        try subset(["a": ["b": 1]], ["a": ["b": 1, "c": 2]], path: "item")
        XCTAssertThrowsError(try subset([1], [1, 2], path: "array"))
        XCTAssertThrowsError(try subset(["a": 1], ["a": 2], path: "object"))
    }
    func testDeclarationAcceptsTheDurableQueueCapability() throws {
        let scenario: J = ["id": "case", "capabilities": ["core", "durable-queue"], "steps": []]
        try Declaration(name: "test", capabilities: ["core", "durable-queue"], suiteVersion: "1", lifecycleSource: nil, knownFailures: [])
            .validate(scenarios: [scenario], version: "1")
    }
    func testScenarioIsSkippedWhenACapabilityItIsSupersededByIsDeclared() throws {
        let scenario: J = ["id": "case", "capabilities": ["core"], "unless": ["durable-queue"], "steps": []]
        XCTAssertEqual(skipReason(scenario, capabilities: ["core", "durable-queue"]), "superseded by durable-queue")
        XCTAssertNil(skipReason(scenario, capabilities: ["core"]))
        let needsConsent: J = ["id": "case", "capabilities": ["core", "consent"], "steps": []]
        XCTAssertEqual(skipReason(needsConsent, capabilities: ["core"]), "Missing: consent")
    }
    func testKnownFailureForASupersededScenarioFailsSuiteLoading() throws {
        let superseded: J = ["id": "old-rule", "capabilities": ["core"], "unless": ["durable-queue"], "steps": []]
        let failure = KnownFailure(id: "old-rule", reason: "r", tracking: "issue-1")
        XCTAssertThrowsError(try Declaration(name: "test", capabilities: ["core", "durable-queue"], suiteVersion: "1", lifecycleSource: nil, knownFailures: [failure])
            .validate(scenarios: [superseded], version: "1"))
        // Without the superseding capability the scenario runs, so a known failure for it is allowed.
        try Declaration(name: "test", capabilities: ["core"], suiteVersion: "1", lifecycleSource: nil, knownFailures: [failure])
            .validate(scenarios: [superseded], version: "1")
    }
}
