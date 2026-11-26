import Foundation
import TranthorSDK

/// The identity-token side of a scenario (suite 1.3.0): tokens minted by the mock at the moment they are needed, so
/// `ttlSeconds` is relative to now, and the scripted `identityTokenProvider`, which answers one outcome per call.
/// The cursor and the log outlive an SDK instance, so a `restart` continues the same script. Tokens are only ever
/// held here and compared; nothing prints one.
actor IdentityScript {
    private let host: String
    private let control = URLSession(configuration: .ephemeral)
    private var outcomes: [J]
    private(set) var tokens: [String: String] = [:]
    private(set) var providerCalls: [String] = []
    init(host: String, outcomes: [J]) {
        self.host = host
        self.outcomes = outcomes
    }
    func close() { control.invalidateAndCancel() }

    /// Mints `{ref, sub, ttlSeconds, valid?}` through the mock and remembers it under its ref.
    func mint(_ spec: J) async throws -> String {
        guard let ref = spec["ref"]?.string, let sub = spec["sub"]?.string, let ttl = spec["ttlSeconds"]?.number else {
            throw CheckFailure("Invalid token spec")
        }
        try require(tokens[ref] == nil, "Duplicate token ref \(ref)")
        var body: [String: J] = ["sub": .string(sub), "ttlSeconds": .number(ttl)]
        if let valid = spec["valid"] { body["valid"] = valid }
        guard let url = URL(string: host + "/control/identity/token") else { throw CheckFailure("Invalid control host") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(J.object(body))
        let (data, response) = try await control.data(for: request)
        try require((response as? HTTPURLResponse)?.statusCode == 200, "Control API failed identity/token")
        guard let token = try JSONDecoder().decode(J.self, from: data)["token"]?.string else { throw CheckFailure("Mock minted no token") }
        tokens[ref] = token
        return token
    }

    /// The scripted provider: the next outcome, or nil once the script is spent.
    func provide(_ userId: String) async throws -> String? {
        providerCalls.append(userId)
        let outcome: J = outcomes.isEmpty ? ["result": "null"] : outcomes.removeFirst()
        if let delay = outcome["delayMs"]?.number, delay > 0 { try await wait(delay) }
        switch outcome["result"]?.string {
        case "hang": try await Task.sleep(nanoseconds: 3_600 * 1_000_000_000); return nil
        case "error": throw CheckFailure("scripted provider error")
        case "token": return try await mint(outcome)
        default: return nil
        }
    }
}

/// The notices the SDK reported, in order. The callback runs synchronously, so a lock is enough.
final class NoticeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [Notice] = []
    func append(_ notice: Notice) { lock.withLock { entries.append(notice) } }
    var snapshot: [Notice] { lock.withLock { entries } }
}
