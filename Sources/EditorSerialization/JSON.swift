public import Foundation
public import DocumentModel

/// ProseMirror-shaped JSON serialization. This is the canonical persistence and
/// collaboration format; `Node`/`Mark`/`Slice` already encode to the documented
/// shape via `AttributeValue`'s `Codable` conformance.
public enum DocumentJSON {
    /// Encode a document.
    ///
    /// **Dense by default, and it stays that way for performance.** This is the
    /// persistence and collaboration format: it is written on every save and on
    /// every step sent to a peer, and read back by machines. Indentation would
    /// add a newline and up to a dozen spaces per value — most of a document's
    /// JSON is small values nested deep — for output nothing in the hot path
    /// looks at. Ask for `pretty: true` where a person reads it: fixtures,
    /// test expectations, the demo's inspector.
    public static func encode(_ node: Node, pretty: Bool = false) throws -> Data {
        var out: [UInt8] = []
        // Documents measure about four JSON bytes per position; overshooting a
        // little beats reallocating, and anything larger just grows on demand.
        out.reserveCapacity(node.nodeSize * 5)
        try write(.object(node.toJSON()), into: &out, pretty: pretty, depth: 0)
        return Data(out)
    }

    /// Encode a document to a string. Dense by default, as `encode` is.
    public static func string(_ node: Node, pretty: Bool = false) throws -> String {
        String(decoding: try encode(node, pretty: pretty), as: UTF8.self)
    }

    public static func decode(_ schema: Schema, _ data: Data) throws -> Node {
        let value = try attributeValue(from: try JSONSerialization.jsonObject(with: data))
        guard case let .object(obj) = value else {
            throw ModelError.invalidJSON("Top-level document JSON must be an object")
        }
        // `Node.fromJSON` builds what it is given, as upstream's does — a
        // slice's open nodes are legitimately partial, and it serves those
        // too. A *document* is not allowed to be partial: a file truncated to
        // `{"type":"doc","content":[]}` loaded as an empty document that
        // failed its own check on the first edit.
        let doc = try Node.fromJSON(schema, obj)
        try doc.check()
        return doc
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

    // MARK: Writing

    /// Encode an attribute value as JSON, keys in sorted order.
    public static func encode(_ value: AttributeValue, pretty: Bool = false) throws -> Data {
        var out: [UInt8] = []
        out.reserveCapacity(256)
        try write(value, into: &out, pretty: pretty, depth: 0)
        return Data(out)
    }

    /// Write `value` as JSON bytes, keys in sorted order.
    ///
    /// `JSONEncoder` spends most of its time on `Codable` machinery our shape
    /// doesn't need — writing the bytes directly encodes a 200 KB document in
    /// 5ms rather than 21ms. Output is byte-identical to `JSONEncoder`'s so
    /// stored documents don't all change: sorted keys, escaped forward slashes,
    /// and two-space indentation with `" : "` around pretty-printed keys. The
    /// one exception is empty containers, which stay `{}` and `[]` when pretty.
    static func write(_ value: AttributeValue, into out: inout [UInt8],
                      pretty: Bool, depth: Int) throws {
        switch value {
        case .null:
            out.append(contentsOf: Array("null".utf8))
        case let .bool(b):
            out.append(contentsOf: Array((b ? "true" : "false").utf8))
        case let .int(i):
            out.append(contentsOf: Array(String(i).utf8))
        case let .double(d):
            // JSON has no way to spell these, and `JSONEncoder` throws too.
            guard d.isFinite else {
                throw ModelError.invalidJSON("Cannot encode \(d) as JSON")
            }
            out.append(contentsOf: Array(String(d).utf8))
        case let .string(s):
            writeString(s, into: &out)
        case let .array(items):
            if items.isEmpty {
                out.append(contentsOf: Array("[]".utf8))
                return
            }
            out.append(UInt8(ascii: "["))
            for (i, item) in items.enumerated() {
                if i > 0 { out.append(UInt8(ascii: ",")) }
                newline(&out, pretty: pretty, depth: depth + 1)
                try write(item, into: &out, pretty: pretty, depth: depth + 1)
            }
            newline(&out, pretty: pretty, depth: depth)
            out.append(UInt8(ascii: "]"))
        case let .object(obj):
            if obj.isEmpty {
                out.append(contentsOf: Array("{}".utf8))
                return
            }
            out.append(UInt8(ascii: "{"))
            for (i, entry) in obj.sorted(by: { $0.key < $1.key }).enumerated() {
                if i > 0 { out.append(UInt8(ascii: ",")) }
                newline(&out, pretty: pretty, depth: depth + 1)
                writeString(entry.key, into: &out)
                out.append(contentsOf: Array((pretty ? " : " : ":").utf8))
                try write(entry.value, into: &out, pretty: pretty, depth: depth + 1)
            }
            newline(&out, pretty: pretty, depth: depth)
            out.append(UInt8(ascii: "}"))
        }
    }

    private static func newline(_ out: inout [UInt8], pretty: Bool, depth: Int) {
        guard pretty else { return }
        out.append(UInt8(ascii: "\n"))
        for _ in 0..<(depth * 2) { out.append(UInt8(ascii: " ")) }
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    /// Escaping works on UTF-8 bytes: every byte of a multi-byte character is
    /// >= 0x80, so it can never be mistaken for a character needing an escape.
    private static func writeString(_ string: String, into out: inout [UInt8]) {
        out.append(UInt8(ascii: "\""))
        for byte in string.utf8 {
            switch byte {
            case UInt8(ascii: "\""): out.append(contentsOf: [0x5C, UInt8(ascii: "\"")])
            case UInt8(ascii: "\\"): out.append(contentsOf: [0x5C, 0x5C])
            // JSON doesn't require escaping this, but `JSONEncoder` does it, and
            // matching keeps stored documents byte-identical across the change.
            case UInt8(ascii: "/"): out.append(contentsOf: [0x5C, UInt8(ascii: "/")])
            case 0x08: out.append(contentsOf: [0x5C, UInt8(ascii: "b")])
            case 0x09: out.append(contentsOf: [0x5C, UInt8(ascii: "t")])
            case 0x0A: out.append(contentsOf: [0x5C, UInt8(ascii: "n")])
            case 0x0C: out.append(contentsOf: [0x5C, UInt8(ascii: "f")])
            case 0x0D: out.append(contentsOf: [0x5C, UInt8(ascii: "r")])
            case 0x00...0x1F:
                out.append(contentsOf: [0x5C, UInt8(ascii: "u"), UInt8(ascii: "0"), UInt8(ascii: "0")])
                out.append(hexDigits[Int(byte >> 4)])
                out.append(hexDigits[Int(byte & 0x0F)])
            default: out.append(byte)
            }
        }
        out.append(UInt8(ascii: "\""))
    }
}

public extension Node {
    /// Load a document node from a ProseMirror-shaped JSON string against the
    /// given schema. Throws `ModelError.invalidJSON` for malformed input, or a
    /// schema error for unknown node/mark types.
    static func fromJSON(_ json: String, schema: Schema) throws -> Node {
        try DocumentJSON.decode(schema, json)
    }

    /// Serialize this node to a ProseMirror-shaped JSON string. Dense by
    /// default, as `DocumentJSON.encode` is — pass `pretty: true` for output a
    /// person reads.
    func toJSONString(pretty: Bool = false) throws -> String {
        try DocumentJSON.string(self, pretty: pretty)
    }
}
