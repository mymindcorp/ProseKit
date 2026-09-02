public import Foundation
public import DocumentModel

// MARK: - Reading

extension DocumentJSON {
    /// How deep a value may nest before the reader refuses it.
    ///
    /// The reader descends one Swift stack frame per open bracket, so a file of
    /// nothing but `[` would otherwise run the stack out — a crash, not an
    /// error the loader can refuse. Documents nest a few dozen levels at most;
    /// this matches the limit Foundation's parser applies.
    public static let maxNestingDepth = 512

    /// Parse JSON bytes into an `AttributeValue`.
    ///
    /// The document loader used to go through `JSONSerialization` and then
    /// walk the `Any` tree it built, asking each value its dynamic type. That
    /// walk cost five times what the parse itself did: a document is hundreds
    /// of thousands of small values, and each one was an `NSString` or
    /// `NSNumber` to allocate, bridge, and release. Reading the bytes straight
    /// into the enum, as the writer does in the other direction, takes that
    /// step from 16ms to 5ms on a 200 KB document, and the whole load — this,
    /// `Node.fromJSON`, and the document check — from 24ms to 10ms.
    ///
    /// The grammar is JSON's (RFC 8259) — any value at the top level, strict
    /// number syntax, no comments, strings in valid UTF-8 with their control
    /// characters escaped — plus the one liberty Foundation's parser takes,
    /// which is to allow a single trailing comma in an array or object. Where
    /// Foundation was strict, so is this: a `\u` escape naming a lone
    /// surrogate, or a number too large for a `Double`, refuses the document.
    /// Two equal keys keep the first, as Foundation kept it. Anything
    /// malformed throws `ModelError.invalidJSON`.
    ///
    /// Two things read differently, both on purpose. An integer past `Int`'s
    /// range is a `Double` here, where Foundation's wrapped it; and a decimal
    /// with more digits than a `Double` holds is correctly rounded, where
    /// Foundation's could land a few ulps off. (Foundation also lets the odd
    /// stray continuation byte through as U+FFFD while refusing every other
    /// kind of broken UTF-8; that is a quirk rather than a rule, and this
    /// reader refuses them all.)
    ///
    /// Input that isn't UTF-8 — UTF-16 or UTF-32 with a byte-order mark — is
    /// handed to Foundation, which knows how to read it, and bridged the old
    /// way; nothing in this codebase writes it, so that path exists for the
    /// odd file another tool produced rather than for speed.
    public static func parse(_ data: Data) throws -> AttributeValue {
        if isWideEncoding(data) {
            return try attributeValue(from: try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
        }
        // Read from a copy of the bytes rather than a pointer into `data`:
        // the copy is one pass over the input, which the parse is many of,
        // and it keeps this file free of unsafe code.
        var reader = JSONReader([UInt8](data))
        return try reader.parseTopLevel()
    }

    /// Whether `data` begins the way a UTF-16 or UTF-32 encoding of JSON does:
    /// with a byte-order mark, or with a zero byte in the first two — JSON
    /// opens with an ASCII character, so a UTF-8 document never has one there.
    private static func isWideEncoding(_ data: Data) -> Bool {
        guard data.count >= 2 else { return false }
        let first = data[data.startIndex], second = data[data.startIndex + 1]
        return first == 0 || second == 0 || first == 0xFF || first == 0xFE
    }
}

/// A recursive-descent reader over the UTF-8 bytes of a JSON text.
private struct JSONReader {
    private let bytes: [UInt8]
    private var index = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    private var count: Int { bytes.count }

    private func byte(at i: Int) -> UInt8 { bytes[i] }

    private func error(_ what: String) -> ModelError {
        .invalidJSON("\(what) at byte \(index)")
    }

    // MARK: Values

    mutating func parseTopLevel() throws -> AttributeValue {
        // A UTF-8 byte-order mark is not part of the text, and some editors
        // put one in front of every file they save.
        if count >= 3, byte(at: 0) == 0xEF, byte(at: 1) == 0xBB, byte(at: 2) == 0xBF { index = 3 }
        skipWhitespace()
        guard index < count else { throw error("Empty JSON") }
        let value = try parseValue(depth: 0)
        skipWhitespace()
        guard index == count else { throw error("Unexpected content after the JSON value") }
        return value
    }

