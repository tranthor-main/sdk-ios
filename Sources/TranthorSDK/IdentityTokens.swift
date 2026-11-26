import Foundation

/// Identity tokens: a JWT your own backend signs for one user ID, which proves to Tranthor that an event really
/// comes from that user. The SDK holds no secret and never verifies a token. It reads `exp` only to decide when to
/// ask for a new one, and never trusts it for anything else. A token is never logged, never put inside an event or
/// an error report, and never sent for a user ID other than its own.

/// The server considers at most this many identity tokens per request, so a request carries at most this many users.
let maxUsersPerRequest = 10
/// A token with less than this left is renewed through the provider before the batch is sent.
let renewBelowMs = 60_000.0
/// Why an identity 503 is held for `Retry-After`, bounded to this range, and for this long when it has none.
let unavailableHoldDefaultMs = 30_000.0
let unavailableHoldMinMs = 1_000.0
/// The server's `Retry-After` on an identity 503 is honoured up to this long (generic retries cap it at 30 s).
let unavailableHoldMaxMs = 300_000.0
/// The server accepts a token until `exp` plus this long, so a cached one is still attached that long after `exp`.
let tokenGraceMs = 120_000.0
let unavailableCodes: Set<String> = ["identity_settings_unavailable", "identity_secrets_unavailable"]
/// 9999-12-31T23:59:59Z in seconds; anything beyond is not a real expiry.
private let maxExpSeconds = 253_402_300_799.0

/// Reads the `exp` claim (seconds since the epoch) from a JWT payload WITHOUT verifying the token. Use it to schedule a
/// renewal and nothing else: it proves nothing about the token. Nil when the text is not a three-segment JWT with a
/// JSON object payload and a numeric `exp`.
func decodeJwtExp(_ token: String) -> Double? {
    let segments = token.split(separator: ".", omittingEmptySubsequences: false)
    guard segments.count == 3, !segments[1].isEmpty else { return nil }
    // base64url only: no padding and no standard-alphabet characters in the token itself.
    guard segments[1].utf8.allSatisfy({ ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 95 }),
          segments[1].count % 4 != 1 else { return nil }
    var base64 = segments[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    guard let data = Data(base64Encoded: base64),
          let payload = try? JSONDecoder().decode(JSONValue.self, from: data), payload.object != nil,
          let exp = payload["exp"]?.number, exp.isFinite, exp >= 0, exp <= maxExpSeconds else { return nil }
    return exp
}

/// The tokens of the users this SDK knows, by user ID. It is part of the stored state, so it is written with the
/// queue and has the queue's file protection; it is never in the Keychain, so a reinstall does not bring back an old
/// token. An entry is kept while its user is the current user or still has events queued or in flight.
struct IdentityTokenCache: Codable, Sendable, Equatable {
    private(set) var tokens: [String: String] = [:]
    init() {}
    init(from decoder: any Decoder) throws {
        let values = try decoder.singleValueContainer().decode([String: String].self)
        tokens = values.filter { !$0.key.isEmpty && !$0.value.isEmpty }
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(tokens)
    }
    var isEmpty: Bool { tokens.isEmpty }
    var users: Set<String> { Set(tokens.keys) }
    mutating func set(_ token: String, for user: String) {
        guard !token.isEmpty, !user.isEmpty else { return }
        tokens[user] = token
    }
    mutating func remove(_ user: String) { tokens.removeValue(forKey: user) }
    /// The user's token when it still has at least `minValidityMs` left. A token whose `exp` cannot be read counts as
    /// valid: it is attached, and the server's answer decides.
    func fresh(for user: String, nowMs: Double, minValidityMs: Double) -> String? {
        guard let token = tokens[user] else { return nil }
        if let exp = decodeJwtExp(token), exp * 1000 - nowMs < minValidityMs { return nil }
        return token
    }
    /// Removes the tokens the server would no longer accept, `exp` + 120 s. True when something was removed.
    @discardableResult
    mutating func evictExpired(nowMs: Double) -> Bool {
        let before = tokens.count
        tokens = tokens.filter { entry in decodeJwtExp(entry.value).map { $0 * 1000 + tokenGraceMs >= nowMs } ?? true }
        return tokens.count != before
    }
    /// Removes every user not in `keep`. True when something was removed.
    @discardableResult
    mutating func retain(_ keep: Set<String>) -> Bool {
        let before = tokens.count
        tokens = tokens.filter { keep.contains($0.key) }
        return tokens.count != before
    }
}

func itemUser(_ item: [String: JSONValue]) -> String? {
    guard let user = item["userId"]?.string, !user.isEmpty else { return nil }
    return user
}
/// The distinct user IDs of a batch, in the order they first appear.
func distinctUsers(_ batch: [[String: JSONValue]]) -> [String] {
    var users: [String] = []
    for item in batch { if let user = itemUser(item), !users.contains(user) { users.append(user) } }
    return users
}
/// How many of the queued items the next request takes: at most `batchSize`, and, with `limitUsers` (identity tokens in
/// use), the longest prefix with at most ten distinct users, so no user is refused for lack of a token slot. At least
/// one while the queue is not empty.
func requestCut<S: Sequence>(_ queued: S, batchSize: Int, limitUsers: Bool = true) -> Int where S.Element == [String: JSONValue] {
    var users = Set<String>()
    var count = 0
    for item in queued {
        if count >= batchSize { break }
        if limitUsers, let user = itemUser(item), !users.contains(user) {
            if users.count >= maxUsersPerRequest { break }
            users.insert(user)
        }
        count += 1
    }
    return count
}
