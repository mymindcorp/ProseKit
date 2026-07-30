import Foundation

/// A JSON-like value used for node and mark attributes.
///
/// ProseMirror stores attributes as plain JS objects with arbitrary JSON
/// values. We model that explicitly so attributes stay `Codable`, `Hashable`,
/// and `Sendable` while remaining schema-flexible.
public enum AttributeValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([AttributeValue])
    case object([String: AttributeValue])
}

public typealias Attrs = [String: AttributeValue]

extension AttributeValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension AttributeValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension AttributeValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}

extension AttributeValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension AttributeValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension AttributeValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: AttributeValue...) { self = .array(elements) }
}

extension AttributeValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, AttributeValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

// MARK: - Convenience accessors

public extension AttributeValue {
    var stringValue: String? {
        if case let .string(s) = self { return s }
        return nil
    }

    var intValue: Int? {
        switch self {
        case let .int(i): return i
        case let .double(d): return Int(d)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case let .double(d): return d
        case let .int(i): return Double(i)
        default: return nil
        }
    }

    var boolValue: Bool? {
        if case let .bool(b) = self { return b }
        return nil
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

// MARK: - Codable

extension AttributeValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Each mismatch costs a thrown error, so the cases are ordered by how
        // often they turn up in a document: objects, arrays and strings first.
        // `Int` must still be tried before `Double`, or whole numbers widen.
        if container.decodeNil() {
            self = .null
        } else if let o = try? container.decode([String: AttributeValue].self) {
            self = .object(o)
        } else if let a = try? container.decode([AttributeValue].self) {
            self = .array(a)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported attribute value")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(b): try container.encode(b)
        case let .int(i): try container.encode(i)
        case let .double(d): try container.encode(d)
        case let .string(s): try container.encode(s)
        case let .array(a): try container.encode(a)
        case let .object(o): try container.encode(o)
        }
    }
}