    private mutating func parseValue(depth: Int) throws -> AttributeValue {
        guard index < count else { throw error("Unexpected end of JSON") }
        switch byte(at: index) {
        case UInt8(ascii: "{"):
            return try parseObject(depth: depth + 1)
        case UInt8(ascii: "["):
            return try parseArray(depth: depth + 1)
        case UInt8(ascii: "\""):
            return .string(try parseString())
        case UInt8(ascii: "t"):
            try expectLiteral("true"); return .bool(true)
        case UInt8(ascii: "f"):
            try expectLiteral("false"); return .bool(false)
        case UInt8(ascii: "n"):
            try expectLiteral("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            return try parseNumber()
        default:
            throw error("Unexpected character")
        }
    }

    private mutating func parseObject(depth: Int) throws -> AttributeValue {
        guard depth <= DocumentJSON.maxNestingDepth else { throw error("JSON nests too deeply") }
        index += 1  // "{"
        var object: [String: AttributeValue] = [:]
        skipWhitespace()
        if index < count, byte(at: index) == UInt8(ascii: "}") {
            index += 1
            return .object(object)
        }
        while true {
            skipWhitespace()
            guard index < count, byte(at: index) == UInt8(ascii: "\"") else {
                throw error("Expected a string key")
            }
            let key = try parseString()
            skipWhitespace()
            guard index < count, byte(at: index) == UInt8(ascii: ":") else { throw error("Expected ':'") }
            index += 1
            skipWhitespace()
            let value = try parseValue(depth: depth)
            // The first of two equal keys wins, which is what Foundation's
            // parser did for the same bytes.
            if object[key] == nil { object[key] = value }
            skipWhitespace()
            guard index < count else { throw error("Unterminated object") }
            switch byte(at: index) {
            case UInt8(ascii: ","):
                index += 1
                // Foundation accepts `{"a":1,}`, and so did the loader.
                skipWhitespace()
                if index < count, byte(at: index) == UInt8(ascii: "}") { index += 1; return .object(object) }
            case UInt8(ascii: "}"): index += 1; return .object(object)
            default: throw error("Expected ',' or '}'")
            }
        }
    }

    private mutating func parseArray(depth: Int) throws -> AttributeValue {
        guard depth <= DocumentJSON.maxNestingDepth else { throw error("JSON nests too deeply") }
        index += 1  // "["
        var array: [AttributeValue] = []
        skipWhitespace()
        if index < count, byte(at: index) == UInt8(ascii: "]") {
            index += 1
            return .array(array)
        }
        while true {
            skipWhitespace()
            array.append(try parseValue(depth: depth))
            skipWhitespace()
            guard index < count else { throw error("Unterminated array") }
            switch byte(at: index) {
            case UInt8(ascii: ","):
                index += 1
                // Foundation accepts `[1,]`, and so did the loader.
                skipWhitespace()
                if index < count, byte(at: index) == UInt8(ascii: "]") { index += 1; return .array(array) }
            case UInt8(ascii: "]"): index += 1; return .array(array)
            default: throw error("Expected ',' or ']'")
            }
        }
    }

    private mutating func expectLiteral(_ literal: StaticString) throws {
        let length = literal.utf8CodeUnitCount
        guard index + length <= count else { throw error("Unexpected end of JSON") }
        let matches = literal.withUTF8Buffer { expected -> Bool in
            for k in 0..<length where unsafe expected[k] != bytes[index + k] { return false }
            return true
        }
        guard matches else { throw error("Unexpected character") }
        index += length
    }

    private mutating func skipWhitespace() {
        while index < count {
            switch byte(at: index) {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    // MARK: Numbers

    /// A number in JSON's grammar: an optional minus, an integer part with no
    /// leading zero, and optional fraction and exponent parts. One with neither
    /// fraction nor exponent is an `Int` when it fits and a `Double` when it
    /// doesn't — the distinction `JSONSerialization` drew, which the attribute
    /// accessors and the writer both rely on.
    private mutating func parseNumber() throws -> AttributeValue {
        let start = index
        var negative = false
        if byte(at: index) == UInt8(ascii: "-") {
            negative = true
            index += 1
        }
        guard index < count, isDigit(byte(at: index)) else { throw error("Expected a digit") }
        var isInteger = true
        var magnitude: UInt64 = 0
        var overflowed = false
        if byte(at: index) == UInt8(ascii: "0") {
            index += 1
        } else {
            while index < count, isDigit(byte(at: index)) {
                let digit = UInt64(byte(at: index) - UInt8(ascii: "0"))
                let (scaled, o1) = magnitude.multipliedReportingOverflow(by: 10)
                let (sum, o2) = scaled.addingReportingOverflow(digit)
                if o1 || o2 { overflowed = true } else { magnitude = sum }
                index += 1
            }
        }
        if index < count, byte(at: index) == UInt8(ascii: ".") {
            isInteger = false
            index += 1
            guard index < count, isDigit(byte(at: index)) else { throw error("Expected a digit after '.'") }
            while index < count, isDigit(byte(at: index)) { index += 1 }
        }
        if index < count, byte(at: index) | 0x20 == UInt8(ascii: "e") {
            isInteger = false
            index += 1
            if index < count, byte(at: index) == UInt8(ascii: "+") || byte(at: index) == UInt8(ascii: "-") {
                index += 1
            }
            guard index < count, isDigit(byte(at: index)) else { throw error("Expected a digit in the exponent") }
            while index < count, isDigit(byte(at: index)) { index += 1 }
        }
        if isInteger, !overflowed {
            if negative {
                // `Int.min`'s magnitude is one past `Int.max`, and is an integer.
                if magnitude <= UInt64(Int.max) { return .int(-Int(magnitude)) }
                if magnitude == UInt64(Int.max) + 1 { return .int(.min) }
            } else if magnitude <= UInt64(Int.max) {
                return .int(Int(magnitude))
            }
        }
        // A fraction, an exponent, or an integer too large to hold.
        let text = String(decoding: bytes[start..<index], as: UTF8.self)
        // `1e400` is past what a `Double` can hold, and Foundation refused it
        // rather than reading infinity.
        guard let value = Double(text), value.isFinite else { throw error("Number out of range") }
        return .double(value)
    }

    private func isDigit(_ b: UInt8) -> Bool { b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9") }

    // MARK: Strings

    /// The string starting at the `"` under `index`, leaving `index` past its
    /// closing quote.
    private mutating func parseString() throws -> String {
        index += 1  // opening quote
        let start = index
        // Almost every string in a document is plain text with nothing to
        // unescape, so the fast path is a scan for the closing quote followed
        // by one validating decode of the bytes between.
        while index < count {
            let c = byte(at: index)
            if c == UInt8(ascii: "\"") {
                let text = try decode(start, index)
                index += 1
                return text
            }
            if c == UInt8(ascii: "\\") || c < 0x20 { break }
            index += 1
        }
        var out: [UInt8] = Array(bytes[start..<index])
        while index < count {
            let c = byte(at: index)
            switch c {
            case UInt8(ascii: "\""):
                index += 1
                guard let text = String(validating: out, as: UTF8.self) else {
                    throw error("Invalid UTF-8 in string")
                }
                return text
            case 0x00...0x1F:
                throw error("Unescaped control character in string")
            case UInt8(ascii: "\\"):
                index += 1
                guard index < count else { throw error("Unterminated string") }
                let escaped = byte(at: index)
                index += 1
                switch escaped {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(escaped)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    let scalar = try parseUnicodeEscape()
                    out.append(contentsOf: scalar.utf8)
                default:
                    throw error("Invalid escape in string")
                }
            default:
                out.append(c)
                index += 1
            }
        }
        throw error("Unterminated string")
    }

    /// The scalar named by the four hex digits after a `\u`, with `index` at
    /// the first digit. A high surrogate joins the `\uXXXX` low surrogate that
    /// has to follow it; a surrogate on its own is not a character, and
    /// Foundation refused the document, so this does too.
    private mutating func parseUnicodeEscape() throws -> Unicode.Scalar {
        let unit = try parseHex4()
        if unit < 0xD800 || unit > 0xDFFF {
            guard let scalar = Unicode.Scalar(unit) else { throw error("Invalid \\u escape") }
            return scalar
        }
        guard unit < 0xDC00,  // a low surrogate can't lead
              index + 1 < count, byte(at: index) == UInt8(ascii: "\\"), byte(at: index + 1) == UInt8(ascii: "u")
        else { throw error("Lone surrogate in \\u escape") }
        index += 2
        let low = try parseHex4()
        guard low >= 0xDC00, low <= 0xDFFF else { throw error("Lone surrogate in \\u escape") }
        let combined = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
        guard let scalar = Unicode.Scalar(combined) else { throw error("Invalid \\u escape") }
        return scalar
    }

    private mutating func parseHex4() throws -> UInt32 {
        guard index + 4 <= count else { throw error("Unterminated \\u escape") }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let c = byte(at: index)
            let digit: UInt32
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(c - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(c - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(c - UInt8(ascii: "A") + 10)
            default: throw error("Invalid hex digit in \\u escape")
            }
            value = value << 4 | digit
            index += 1
        }
        return value
    }

    /// The bytes in `lo..<hi` as a string, refusing invalid UTF-8 the way
    /// Foundation's parser does rather than repairing it silently.
    private func decode(_ lo: Int, _ hi: Int) throws -> String {
        guard lo < hi else { return "" }
        guard let text = String(validating: bytes[lo..<hi], as: UTF8.self) else {
            throw error("Invalid UTF-8 in string")
        }
        return text
    }
}
