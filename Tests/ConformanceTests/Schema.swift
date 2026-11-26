import Foundation
import TranthorSDK

typealias J = JSONValue
struct CheckFailure: Error, CustomStringConvertible {
    var description: String
    init(_ text: String) { description = text }
}
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckFailure(message) }
}

/// Implements the draft-7 keywords used by the vendored schema, failing closed on unknown keywords.
/// The schema itself is wrong (an unsupported keyword, an unresolved reference): never a mismatch of the value, so it is
/// not swallowed where a keyword only asks whether a sub-schema matches.
struct SchemaFault: Error, CustomStringConvertible {
    var description: String
    init(_ text: String) { description = text }
}

struct Schema {
    let root: J
    func validate(_ value: J, schema: J? = nil, path: String = "$" ) throws {
        let rule = schema ?? root
        guard let map = rule.object else { throw SchemaFault("Invalid schema at \(path)") }
        let supported: Set<String> = ["$schema", "$id", "title", "definitions", "$ref", "type", "properties", "required",
            "additionalProperties", "enum", "const", "pattern", "minLength", "minimum", "maximum", "items", "minItems",
            "uniqueItems", "contains", "oneOf", "anyOf", "allOf", "not", "if", "then", "else"]
        if !Set(map.keys).isSubset(of: supported) { throw SchemaFault("Unsupported schema keyword \(path)") }
        if let ref = map["$ref"]?.string {
            if !ref.hasPrefix("#/") { throw SchemaFault("Nonlocal schema ref") }
            var target: J? = root
            for component in ref.dropFirst(2).split(separator: "/") { target = target?[String(component)] }
            guard let target else { throw SchemaFault("Unresolved schema ref \(ref)") }
            try validate(value, schema: target, path: path)
            return
        }
        if let type = map["type"] {
            let types = type.array ?? [type]
            try require(types.contains { matches(value, type: $0.string ?? "") }, "Type mismatch \(path)")
        }
        if let constant = map["const"] { try require(value == constant, "Const mismatch \(path)") }
        if let enumeration = map["enum"]?.array { try require(enumeration.contains(value), "Enum mismatch \(path)") }
        if let string = value.string {
            if let length = map["minLength"]?.number { try require(Double(string.count) >= length, "Short string \(path)") }
            if let pattern = map["pattern"]?.string {
                let regex = try NSRegularExpression(pattern: pattern)
                try require(regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil, "Pattern mismatch \(path)")
            }
        }
        if let n = value.number {
            if let min = map["minimum"]?.number { try require(n >= min, "Minimum \(path)") }
            if let max = map["maximum"]?.number { try require(n <= max, "Maximum \(path)") }
        }
        if let object = value.object {
            for key in map["required"]?.array ?? [] {
                try require(object[key.string ?? ""] != nil, "Missing \(path).\(key)")
            }
            let properties = map["properties"]?.object ?? [:]
            for (key, child) in object {
                if let childSchema = properties[key] { try validate(child, schema: childSchema, path: path + "." + key) }
                else if let extra = map["additionalProperties"] {
                    if extra == .bool(false) { throw CheckFailure("Unknown field \(path).\(key)") }
                    if extra.object != nil { try validate(child, schema: extra, path: path + "." + key) }
                }
            }
        }
        if let array = value.array {
            if let min = map["minItems"]?.number { try require(Double(array.count) >= min, "Short array \(path)") }
            if map["uniqueItems"] == .bool(true) {
                for index in array.indices { try require(!array.prefix(index).contains(array[index]), "Duplicate item \(path)") }
            }
            if let items = map["items"] { for (index, child) in array.enumerated() { try validate(child, schema: items, path: "\(path)[\(index)]") } }
            if let contains = map["contains"] {
                try require(try array.contains { try matches($0, schema: contains) }, "Contains mismatch \(path)")
            }
        }
        for keyword in ["allOf", "anyOf", "oneOf"] {
            if let variants = map[keyword]?.array {
                let count = try variants.filter { try matches(value, schema: $0, path: path) }.count
                try require(keyword == "allOf" ? count == variants.count : keyword == "oneOf" ? count == 1 : count >= 1,
                            "\(keyword) mismatch \(path)")
            }
        }
        if let negated = map["not"] {
            try require(!(try matches(value, schema: negated, path: path)), "not mismatch \(path)")
        }
        if let condition = map["if"] {
            if try matches(value, schema: condition) {
                if let then = map["then"] { try validate(value, schema: then, path: path) }
            } else if let otherwise = map["else"] {
                try validate(value, schema: otherwise, path: path)
            }
        }
    }
    /// Whether the value matches a sub-schema. A mismatch is false; a fault in the schema is thrown.
    private func matches(_ value: J, schema: J, path: String = "$") throws -> Bool {
        do { try validate(value, schema: schema, path: path); return true }
        catch is CheckFailure { return false }
    }
    private func matches(_ value: J, type: String) -> Bool {
        switch type {
        case "object": value.object != nil
        case "array": value.array != nil
        case "string": value.string != nil
        case "number": value.number != nil
        case "integer": value.number.map { $0.isFinite && $0.rounded(.down) == $0 } ?? false
        case "boolean": value.bool != nil
        case "null": value == .null
        default: false
        }
    }
}

