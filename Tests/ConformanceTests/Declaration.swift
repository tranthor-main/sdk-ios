import Foundation

func conformanceHost(environment: [String: String], allowDeveloperSkip: Bool) throws -> String? {
    if let host = environment["CONFORMANCE_HOST"], !host.isEmpty { return host }
    if allowDeveloperSkip && environment["CONFORMANCE_ALLOW_SKIP"] == "1" { return nil }
    throw CheckFailure("Missing CONFORMANCE_HOST. Run scripts/test-simulator.sh or supply a local mock host; simulator conformance cannot skip.")
}

/// The capability a scenario is superseded by (the suite names it in `unless`), if the adapter declares it.
func supersedingCapability(_ scenario: J, capabilities: [String]) -> String? {
    (scenario["unless"]?.array ?? []).compactMap(\.string).first(where: capabilities.contains)
}
/// Why an adapter does not run a scenario, or nil when it must.
func skipReason(_ scenario: J, capabilities: [String]) -> String? {
    if let superseding = supersedingCapability(scenario, capabilities: capabilities) { return "superseded by " + superseding }
    let missing = (scenario["capabilities"]?.array ?? []).compactMap(\.string).filter { !capabilities.contains($0) }
    return missing.isEmpty ? nil : "Missing: " + missing.joined(separator: ",")
}

struct KnownFailure {
    let id: String
    let reason: String
    let tracking: String
}
struct Declaration {
    let name: String
    let capabilities: [String]
    let suiteVersion: String
    let lifecycleSource: String?
    let knownFailures: [KnownFailure]
    func validate(scenarios: [J], version: String) throws {
        let allowed: Set<String> = ["core", "transport", "persistence", "lifecycle", "consent", "identity-link", "durable-queue", "identity-token", "app-id"]
        try require(!name.isEmpty && suiteVersion == version && !version.isEmpty, "Invalid declaration name/version")
        try require(Set(capabilities).isSubset(of: allowed) && Set(capabilities).count == capabilities.count, "Invalid capabilities")
        if let lifecycleSource { try require(["os-hook", "public-method"].contains(lifecycleSource), "Invalid lifecycle source") }
        if capabilities.contains("lifecycle") { try require(lifecycleSource != nil, "Missing lifecycle source") }
        var ids = Set<String>()
        for failure in knownFailures {
            try require(ids.insert(failure.id).inserted && !failure.reason.isEmpty && !failure.tracking.isEmpty, "Invalid known failure")
            guard let scenario = scenarios.first(where: { $0["id"]?.string == failure.id }) else { throw CheckFailure("Unknown known failure") }
            try require(skipReason(scenario, capabilities: capabilities) == nil, "Known failure would be skipped")
        }
    }
}
