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
struct Schema {
    let root: J
    func validate(_ value: J, schema: J? = nil, path: String = "$" ) throws {
        let rule = schema ?? root
        guard let map = rule.object else { throw CheckFailure("Invalid schema at \(path)") }
        let supported: Set<String> = ["$schema", "$id", "title", "definitions", "$ref", "type", "properties", "required",
            "additionalProperties", "enum", "const", "pattern", "minLength", "minimum", "maximum", "items", "minItems",
            "uniqueItems", "contains", "oneOf", "anyOf", "allOf", "if", "then"]
        try require(Set(map.keys).isSubset(of: supported), "Unsupported schema keyword \(path)")
        if let ref = map["$ref"]?.string {
            try require(ref.hasPrefix("#/"), "Nonlocal schema ref")
            var target: J? = root
            for component in ref.dropFirst(2).split(separator: "/") { target = target?[String(component)] }
            guard let target else { throw CheckFailure("Unresolved schema ref \(ref)") }
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
                try require(array.contains { (try? validate($0, schema: contains)) != nil }, "Contains mismatch \(path)")
            }
        }
        for keyword in ["allOf", "anyOf", "oneOf"] {
            if let variants = map[keyword]?.array {
                let count = variants.filter { (try? validate(value, schema: $0, path: path)) != nil }.count
                try require(keyword == "allOf" ? count == variants.count : keyword == "oneOf" ? count == 1 : count >= 1,
                            "\(keyword) mismatch \(path)")
            }
        }
        if let condition = map["if"], (try? validate(value, schema: condition)) != nil, let then = map["then"] {
            try validate(value, schema: then, path: path)
        }
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
    let linking = (scenario["capabilities"]?.array ?? []).contains { $0.string == "identity-link" }
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
        for request in requests {
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
