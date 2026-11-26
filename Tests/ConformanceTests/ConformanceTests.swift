import Foundation
import XCTest
import TranthorSDK

@MainActor
final class ConformanceTests: XCTestCase {
    func testConformance() async throws {
        #if os(macOS) && SWIFT_PACKAGE
        let allowDeveloperSkip = true
        #else
        let allowDeveloperSkip = false
        #endif
        guard let host = try conformanceHost(environment: ProcessInfo.processInfo.environment,
                                             allowDeveloperSkip: allowDeveloperSkip) else {
            throw XCTSkip("Explicit macOS developer opt-out: CONFORMANCE_ALLOW_SKIP=1")
        }
        try require(host.hasPrefix("http://127.0.0.1:"), "Conformance is local-only")
        guard let fixtures = Bundle.module.url(forResource: "Fixtures", withExtension: nil) else { throw CheckFailure("Missing fixtures") }
        let version = try String(contentsOf: fixtures.appendingPathComponent("VERSION"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let schema = Schema(root: try JSONDecoder().decode(J.self, from: Data(contentsOf: fixtures.appendingPathComponent("scenario.schema.json"))))
        let files = try FileManager.default.contentsOfDirectory(at: fixtures.appendingPathComponent("scenarios"), includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let scenarios = try files.map { try JSONDecoder().decode(J.self, from: Data(contentsOf: $0)) }
        var ids = Set<String>()
        // Validate every file before filtering or executing any scenario.
        for scenario in scenarios {
            try schema.validate(scenario)
            try validateReferences(scenario)
            guard let id = scenario["id"]?.string else { throw CheckFailure("Missing ID") }
            try require(ids.insert(id).inserted, "Duplicate scenario ID")
        }
        #if canImport(UIKit)
        let capabilities = ["core", "transport", "persistence", "lifecycle", "consent", "identity-link", "durable-queue", "identity-token", "app-id"]
        let lifecycle: J = "os-hook"
        #else
        let capabilities = ["core", "transport", "persistence", "consent", "identity-link", "durable-queue", "identity-token", "app-id"]
        let lifecycle: J = .null
        #endif
        let name = "TranthorSDK Swift XCTest"
        let knownFailures: [KnownFailure] = []
        let declaration = Declaration(name: name, capabilities: capabilities, suiteVersion: version,
                                      lifecycleSource: lifecycle.string, knownFailures: knownFailures)
        try declaration.validate(scenarios: scenarios, version: version)
        var passed = 0, failed = 0, skipped = 0, xfailed = 0
        let filter = ProcessInfo.processInfo.environment["CONFORMANCE_SCENARIO"]
        for scenario in scenarios {
            let id = scenario["id"]?.string ?? ""
            if let filter, filter != id { continue } // Diagnostic mode still validates all files.
            if let reason = skipReason(scenario, capabilities: capabilities) {
                skipped += 1
                try emitLine(["id": .string(id), "result": "skip", "reason": .string(reason)])
                continue
            }
            let runner = ScenarioRunner(host: host, scenario: scenario, linking: capabilities.contains("identity-link"))
            do {
                try await runner.run()
                if knownFailures.contains(where: { $0.id == id }) {
                    failed += 1
                    try emitLine(["id": .string(id), "result": "fail", "reason": "Unexpected pass; remove knownFailure"])
                } else {
                    passed += 1
                    try emitLine(["id": .string(id), "result": "pass"])
                }
            } catch {
                if let known = knownFailures.first(where: { $0.id == id }) {
                    xfailed += 1
                    try emitLine(["id": .string(id), "result": "xfail", "reason": .string(known.reason + " (" + known.tracking + ") " + String(describing: error))])
                } else {
                    failed += 1
                    try emitLine(["id": .string(id), "result": "fail", "reason": .string(String(describing: error))])
                }
            }
        }
        try emitLine(["adapter": .string(name), "capabilities": .array(capabilities.map(J.string)), "suiteVersion": .string(version),
                      "knownFailures": .array(knownFailures.map { .string($0.id) }), "validated": .number(Double(scenarios.count)),
                      "passed": .number(Double(passed)), "failed": .number(Double(failed)), "skipped": .number(Double(skipped)),
                      "xfailed": .number(Double(xfailed)), "lifecycleSource": lifecycle])
        print("validated \(scenarios.count), passed \(passed), failed \(failed), skipped \(skipped)")
        XCTAssertEqual(failed, 0, "Conformance scenarios failed")
        if let filter { try require(ids.contains(filter), "Unknown diagnostic scenario") }
    }
}
