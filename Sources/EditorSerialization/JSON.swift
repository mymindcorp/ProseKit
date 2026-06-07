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
        let value = try JSONDecoder().decode(AttributeValue.self, from: data)
        guard case let .object(obj) = value else {
            throw ModelError.invalidJSON("Top-level document JSON must be an object")
        }
        return try Node.fromJSON(schema, obj)
    }

    public static func decode(_ schema: Schema, _ string: String) throws -> Node {
        try decode(schema, Data(string.utf8))
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
