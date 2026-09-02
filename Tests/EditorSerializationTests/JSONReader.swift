import Foundation
import DocumentModel
import EditorSerialization
import TestHarness

// The direct JSON reader, held to what `JSONSerialization` used to answer for
// the document loader: the same values from the same bytes, and a refusal —
// never a trap — for everything malformed.

private func parse(_ json: String) throws -> AttributeValue {
    try DocumentJSON.parse(Data(json.utf8))
}

/// What the loader used to build for the same bytes.
private func foundationParse(_ json: String) throws -> AttributeValue {
    try DocumentJSON.attributeValue(
        from: try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed]))
}

func registerJSONReaderTests() {
    test("JSON reader: every value shape reads back as written") {
        let cases: [AttributeValue] = [
            .object(["b": .int(1), "a": .int(2), "C": .int(3), "": .int(4)]),
            .string(""), .string("quote \" backslash \\ slash /"),
            .string("newline \n tab \t return \r bell \u{07} nul \u{00} vt \u{0B}"),
            .string("emoji 👨‍👩‍👧 accents éü CJK 日本語 math ∑∫"),
            .int(0), .int(-1), .int(Int.max), .int(Int.min),
            .double(1.5), .double(-0.25), .double(1e100), .double(1e-7), .double(100),
            .bool(true), .bool(false), .null,
            .object(["nested": .array([.object(["deep": .array([.int(1), .null])])])]),
            .array([]), .object([:]), .array([.array([]), .object([:])]),
            .object(doc(p(t("hi"), strong("!"), em("?")), h(1, "Title")).toJSON()),
        ]
        var mismatches: [String] = []
        for value in cases {
            for pretty in [false, true] {
                let bytes = try DocumentJSON.encode(value, pretty: pretty)
                let read = try DocumentJSON.parse(bytes)
                if read != value { mismatches.append("\(value) pretty=\(pretty): read \(read)") }
                let viaFoundation = try DocumentJSON.attributeValue(
                    from: try JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed]))
                if read != viaFoundation { mismatches.append("\(value) pretty=\(pretty): Foundation read \(viaFoundation)") }
            }
        }
        try expect(mismatches.isEmpty, "\(mismatches.count) mismatch(es):\n" + mismatches.joined(separator: "\n"))
    }

    test("JSON reader: a document survives the file loader") {
        let source = doc(h(1, "Title"), p(t("plain "), strong("bold"), t(" and "), em("italic")), p(""))
        let loaded = try DocumentJSON.decode(schema, try DocumentJSON.encode(source))
        try expectEqual(loaded, source)
        let pretty = try DocumentJSON.decode(schema, try DocumentJSON.string(source, pretty: true))
        try expectEqual(pretty, source)
    }

    test("JSON reader: escapes and surrogate pairs decode") {
        try expectEqual(try parse(#""\u00e9\u00FC""#), .string("éü"))
        try expectEqual(try parse(#""\ud83d\ude00""#), .string("😀"))
        try expectEqual(try parse(#""\uD83D\uDE00 x""#), .string("😀 x"))
        try expectEqual(try parse(#""\"\\\/\b\f\n\r\t""#), .string("\"\\/\u{08}\u{0C}\n\r\t"))
        try expectEqual(try parse(#""\u0000""#), .string("\u{00}"))
        try expectEqual(try parse(#""a\u0041b""#), .string("aAb"))
        // A surrogate with no partner is not a character, and Foundation
        // refused the document; so does this.
        for lone in [#""\ud83d""#, #""\ude00""#, #""\ud83d\u0041""#, #""\ud83dx""#] {
            try expectThrows { _ = try parse(lone) }
        }
        // Raw multi-byte text, with escapes around it.
        try expectEqual(try parse(#""日本\n語""#), .string("日本\n語"))
    }

    test("JSON reader: numbers keep their type") {
        try expectEqual(try parse("0"), .int(0))
        try expectEqual(try parse("-0"), .int(0))
        try expectEqual(try parse("123"), .int(123))
        try expectEqual(try parse("-45"), .int(-45))
        try expectEqual(try parse("9223372036854775807"), .int(Int.max))
        try expectEqual(try parse("-9223372036854775808"), .int(Int.min))
        try expectEqual(try parse("1.0"), .double(1))
        try expectEqual(try parse("-0.0"), .double(0))
        try expectEqual(try parse("1.5"), .double(1.5))
        try expectEqual(try parse("-0.25"), .double(-0.25))
        try expectEqual(try parse("1e2"), .double(100))
        try expectEqual(try parse("1E+2"), .double(100))
        try expectEqual(try parse("25e-1"), .double(2.5))
        try expectEqual(try parse("1e100"), .double(1e100))
        // An exponent past what a Double can hold: underflow is zero, as it
        // is in IEEE arithmetic, and overflow is refused in either sign.
        // (Foundation refused `1e-1000` and read `-1e1000` as an infinity;
        // neither is an answer worth keeping.)
        try expectEqual(try parse("1e-1000"), .double(0))
        try expectEqual(try parse("1e-99999999999"), .double(0))
        try expectThrows { _ = try parse("-1e1000") }
        // Too big for an Int is still a number.
        try expectEqual(try parse("9223372036854775808"), .double(9223372036854775808))
        try expectEqual(try parse("-9223372036854775809"), .double(-9.223372036854776e18))
        try expectEqual(try parse("123456789012345678901234567890"), .double(1.2345678901234568e29))
        for bad in ["01", "1.", ".5", "+1", "1e", "1e+", "-", "--1", "0x10", "1_000", "NaN", "Infinity", "1.5.2", "1e400", "-1e400"] {
            try expectThrows { _ = try parse(bad) }
        }
    }

    test("JSON reader: whitespace, a byte-order mark, duplicate keys and a trailing comma") {
        try expectEqual(try parse(" \n\t{ \"a\" : [ 1 , 2 ] , \"b\" : { } } \r\n"),
                        .object(["a": .array([.int(1), .int(2)]), "b": .object([:])]))
        try expectEqual(try parse("\u{FEFF}{\"a\":1}"), .object(["a": .int(1)]))
        // What Foundation's parser answered for the same bytes: the first key
        // wins, and one trailing comma is tolerated.
        try expectEqual(try parse("{\"a\":1,\"a\":2}"), .object(["a": .int(1)]))
        try expectEqual(try parse("{\"a\":1,}"), .object(["a": .int(1)]))
        try expectEqual(try parse("[1,]"), .array([.int(1)]))
        try expectEqual(try parse("[1 , ]"), .array([.int(1)]))
        try expectEqual(try parse("\"top-level string\""), .string("top-level string"))
        try expectEqual(try parse("[]"), .array([]))
        // A key goes through the same string path as a value, escapes and all.
        try expectEqual(try parse(#"{"a\"b\u0041\n":1}"#), .object(["a\"bA\n": .int(1)]))
        // Whitespace JSON doesn't allow: vertical tab, form feed, a no-break
        // space, a next-line character.
        for bad in ["[1\u{0B}]", "[\u{0C}1]", "\u{A0}[1]", "[1]\u{85}", "{\"a\"\u{0B}:1}"] {
            try expectThrows { _ = try parse(bad) }
        }
    }

    test("JSON reader: bytes that aren't UTF-8 are refused, on both string paths") {
        // Foundation refused these too — all but a stray continuation byte
        // in the 0xA0 range, which it let through as U+FFFD while refusing
        // 0x80 and 0xFF beside it. That is a quirk, not a rule, and the
        // reader refuses the lot.
        for bytes in [
            [0x22, 0x61, 0xFF, 0x62, 0x22],
            [0x22, 0xC3, 0x22],
            [0x22, 0x61, 0x80, 0x62, 0x22],
            [0x22, 0x61, 0x5C, 0x6E, 0xFF, 0x22],
            [0x22, 0xE2, 0x82, 0x22],
            [0x7B, 0x22, 0x6B, 0xFF, 0x22, 0x3A, 0x31, 0x7D],
        ] as [[UInt8]] {
            let data = Data(bytes)
            try expectThrows { _ = try DocumentJSON.parse(data) }
            try expectThrows { _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
        }
    }

    test("JSON reader: a long string that turns out to need unescaping") {
        // The fast path scans for the closing quote and gives up at the first
        // escape; here that is thousands of bytes in, so the slow path has to
        // pick up everything already scanned.
        let head = String(repeating: "x", count: 10_000)
        try expectEqual(try parse("\"" + head + "\\n\\u00e9tail\""), .string(head + "\né" + "tail"))
        try expectEqual(try parse("\"" + head + "\""), .string(head))
    }

    test("JSON reader: other encodings load exactly when Foundation reads them") {
        // The loader used to be Foundation's parser, which reads UTF-16 and
        // most UTF-32; those bytes are handed back to it, so what loaded
        // before loads now and what didn't still doesn't.
        let source = doc(p(t("wide")))
        let json = try DocumentJSON.string(source)
        var checked = 0
        for encoding in [String.Encoding.utf16, .utf16LittleEndian, .utf16BigEndian,
                         .utf32, .utf32LittleEndian, .utf32BigEndian] {
            guard let data = json.data(using: encoding) else { continue }
            let foundationReads = (try? JSONSerialization.jsonObject(with: data)) != nil
            let loaded = try? DocumentJSON.decode(schema, data)
            try expect((loaded != nil) == foundationReads, "\(encoding): Foundation \(foundationReads), loader \(loaded != nil)")
            if let loaded { try expectEqual(loaded, source, "\(encoding)"); checked += 1 }
        }
        try expect(checked >= 3, "only \(checked) wide encodings loaded")
    }

    test("JSON reader refuses malformed input, and never traps") {
        let bad = [
            "", " ", "{", "[", "{\"a\"", "{\"a\":", "{\"a\":1", "{\"a\":1,", "{\"a\":1,,}", "{,}",
            "[,1]", "[1,,2]", "[1 2]", "{\"a\" 1}", "{a:1}", "'a'", "{} x", "[] []", "1 2",
            "\"unterminated", "\"bad \\x escape\"", "\"\\u12\"", "\"\\u12G4\"", "\"tab\there\"",
            "\"newline\nhere\"", "nul", "tru", "falsy", "True", "NULL", "undefined",
            "\"\\", "\"\\u", "\"\\ud83d\\u", "\"\\ud83d\\ude0", "[1]//c", "/*c*/[1]", "1e400",
        ]
        for json in bad {
            try expectThrows { _ = try parse(json) }
        }
        var invalid = Data("\"".utf8); invalid.append(0xFF); invalid.append(contentsOf: "\"".utf8)
        try expectThrows { _ = try DocumentJSON.parse(invalid) }
        var truncatedEscape = Data("\"\\u00".utf8); truncatedEscape.append(0xC3); truncatedEscape.append(0xA9)
        try expectThrows { _ = try DocumentJSON.parse(truncatedEscape) }
        // Every prefix of a real document is a truncated file.
        let json = try DocumentJSON.string(doc(h(1, "Title"), p(t("plain "), strong("bold \"quoted\" \\"), em("é"))))
        let bytes = Array(json.utf8)
        for length in 0..<bytes.count {
            try expectThrows { _ = try DocumentJSON.parse(Data(bytes[0..<length])) }
        }
        // Nesting past the limit is refused rather than overflowing the stack.
        try expectThrows { _ = try parse(String(repeating: "[", count: 100_000)) }
        try expectThrows { _ = try parse(String(repeating: "[", count: 100_000) + String(repeating: "]", count: 100_000)) }
        try expectThrows { _ = try parse(String(repeating: "{\"a\":", count: 100_000)) }
        _ = try parse(String(repeating: "[", count: 500) + String(repeating: "]", count: 500))
    }

    test("JSON reader agrees with Foundation on what it refuses") {
        // Both answers must match on every input, so the loader's behaviour is
        // unchanged: what it read before it reads now, what it refused it
        // still refuses.
        let inputs = [
            "{\"type\":\"doc\",\"content\":[{\"type\":\"paragraph\"}]}", "[1,2.5,\"x\",true,null]",
            "{}", "[]", "\"\"", "0", "-0", "-1.5e3", "1E+2", "{\"a\":{\"b\":[[]]}}", "{\"a\":1,}", "[1,]",
            "[,1]", "{,}", "[1,,2]", "{\"a\":1,,}", "{\"a\"}", "{\"a\":1 \"b\":2}", "{\"a\":1,\"a\":2}",
            "\"\\ud83d\\ude00\"", "\"\\u00e9\"", "\"\\u0000\"", "\"\\ud83d\"", "\"\\ude00\"",
            "  [ ]  ", "\u{FEFF}[1]", "[1] [2]", "1 2", "01", "1.", "1.0", "-0.0", ".5", "+1", "-", "NaN", "Infinity", "1e400",
            "[1\u{0B}]", "[\u{0C}1]", "\u{A0}[1]", "[1]\u{85}", #"{"a\"b\u0041":1}"#,
            "\"a\\/b\"", "\"\\x\"", "\"tab\there\"", "'a'", "[1]//c", "nul", "True", "[", " ",
        ]
        for input in inputs {
            let ours = try? parse(input)
            let theirs = try? foundationParse(input)
            try expect((ours == nil) == (theirs == nil), "refusal differs for \(input): ours \(String(describing: ours)), Foundation \(String(describing: theirs))")
            if let ours, let theirs { try expectEqual(ours, theirs, input) }
        }
    }
}
