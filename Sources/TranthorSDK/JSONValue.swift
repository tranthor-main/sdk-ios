import Foundation

/// A JSON value: the type of event properties, traits and context. Value semantics, safe to pass between tasks.
public enum JSONValue: Sendable, Equatable, Codable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null

    /// Decodes any JSON value.
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode(Double.self) { self = .number(v) }
        else if let v = try? value.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try value.decode([JSONValue].self)) }
    }

    /// Encodes the value as plain JSON.
    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let v): try value.encode(v)
        case .array(let v): try value.encode(v)
        case .string(let v): try value.encode(v)
        case .number(let v): try value.encode(v)
        case .bool(let v): try value.encode(v)
        case .null: try value.encodeNil()
        }
    }

    /// The dictionary, if this is an object.
    public var object: [String: JSONValue]? { if case .object(let v) = self { v } else { nil } }
    /// The elements, if this is an array.
    public var array: [JSONValue]? { if case .array(let v) = self { v } else { nil } }
    /// The text, if this is a string.
    public var string: String? { if case .string(let v) = self { v } else { nil } }
    /// The number, if this is a number.
    public var number: Double? { if case .number(let v) = self { v } else { nil } }
    /// The flag, if this is a boolean.
    public var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
    /// The value for `key`, if this is an object that has it.
    public subscript(key: String) -> JSONValue? { object?[key] }
}
extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
                     ExpressibleByBooleanLiteral, ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral,
                     ExpressibleByNilLiteral {
    /// Creates a string from a string literal.
    public init(stringLiteral value: String) { self = .string(value) }
    /// Creates a number from an integer literal.
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    /// Creates a number from a floating-point literal.
    public init(floatLiteral value: Double) { self = .number(value) }
    /// Creates a boolean from a boolean literal.
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    /// Creates an object from a dictionary literal.
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, new in new }))
    }
    /// Creates an array from an array literal.
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    /// Creates `null` from `nil`.
    public init(nilLiteral: ()) { self = .null }
}
