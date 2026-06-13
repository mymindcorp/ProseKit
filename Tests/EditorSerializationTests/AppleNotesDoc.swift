import Foundation
import DocumentModel
import EditorSerialization
import TestHarness

// Full-document conversion of the Apple Notes proto. Fixtures are synthesized
// with a minimal protobuf writer mirroring the Note schema the parser reads:
// Note { 2: text, 5: AttributeRun { 1: length, 2: ParagraphStyle { 1: style,
// 4: indent, 5: Checklist { 2: done } }, 5: font_weight, 6: underlined,
// 7: strikethrough, 9: link } }.

private func pvarint(_ v: UInt64) -> [UInt8] {
    var v = v, out: [UInt8] = []
    repeat {
        var b = UInt8(v & 0x7f)
        v >>= 7
        if v != 0 { b |= 0x80 }
        out.append(b)
    } while v != 0
    return out
}
private func chunk(_ field: Int, _ payload: [UInt8]) -> [UInt8] {
    pvarint(UInt64(field << 3 | 2)) + pvarint(UInt64(payload.count)) + payload
}
private func vint(_ field: Int, _ v: Int) -> [UInt8] { pvarint(UInt64(field << 3)) + pvarint(UInt64(v)) }

private func styleProto(type: Int? = nil, indent: Int? = nil, done: Bool? = nil) -> [UInt8] {
    var b: [UInt8] = []
    if let type { b += vint(1, type) }
    if let indent { b += vint(4, indent) }
    if let done { b += chunk(5, vint(2, done ? 1 : 0)) }
    return b
}
private func runProto(_ len: Int, style: [UInt8]? = nil, weight: Int? = nil,
                      underline: Bool = false, strike: Bool = false, link: String? = nil) -> [UInt8] {
    var b = vint(1, len)
    if let style { b += chunk(2, style) }
    if let weight { b += vint(5, weight) }
    if underline { b += vint(6, 1) }
    if strike { b += vint(7, 1) }
    if let link { b += chunk(9, Array(link.utf8)) }
    return b
}
private func noteProto(_ text: String, _ runs: [[UInt8]]) -> Data {
    Data(chunk(2, Array(text.utf8)) + runs.flatMap { chunk(5, $0) })
}

