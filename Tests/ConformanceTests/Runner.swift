import Foundation
import XCTest
import TranthorSDK
#if canImport(UIKit)
import UIKit
#endif

/// Synchronous callbacks yield into a FIFO stream. Snapshot markers drain every preceding
/// yield, so observations cannot race callback delivery or reorder callback entries.
final class ErrorLog: Sendable {
    private enum Entry: Sendable {
        case failure(BatchFailure)
        case snapshot(CheckedContinuation<[BatchFailure], Never>)
    }
    private let input: AsyncStream<Entry>.Continuation
    private let consumer: Task<Void, Never>
    init() {
        var continuation: AsyncStream<Entry>.Continuation?
        let stream = AsyncStream<Entry> { continuation = $0 }
        // AsyncStream's builder runs synchronously. Avoid force unwraps even in the harness.
        guard let continuation else { preconditionFailure("Missing callback stream continuation") }
        input = continuation
        consumer = Task {
            var entries: [BatchFailure] = []
            for await entry in stream {
                switch entry {
                case .failure(let failure): entries.append(failure)
                case .snapshot(let reply): reply.resume(returning: entries)
                }
            }
        }
    }
    func append(_ error: BatchFailure) { input.yield(.failure(error)) }
    func snapshot() async -> [BatchFailure] {
        await withCheckedContinuation { input.yield(.snapshot($0)) }
    }
    deinit { input.finish() }
}
struct Call {
    let method: String
    let data: J
    let before: Double
    let after: Double
    /// The SDK's stored anonymousId read right after the call (identity-link only).
    var storedAnonymousId: String? = nil
}
struct Operation { let kind: String; let before: Double; let after: Double }
func now() -> Double { Date().timeIntervalSince1970 * 1000 }
func wait(_ ms: Double) async throws { try await Task.sleep(nanoseconds: UInt64(max(0, ms) * 1_000_000)) }
func emitLine(_ value: J) throws {
    let data = try JSONEncoder().encode(value)
    print(String(decoding: data, as: UTF8.self))
}
func validateEnvelope(_ body: J?) throws {
    // Stricter iOS SDK invariant: production does not merge envelope context into items.
    // The language-neutral protocol permits wrappers to add context; this SDK never does.
    try require(body?.object.map { Set($0.keys) == ["batch"] } == true,
                "iOS SDK envelope must contain exactly batch")
    try require(body?["batch"]?.array != nil, "iOS SDK batch must be an array")
}
func requestDiagnostics(_ records: [J]) -> J {
    .array(records.map { record in
        ["index": record["index"] ?? .null,
         "receivedAtMs": record["receivedAtMs"] ?? .null,
         "messageIds": .array((record["body"]?["batch"]?.array ?? []).map { $0["messageId"] ?? .null })]
    })
}
func scenarioFailureReason(_ error: any Error, records: [J]) -> String {
    let encoded = (try? JSONEncoder().encode(requestDiagnostics(records))) ?? Data("null".utf8)
    return String(describing: error) + "; requests=" + String(decoding: encoded, as: UTF8.self)
}
func subset(_ expected: J, _ actual: J?, path: String) throws {
    guard let actual else { throw CheckFailure("Missing \(path)") }
    if let map = expected.object {
        try require(actual.object != nil, "Expected object \(path)")
        for (key, child) in map { try subset(child, actual[key], path: path + "." + key) }
    } else { try require(expected == actual, "Mismatch \(path): expected \(expected), got \(actual)") }
}