func validateReferences(_ scenario: J) throws {
    var calls: [String: J] = [:]
    var labels: [String: String] = [:]
    let declared = (scenario["capabilities"]?.array ?? []).compactMap(\.string)
    let linking = declared.contains("identity-link")
    func needs(_ capability: String, _ what: String) throws { try require(declared.contains(capability), "\(what) must require \(capability)") }
    // Token refs: one definition each, from a scripted provider outcome or an emit.
    var refs = Set<String>()
    func define(_ ref: String?) throws {
        guard let ref else { return }
        try require(refs.insert(ref).inserted, "Duplicate token ref \(ref)")
    }
    if let identity = scenario["config"]?["identity"] {
        try needs("identity-token", "config.identity")
        for outcome in identity["provider"]?.array ?? [] where outcome["result"]?.string == "token" { try define(outcome["ref"]?.string) }
    }
    if scenario["server"]?["identity"] != nil { try needs("identity-token", "server.identity") }
    if scenario["config"]?["appId"] != nil { try needs("app-id", "config.appId") }
    for step in scenario["steps"]?.array ?? [] where step["op"]?.string == "emit" {
        guard let spec = step["identityToken"] else { continue }
        try needs("identity-token", "emit identityToken")
        try require(step["method"]?.string == "identify" && step["data"]?["userId"]?.string != nil,
                    "identityToken belongs on an identify with a userId")
        try define(spec["ref"]?.string)
    }
    for step in scenario["steps"]?.array ?? [] {
        let op = step["op"]?.string ?? ""
        if op == "anonymousId" { try require(linking, "anonymousId step must require identity-link") }
        if let label = step["call"]?.string ?? step["label"]?.string {
            try require(labels[label] == nil, "Duplicate label \(label)")
            labels[label] = op
            if op == "emit" { calls[label] = step["data"] ?? [:] }
        }
        guard let expect = step["expect"] else { continue }
        let requests = expect["requests"]?.array ?? []
        if expect["providerCalls"] != nil { try needs("identity-token", "expect.providerCalls") }
        if expect["notices"] != nil { try needs("identity-token", "expect.notices") }
        for request in requests {
            for ref in request["identityTokens"]?.array?.compactMap(\.string) ?? [] {
                try needs("identity-token", "identityTokens")
                try require(refs.contains(ref), "Unknown token ref \(ref)")
            }
            for item in request["batch"]?.array ?? [] {
                guard let data = calls[item["call"]?.string ?? ""] else { throw CheckFailure("Unknown item call") }
                if item["anonymousIdRef"] != nil {
                    try require(linking, "anonymousIdRef must require identity-link")
                    try require(data["anonymousId"] == nil, "anonymousIdRef cannot check a caller-supplied anonymousId")
                }
            }
            for key in request["headers"]?.object?.keys ?? Dictionary<String, J>().keys {
                try require(key == key.lowercased(), "Header must be lower-case")
            }
        }
        for error in expect["errors"]?.array ?? [] {
            for call in error["eventCalls"]?.array ?? [] { try require(calls[call.string ?? ""] != nil, "Unknown error call") }
        }
        for delay in expect["delays"]?.array ?? [] {
            try require((delay["minMs"]?.number ?? 0) <= (delay["maxMs"]?.number ?? 0), "Invalid delay bounds")
            try require(validIndex(delay["to"], requests.count), "Invalid delay to")
            if let from = delay["from"]?.string { try require(labels[from] != nil, "Unknown delay label") }
            else { try require(validIndex(delay["from"], requests.count), "Invalid delay from") }
        }
        for restart in expect["restartBetween"]?.array ?? [] {
            try require(labels[restart["label"]?.string ?? ""] == "restart", "Invalid restart label")
            for key in ["from", "to"] { if let index = restart[key] { try require(validIndex(index, requests.count), "Invalid restart index") } }
            if let from = restart["from"]?.number, let to = restart["to"]?.number { try require(from < to, "Invalid restart ordering") }
        }
    }
}
func validIndex(_ v: J?, _ count: Int) -> Bool { v?.number.map { $0 >= 0 && $0 < Double(count) && $0.rounded() == $0 } ?? false }
