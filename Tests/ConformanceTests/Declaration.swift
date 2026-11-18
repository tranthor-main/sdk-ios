import Foundation

func conformanceHost(environment: [String: String], allowDeveloperSkip: Bool) throws -> String? {
    if let host = environment["CONFORMANCE_HOST"], !host.isEmpty { return host }
    if allowDeveloperSkip && environment["CONFORMANCE_ALLOW_SKIP"] == "1" { return nil }
    throw CheckFailure("Missing CONFORMANCE_HOST. Run scripts/test-simulator.sh or supply a local mock host; simulator conformance cannot skip.")
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
        let allowed: Set<String> = ["core", "transport", "persistence", "lifecycle", "consent", "identity-link"]
        try require(!name.isEmpty && suiteVersion == version && !version.isEmpty, "Invalid declaration name/version")
        try require(Set(capabilities).isSubset(of: allowed) && Set(capabilities).count == capabilities.count, "Invalid capabilities")
        if let lifecycleSource { try require(["os-hook", "public-method"].contains(lifecycleSource), "Invalid lifecycle source") }
        if capabilities.contains("lifecycle") { try require(lifecycleSource != nil, "Missing lifecycle source") }
        var ids = Set<String>()
        for failure in knownFailures {
            try require(ids.insert(failure.id).inserted && !failure.reason.isEmpty && !failure.tracking.isEmpty, "Invalid known failure")
            guard let scenario = scenarios.first(where: { $0["id"]?.string == failure.id }) else { throw CheckFailure("Unknown known failure") }
            try require((scenario["capabilities"]?.array ?? []).compactMap(\.string).allSatisfy(capabilities.contains), "Known failure would be skipped")
        }
    }
}
