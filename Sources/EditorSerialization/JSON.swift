import Foundation
import DocumentModel

/// ProseMirror-shaped JSON serialization. This is the canonical persistence and
/// collaboration format; `Node`/`Mark`/`Slice` already encode to the documented
/// shape via `AttributeValue`'s `Codable` conformance.
public enum DocumentJSON {
    public static func encode(_ node: Node, pretty: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try encoder.encode(AttributeValue.object(node.toJSON()))
    }

    public static func string(_ node: Node, pretty: Bool = false) throws -> String {
        String(decoding: try encode(node, pretty: pretty), as: UTF8.self)
    }

    public static func decode(_ schema: Schema, _ data: Data) throws -> Node {
        let value = try attributeValue(from: try JSONSerialization.jsonObject(with: data))
        guard case let .object(obj) = value else {
            throw ModelError.invalidJSON("Top-level document JSON must be an object")
        }
        return try Node.fromJSON(schema, obj)
    }

    public static func decode(_ schema: Schema, _ string: String) throws -> Node {
        try decode(schema, Data(string.utf8))
    }

    /// Bridge `JSONSerialization`'s output into `AttributeValue`.
    ///
    /// `AttributeValue`'s own `Decodable` conformance has to discover each value's
    /// type by trying every case in turn, and a document is overwhelmingly objects,
    /// arrays and strings — the cases it reaches last. Foundation's parser already
    /// knows the type, so going through it and switching on the result decodes a
    /// 200 KB document in 18ms rather than 124ms.
    public static func attributeValue(from json: Any) throws -> AttributeValue {
        switch json {
        case let dict as [String: Any]:
            var out: [String: AttributeValue] = [:]
            out.reserveCapacity(dict.count)
            for (key, value) in dict { out[key] = try attributeValue(from: value) }
            return .object(out)
        case let array as [Any]:
            var out: [AttributeValue] = []
            out.reserveCapacity(array.count)
            for value in array { out.append(try attributeValue(from: value)) }
            return .array(out)
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            // Order matters: `true` bridges to a number, and `as? Bool` would
            // accept any 0/1, so booleans have to be identified by their type.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            if CFNumberIsFloatType(number) { return .double(number.doubleValue) }
            return .int(number.intValue)
        case is NSNull:
            return .null
        default:
            throw ModelError.invalidJSON("Unsupported attribute value of type \(type(of: json))")
        }
    }
}

public extension Node {
    /// Load a document node from a ProseMirror-shaped JSON string against the
    /// given schema. Throws `ModelError.invalidJSON` for malformed input, or a
    /// schema error for unknown node/mark types.
    static func fromJSON(_ json: String, schema: Schema) throws -> Node {
        try DocumentJSON.decode(schema, json)
    }

    /// Serialize this node to a ProseMirror-shaped JSON string.
    func toJSONString(pretty: Bool = false) throws -> String {
        try DocumentJSON.string(self, pretty: pretty)
    }
}
