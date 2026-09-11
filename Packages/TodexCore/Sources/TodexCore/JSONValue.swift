import Foundation

/// Preserves provider-specific fields without weakening the typed transport envelope.
public enum JSONValue: Codable, Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode(Double.self) {
            self = .number(v)
        } else if let v = try? c.decode([JSONValue].self) {
            self = .array(v)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    public subscript(_ key: String) -> JSONValue {
        get { objectValue[key] ?? .null }
        set {
            var value = objectValue
            value[key] = newValue
            self = .object(value)
        }
    }
    public var stringValue: String { if case .string(let s) = self { s } else { "" } }
    public var optionalString: String? { if case .string(let s) = self { s } else { nil } }
    public var arrayValue: [JSONValue] { if case .array(let a) = self { a } else { [] } }
    public var objectValue: [String: JSONValue] { if case .object(let o) = self { o } else { [:] } }
    public var boolValue: Bool { if case .bool(let b) = self { b } else { false } }
    public var doubleValue: Double? { if case .number(let n) = self { n } else { nil } }
    public var intValue: Int {
        guard let v = doubleValue, v.isFinite, v >= Double(Int.min), v < Double(Int.max) else { return 0 }
        return Int(v)
    }
    public var isNull: Bool { self == .null }
    public func decoded<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }
    public init<T: Encodable>(encoding value: T) throws {
        self = try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value))
    }
    public var prettyPrinted: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }
}
extension JSONValue: ExpressibleByStringLiteral { public init(stringLiteral value: String) { self = .string(value) } }
extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}
extension JSONValue: ExpressibleByFloatLiteral { public init(floatLiteral value: Double) { self = .number(value) } }
extension JSONValue: ExpressibleByBooleanLiteral { public init(booleanLiteral value: Bool) { self = .bool(value) } }
extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}
extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, rhs in rhs }))
    }
}
extension JSONValue: ExpressibleByNilLiteral { public init(nilLiteral: ()) { self = .null } }
