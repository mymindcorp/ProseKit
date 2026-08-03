import Foundation
import DocumentModel
import TestHarness

// `AttributeValue` is what every node and mark attribute is: a heading's level,
// a link's href, a cell's colwidth and alignment. It is also the only part of a
// document that arrives verbatim from JSON, so it is where a pasted or synced
// document's worst input lands first.

func registerAttributeValueTests() {
    // MARK: Accessors

    test("AttributeValue: each accessor answers for its own case") {
        try expectEqual(AttributeValue.string("x").stringValue, "x")
        try expectEqual(AttributeValue.int(3).intValue, 3)
        try expectEqual(AttributeValue.double(1.5).doubleValue, 1.5)
        try expectEqual(AttributeValue.bool(true).boolValue, true)
        try expect(AttributeValue.null.isNull)
        try expect(!AttributeValue.int(0).isNull)
    }

    test("AttributeValue: an accessor for another case answers nothing") {
        let values: [AttributeValue] = [.null, .bool(true), .int(1), .double(1.5),
                                        .string("s"), .array([.int(1)]), .object(["a": .int(1)])]
        for v in values {
            if case .string = v {} else { try expect(v.stringValue == nil, "stringValue of \(v)") }
            if case .bool = v {} else { try expect(v.boolValue == nil, "boolValue of \(v)") }
        }
        // Not "0" or "" or false — nothing, so a caller's `?? default` holds.
        try expectNil(AttributeValue.string("5").intValue)
        try expectNil(AttributeValue.null.intValue)
        try expectNil(AttributeValue.array([]).doubleValue)
    }

    test("AttributeValue: whole numbers read as either int or double") {
        // Which case a JSON number lands in isn't something a caller should
        // have to know, so 3 and 3.0 both answer both questions.
        try expectEqual(AttributeValue.int(3).doubleValue, 3.0)
        try expectEqual(AttributeValue.double(3.0).intValue, 3)
        // A fraction truncates towards zero, as `Int(_:)` does.
        try expectEqual(AttributeValue.double(1.9).intValue, 1)
        try expectEqual(AttributeValue.double(-1.9).intValue, -1)
    }

    test("AttributeValue: a double no integer can hold reads as nothing") {
        // `Int(d)` traps on all of these, and a document decoded from JSON can
        // carry any of them — `{"colwidth": 1e300}` used to take the process
        // down the moment a table asked for its width.
        for d in [Double.infinity, -.infinity, .nan, 1e300, -1e300,
                  Double(Int.max) * 2, Double(Int.min) * 2] {
            try expect(AttributeValue.double(d).intValue == nil, "intValue of \(d)")
            // It is still a perfectly good double.
            if !d.isNaN { try expectEqual(AttributeValue.double(d).doubleValue, d) }
        }
        // The edges themselves still work.
        try expectEqual(AttributeValue.double(Double(Int.min)).intValue, Int.min)
        try expectEqual(AttributeValue.double(0).intValue, 0)
    }

    // MARK: Literals

    test("AttributeValue: literals build the case they look like") {
        let attrs: Attrs = ["a": nil, "b": true, "c": 3, "d": 1.5, "e": "s",
                            "f": [1, 2], "g": ["h": 4]]
        try expectEqual(attrs["a"], .null)
        try expectEqual(attrs["b"], .bool(true))
        try expectEqual(attrs["c"], .int(3))
        try expectEqual(attrs["d"], .double(1.5))
        try expectEqual(attrs["e"], .string("s"))
        try expectEqual(attrs["f"], .array([.int(1), .int(2)]))
        try expectEqual(attrs["g"], .object(["h": .int(4)]))
    }

    // MARK: Equality

    test("AttributeValue: cases don't compare across each other") {
        // 3 and 3.0 read alike through the accessors but are not the same
        // value — attribute comparison is what decides whether a node changed.
        try expect(AttributeValue.int(3) != AttributeValue.double(3.0))
        try expect(AttributeValue.null != AttributeValue.int(0))
        try expect(AttributeValue.bool(false) != AttributeValue.int(0))
        try expect(AttributeValue.string("3") != AttributeValue.int(3))
        // And the same case compares by value, including nested.
        try expectEqual(AttributeValue.object(["a": .array([.int(1)])]),
                        .object(["a": .array([.int(1)])]))
        try expect(AttributeValue.array([.int(1), .int(2)]) != .array([.int(2), .int(1)]))
    }

    test("AttributeValue: equal values hash alike") {
        // Node keys the block cache and its own equality off attributes.
        var seen = Set<AttributeValue>()
        seen.insert(.object(["a": .int(1)]))
        try expect(seen.contains(.object(["a": .int(1)])))
        try expect(!seen.contains(.object(["a": .int(2)])))
    }

    // MARK: Codable

    test("AttributeValue: every case survives a JSON round trip") {
        let values: [AttributeValue] = [
            .null, .bool(true), .bool(false), .int(0), .int(-7), .double(1.5),
            .string(""), .string("a \"quoted\" string"), .string("emoji 🎉 and 日本語"),
            .array([]), .array([.int(1), .string("x"), .null]),
            .object([:]), .object(["a": .int(1), "b": .array([.object(["c": .bool(true)])])]),
        ]
        for v in values {
            let data = try JSONEncoder().encode(v)
            let back = try JSONDecoder().decode(AttributeValue.self, from: data)
            try expectEqual(back, v, "round trip of \(v)")
        }
    }

    test("AttributeValue: a whole number decodes as an int, not a double") {
        // The decoder tries Int before Double on purpose: widening 3 to 3.0
        // would make an unchanged document compare as changed after a save.
        let back = try JSONDecoder().decode(AttributeValue.self, from: Data("3".utf8))
        try expectEqual(back, .int(3))
        try expectEqual(try JSONDecoder().decode(AttributeValue.self, from: Data("3.5".utf8)),
                        .double(3.5))
        // A bool stays a bool rather than becoming 1.
        try expectEqual(try JSONDecoder().decode(AttributeValue.self, from: Data("true".utf8)),
                        .bool(true))
    }

    test("AttributeValue: nested containers decode to nested cases") {
        let json = #"{"a":[1,"two",{"b":null}],"c":false}"#
        let back = try JSONDecoder().decode(AttributeValue.self, from: Data(json.utf8))
        try expectEqual(back, .object([
            "a": .array([.int(1), .string("two"), .object(["b": .null])]),
            "c": .bool(false),
        ]))
    }

    test("AttributeValue: encoding writes plain JSON, not a tagged case") {
        // What goes over the collab wire and into a saved document, so the
        // shape matters beyond round-tripping with ourselves.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let out = String(decoding: try encoder.encode(
            AttributeValue.object(["n": .null, "s": .string("x"), "i": .int(2)])), as: UTF8.self)
        try expectEqual(out, #"{"i":2,"n":null,"s":"x"}"#)
    }
}