func registerAppleNotesDocTests() {
    test("Notes proto doc: title/heading/body lines") {
        let data = noteProto("Title\nHead\nbody\n", [
            runProto(6, style: styleProto(type: 0)),
            runProto(5, style: styleProto(type: 1)),
            runProto(5),
        ])
        let d = AppleNotesPasteboard.parseNoteDocument(data, schema: schema)
        try expectEqual(d, doc(h(1, "Title"), h(2, "Head"), p("body")))
    }

    test("Notes proto doc: inline marks (bold, strike, link)") {
        let data = noteProto("ab cd\n", [
            runProto(2, weight: 1),
            runProto(1),
            runProto(3, strike: true),
        ])
        let d = AppleNotesPasteboard.parseNoteDocument(data, schema: schema)
        try expectEqual(d, doc(p(strong("ab"), t(" "), schema.text("cd", [schema.mark("strike")]))))

        let linked = noteProto("go\n", [runProto(3, link: "https://x.dev")])
        try expectEqual(AppleNotesPasteboard.parseNoteDocument(linked, schema: schema),
                        doc(p(schema.text("go", [schema.mark("link", ["href": .string("https://x.dev")])]))))
    }

    test("Notes proto doc: checklist → task list with checked state") {
        let data = noteProto("a\nb\n", [
            runProto(2, style: styleProto(type: 103, done: true)),
            runProto(2, style: styleProto(type: 103, done: false)),
        ])
        let d = AppleNotesPasteboard.parseNoteDocument(data, schema: schema)
        try expectEqual(d, doc(taskListN(taskItemN(true, p("a")), taskItemN(false, p("b")))))
    }

    test("Notes proto doc: bullet/ordered lists + indent nesting") {
        let data = noteProto("a\nb\nc\n", [
            runProto(2, style: styleProto(type: 100)),
            runProto(2, style: styleProto(type: 100, indent: 1)),
            runProto(2, style: styleProto(type: 102)),
        ])
        let d = AppleNotesPasteboard.parseNoteDocument(data, schema: schema)
        try expectEqual(d, doc(ul(li(p("a"), ul(li(p("b"))))), ol(li(p("c")))))
    }

    test("Notes proto doc: list type switch at a nested indent starts a new nested list") {
        // bullet@0, bullet@1, numbered@1: the numbered line must become a nested
        // ordered list — not lose its type/indent into the outer bullet list.
        let data = noteProto("a\nb\nc\n", [
            runProto(2, style: styleProto(type: 100)),
            runProto(2, style: styleProto(type: 100, indent: 1)),
            runProto(2, style: styleProto(type: 102, indent: 1)),
        ])
        let d = AppleNotesPasteboard.parseNoteDocument(data, schema: schema)
        try expectEqual(d, doc(ul(li(p("a"), ul(li(p("b"))), ol(li(p("c")))))))
    }

    test("Notes proto doc: checklist line after a nested bullet doesn't drop the list") {
        // A taskItem must never be appended into a bulletList level (which would
        // fail validation and silently drop the whole list).
        let data = noteProto("a\nb\nt\n", [
            runProto(2, style: styleProto(type: 100)),
            runProto(2, style: styleProto(type: 100, indent: 1)),
            runProto(2, style: styleProto(type: 103, indent: 1, done: true)),
        ])
        let d = AppleNotesPasteboard.parseNoteDocument(data, schema: schema)
        try expectEqual(d, doc(ul(li(p("a"), ul(li(p("b"))), taskListN(taskItemN(true, p("t")))))))
    }

    test("Notes proto doc: monospaced lines merge into one code block") {
        let data = noteProto("x = 1\ny = 2\n", [
            runProto(6, style: styleProto(type: 4)),
            runProto(6, style: styleProto(type: 4)),
        ])
        let d = AppleNotesPasteboard.parseNoteDocument(data, schema: schema)
        try expectEqual(d, doc(node("codeBlock", [:], [t("x = 1\ny = 2")])))
    }

    test("Notes proto doc: real Apple Notes fixture converts to a task list") {
        let data = Data(base64Encoded: notesChecklistFixture)!
        let d = AppleNotesPasteboard.parseNoteDocument(data, schema: schema)
        try expectEqual(d, doc(taskListN(
            taskItemN(false, p("Beta")), taskItemN(false, p("Gamama")), taskItemN(true, p("Alpha")))))
    }

    test("Notes proto doc: matchingText guard rejects whole-note vs selection") {
        let data = noteProto("a\n", [runProto(2, style: styleProto(type: 100))])
        try expect(AppleNotesPasteboard.parseNoteDocument(data, schema: schema, matchingText: "different") == nil)
        try expectNotNil(AppleNotesPasteboard.parseNoteDocument(data, schema: schema, matchingText: "  a \n"))
    }

    test("Notes archive: blob hunt feeds both document() and checklist()") {
        let plist: [String: Any] = ["$objects": ["junk", Data(base64Encoded: notesChecklistFixture)!]]
        let arch = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        try expectNotNil(AppleNotesPasteboard.document(fromArchive: arch, schema: schema))
        try expectEqual(AppleNotesPasteboard.checklist(fromArchive: arch)?.count, 3)
    }

    test("Notes proto doc: hostile/garbage input returns nil, never traps") {
        try expect(AppleNotesPasteboard.parseNoteDocument(Data([0xff, 0x00, 0x12, 0x99, 0x7f]), schema: schema) == nil)
        try expect(AppleNotesPasteboard.parseNoteDocument(Data(), schema: schema) == nil)
        let huge = Data([0x12] + Array(repeating: 0x80, count: 9) + [0x01])
        try expect(AppleNotesPasteboard.parseNoteDocument(huge, schema: schema) == nil)
    }

    test("Notes proto doc: no trailing newline / only-newlines / underline degrade") {
        // Last line without a terminating "\n" still becomes a block.
        try expectEqual(AppleNotesPasteboard.parseNoteDocument(noteProto("hi", [runProto(2)]), schema: schema),
                        doc(p("hi")))
        // A note that is only blank lines trims to nothing → nil.
        try expect(AppleNotesPasteboard.parseNoteDocument(noteProto("\n\n", [runProto(2)]), schema: schema) == nil)
        // Underline runs map to the underline mark (the schema has one now).
        try expectEqual(AppleNotesPasteboard.parseNoteDocument(noteProto("u\n", [runProto(2, underline: true)]), schema: schema),
                        doc(p(schema.text("u", [schema.mark("underline")]))))
        // And degrade to plain in a schema without the mark.
        let bare: Schema = {
            let nodes: [(String, NodeSpec)] = [
                ("doc", NodeSpec(content: "block+")),
                ("paragraph", NodeSpec(content: "inline*", group: "block")),
                ("text", NodeSpec(group: "inline")),
            ]
            return try! Schema(nodes: nodes, marks: [], topNode: "doc")
        }()
        let plain = AppleNotesPasteboard.parseNoteDocument(noteProto("u\n", [runProto(2, underline: true)]), schema: bare)
        try expectEqual(plain?.textContent, "u")
        try expectEqual(plain?.child(0).child(0).marks.count, 0)
    }

    test("Notes proto fuzz: random, truncated, and bit-flipped inputs never crash") {
        // Deterministic xorshift so failures are reproducible.
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func rnd() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
        let fixture = [UInt8](Data(base64Encoded: notesChecklistFixture)!)
        for round in 0..<400 {
            var bytes: [UInt8]
            switch round % 3 {
            case 0: // pure noise
                bytes = (0..<Int(rnd() % 80)).map { _ in UInt8(truncatingIfNeeded: rnd()) }
            case 1: // truncated real fixture
                bytes = Array(fixture.prefix(Int(rnd() % UInt64(fixture.count + 1))))
            default: // bit-flipped real fixture
                bytes = fixture
                for _ in 0...(rnd() % 8) {
                    bytes[Int(rnd() % UInt64(bytes.count))] = UInt8(truncatingIfNeeded: rnd())
                }
            }
            let d = Data(bytes)
            _ = AppleNotesPasteboard.parseNoteProto(d)
            _ = AppleNotesPasteboard.parseNoteDocument(d, schema: schema)
            _ = AppleNotesPasteboard.checklist(fromArchive: d)
        }
    }
}