@MainActor
final class ScenarioRunner {
    let host: String
    let scenario: J
    let directory: URL
    let errors = ErrorLog()
    var sdk: TranthorSDK?
    var calls: [String: Call] = [:]
    var operations: [String: Operation] = [:]
    var stamps: [String: (String, String)] = [:]
    let linking: Bool
    var anonymousIdRefs: [String: String] = [:]
    var offset = 0.0
    let control = URLSession(configuration: .ephemeral)
    init(host: String, scenario: J, linking: Bool = false) {
        self.host = host
        self.scenario = scenario
        self.linking = linking
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("tranthor-conformance-" + UUID().uuidString)
    }
    /// One ref names one stored anonymousId; distinct refs must hold distinct values.
    func bindAnonymousId(_ ref: String, _ value: String?, _ label: String) throws {
        guard let value, !value.isEmpty else { throw CheckFailure("\(label): anonymousId must be a nonempty string") }
        if let bound = anonymousIdRefs[ref] { try require(bound == value, "\(label): anonymousId differs from ref \(ref)"); return }
        if let other = anonymousIdRefs.first(where: { $0.value == value }) {
            throw CheckFailure("\(label): ref \(ref) reuses the anonymousId of ref \(other.key)")
        }
        anonymousIdRefs[ref] = value
    }
    func http(_ path: String, _ body: J? = nil) async throws -> J {
        guard let url = URL(string: host + path) else { throw CheckFailure("Invalid control host") }
        var request = URLRequest(url: url)
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await control.data(for: request)
        try require((response as? HTTPURLResponse)?.statusCode == 200, "Control API failed \(path)")
        return try JSONDecoder().decode(J.self, from: data)
    }
    func makeSDK() async throws -> TranthorSDK {
        let config = scenario["config"] ?? [:]
        let log = errors
        return try await TranthorSDK.configure(Configuration(
            writeKey: config["writeKey"]?.string ?? "",
            host: host + (config["hostSuffix"]?.string ?? ""),
            batchSize: config["batchSize"]?.number, flushIntervalMs: config["flushIntervalMs"]?.number,
            retries: config["retries"]?.number, baseDelay: config["baseDelay"]?.number,
            // caller-overrides requires exact equality of the original context object.
            // Every other scenario exercises the production context default.
            automaticContext: scenario["id"]?.string != "caller-overrides", storageNamespace: "scenario", storageDirectory: directory,
            onError: { log.append($0) }))
    }
    func run() async throws {
        do {
            _ = try await http("/control/reset", [:])
            var samples: [Double] = []
            for _ in 0..<3 {
                let before = now()
                let response = try await http("/control/time")
                let after = now()
                guard let server = response["nowMs"]?.number else { throw CheckFailure("Missing server clock") }
                samples.append(server - (before + after) / 2)
            }
            offset = samples.sorted()[1]
            _ = try await http("/control/script", scenario["server"])
            sdk = try await makeSDK()
            for step in scenario["steps"]?.array ?? [] { try await execute(step) }
        } catch {
            // Capture raw request timing/stamps before invalidating the control session.
            let reason: String
            do { reason = scenarioFailureReason(error, records: try await requests()) }
            catch let snapshotError {
                reason = String(describing: error) + "; requests unavailable: " + String(describing: snapshotError)
            }
            await dispose()
            throw CheckFailure(reason)
        }
        await dispose()
    }
    func dispose() async {
        await sdk?.shutdown(); sdk = nil
        control.invalidateAndCancel()
        try? FileManager.default.removeItem(at: directory)
    }
    func execute(_ step: J) async throws {
        guard let sdk else { throw CheckFailure("Missing SDK") }
        let op = step["op"]?.string ?? ""
        let before = now()
        switch op {
        case "emit":
            let data = step["data"] ?? [:]
            let method = step["method"]?.string ?? ""
            let user = data["userId"]?.string, anonymous = data["anonymousId"]?.string
            let id = data["messageId"]?.string, time = data["timestamp"]?.string
            let context = data["context"]?.object, properties = data["properties"]?.object
            switch method {
            case "identify": try await sdk.identify(userId: user, anonymousId: anonymous, traits: data["traits"]?.object, messageId: id, timestamp: time, context: context)
            case "track": try await sdk.track(event: data["event"]?.string ?? "", userId: user, anonymousId: anonymous, properties: properties, files: data["files"]?.array, messageId: id, timestamp: time, context: context)
            case "page": try await sdk.page(name: data["name"]?.string, userId: user, anonymousId: anonymous, properties: properties, messageId: id, timestamp: time, context: context)
            case "screen": try await sdk.screen(name: data["name"]?.string, userId: user, anonymousId: anonymous, properties: properties, messageId: id, timestamp: time, context: context)
            default: throw CheckFailure("Unknown method")
            }
            let after = now()
            var call = Call(method: method, data: data, before: before, after: after)
            if linking { call.storedAnonymousId = await sdk.anonymousId }
            calls[step["call"]?.string ?? ""] = call
        case "wait": try await wait(step["ms"]?.number ?? 0)
        case "flush":
            // The timeout task cancels SDK work so the task group cannot hang while joining a stuck flush.
            let rejected = try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask { do { try await sdk.flush(); return false } catch { return true } }
                group.addTask {
                    try await wait(5000)
                    await sdk.shutdown()
                    throw CheckFailure("Flush did not settle within 5 seconds")
                }
                guard let value = try await group.next() else { throw CheckFailure("Missing flush completion") }
                group.cancelAll()
                return value
            }
            try require(now() - before < 5000, "Flush exceeded its five-second deadline")
            if let expected = step["rejected"]?.bool { try require(expected == rejected, "Flush rejected=\(rejected), expected \(expected)") }
        case "restart":
            await sdk.shutdown()
            self.sdk = nil // Destroy the instance before recreating; never flush or re-emit.
            self.sdk = try await makeSDK()
        case "optOut": try await sdk.optOut()
        case "optIn": try await sdk.optIn()
        case "background":
            #if canImport(UIKit)
            // Post the exact OS notification; this does not transition the minimal test host to background.
            NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
            await Task.yield()
            #else
            throw CheckFailure("UIKit lifecycle unavailable")
            #endif
        case "assert": try await assertExpectation(step)
        case "anonymousId":
            let stored = await sdk.anonymousId
            try bindAnonymousId(step["ref"]?.string ?? "", stored, "step")
        default: throw CheckFailure("Unknown operation \(op)")
        }
        if let label = step["label"]?.string { operations[label] = Operation(kind: op, before: before, after: now()) }
    }
    func requests() async throws -> [J] { try await http("/control/requests")["requests"]?.array ?? [] }
    func assertExpectation(_ step: J) async throws {
        let expect = step["expect"] ?? [:]
        let expectedRequests = expect["requests"]?.array ?? []
        let expectedErrors = expect["errors"]?.array ?? []
        let deadline = now() + (step["timeoutMs"]?.number ?? 3000)
        while now() < deadline {
            let records = try await requests()
            let callbacks = await errors.snapshot()
            if records.count >= expectedRequests.count && callbacks.count >= expectedErrors.count { break }
            try await wait(10)
        }
        try await wait(step["observeMs"]?.number ?? 100)
        let records = try await requests()
        let callbacks = await errors.snapshot()
        for record in records { try validateEnvelope(record["body"]) }
        try require(records.count == expectedRequests.count, "Request count \(records.count), expected \(expectedRequests.count)")
        try require(callbacks.count == expectedErrors.count, "Error count \(callbacks.count), expected \(expectedErrors.count)")
        var wire: [String: J] = [:]
        for (index, expected) in expectedRequests.enumerated() {
            let record = records[index]
            for key in ["method", "path"] { if let v = expected[key] { try subset(v, record[key], path: key) } }
            for (key, value) in expected["headers"]?.object ?? [:] {
                if key == "content-type" {
                    let media = record["headers"]?[key]?.string?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
                    let wanted = value.string?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
                    try require(media == wanted, "Content-Type mismatch")
                } else { try subset(value, record["headers"]?[key], path: "header " + key) }
            }
            if let context = expected["context"] { try subset(context, record["body"]?["context"], path: "batch context") }
            let batch = record["body"]?["batch"]?.array ?? []
            let items = expected["batch"]?.array ?? []
            try require(batch.count == items.count, "Batch count request \(index)")
            for (position, item) in items.enumerated() {
                let label = item["call"]?.string ?? ""
                guard let call = calls[label] else { throw CheckFailure("Missing call \(label)") }
                let actual = batch[position]
                try subset(.string(call.method), actual["type"], path: label + ".type")
                // Original values are exact, including nested objects, unlike fields subset checks.
                for (key, original) in call.data.object ?? [:] {
                    try require(actual[key] == original, "Original call value changed \(label).\(key)")
                }
                for key in ["userId", "anonymousId"] where call.data[key] == nil {
                    if linking && key == "anonymousId" && call.method == "identify" && !(call.data["userId"]?.string ?? "").isEmpty {
                        // identity-link: a login identify carries the anonymousId stored once the call returned.
                        try require(actual[key]?.string == call.storedAnonymousId, "Identify \(label) must carry the stored anonymousId")
                    } else {
                        try require(actual[key] == nil, "Unexpected identity \(label).\(key)")
                    }
                }
                if let ref = item["anonymousIdRef"]?.string { try bindAnonymousId(ref, actual["anonymousId"]?.string, label) }
                if let fields = item["fields"] { try subset(fields, actual, path: label) }
                try checkStamp(actual, call: call, label: label)
                wire[label] = actual
            }
        }
        for (index, expected) in expectedErrors.enumerated() {
            let error = callbacks[index]
            try require(Double(error.attempts) == expected["attempts"]?.number, "Error attempts mismatch")
            if let status = expected["status"] { try require(status == error.error.status.map { .number(Double($0)) } ?? .null, "Error status mismatch") }
            let labels = expected["eventCalls"]?.array ?? []
            try require(error.events.count == labels.count, "Error event count mismatch")
            for (position, label) in labels.enumerated() {
                guard let event = wire[label.string ?? ""] else { throw CheckFailure("Callback call absent from wire") }
                for key in ["messageId", "type"] { try require(error.events[position][key] == event[key], "Callback \(key) mismatch") }
            }
        }
        for delay in expect["delays"]?.array ?? [] {
            guard let to = delay["to"]?.number else { throw CheckFailure("Missing to") }
            let end = records[Int(to)]["receivedAtMs"]?.number ?? 0
            let start: Double
            if let index = delay["from"]?.number { start = records[Int(index)]["receivedAtMs"]?.number ?? 0 }
            else {
                let label = delay["from"]?.string ?? ""
                guard let before = calls[label]?.before ?? operations[label]?.before else { throw CheckFailure("Missing delay source") }
                start = floor(before + offset)
            }
            let delta = end - start
            try require(delta >= (delay["minMs"]?.number ?? 0) && delta <= (delay["maxMs"]?.number ?? 0), "Delay \(delta) outside \(delay)")
        }
        for boundary in expect["restartBetween"]?.array ?? [] {
            guard let operation = operations[boundary["label"]?.string ?? ""], operation.kind == "restart" else { throw CheckFailure("Missing restart") }
            if let from = boundary["from"]?.number { try require((records[Int(from)]["receivedAtMs"]?.number ?? 0) <= floor(operation.before + offset), "Restart begins before source request") }
            if let to = boundary["to"]?.number { try require(floor(operation.after + offset) <= (records[Int(to)]["receivedAtMs"]?.number ?? 0), "Request arrived before restart finished") }
        }
    }
    func checkStamp(_ event: J, call: Call, label: String) throws {
        guard let id = event["messageId"]?.string, !id.isEmpty, let time = event["timestamp"]?.string else { throw CheckFailure("Missing stamp") }
        if let prior = stamps[label] { try require(prior.0 == id && prior.1 == time, "Restamped \(label)") }
        else {
            if call.data["messageId"] == nil {
                for (other, stamp) in stamps where other != label && calls[other]?.data["messageId"] == nil { try require(stamp.0 != id, "Duplicate generated ID") }
            }
            stamps[label] = (id, time)
        }
        if call.data["timestamp"] == nil {
            let regex = try NSRegularExpression(pattern: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z$(?![\\s\\S])")
            try require(regex.firstMatch(in: time, range: NSRange(time.startIndex..., in: time)) != nil, "Invalid timestamp format")
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = formatter.date(from: time) else { throw CheckFailure("Unparseable timestamp") }
            let ms = date.timeIntervalSince1970 * 1000
            try require(ms >= call.before - 50 && ms <= call.after + 50, "Timestamp outside call-time band \(label)")
        }
    }
}
