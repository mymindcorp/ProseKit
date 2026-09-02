import Foundation
import DocumentModel
import EditorSerialization
import TestHarness

// RTF corners the fixture suite doesn't reach: the control symbols that are
// punctuation rather than text, a parameter that is a bare minus sign, the
// Symbol-charset bullet Word writes for a list marker, a table left unclosed,
// and what the reader does when the schema it is given has no node for what it
// found. Every one of these is something a real producer emits, or something a
// truncated paste arrives as.

private let edgeHeader =
    #"{\rtf1\ansi\ansicpg1252\deff0{\fonttbl{\f0\fswiss Helvetica;}{\f1\fmodern Courier New;}{\f3\fnil\fcharset2 Symbol;}}"#
private func edgeRTF(_ body: String) -> String { edgeHeader + body + "}" }

/// A schema with no code block, heading, or table nodes — the reader has to
/// find another way to say what it read.
private let plainSchema: Schema = try! Schema(nodes: [
    ("doc", NodeSpec(content: "block+")),
    ("paragraph", NodeSpec(content: "inline*", group: "block")),
    ("text", NodeSpec(group: "inline")),
], marks: [
    ("bold", MarkSpec()),
    ("italic", MarkSpec()),
    ("highlight", MarkSpec(attrs: ["color": AttributeSpec(default: .null)])),
])

/// The block-level shape of a document, for assertions that are about
/// structure rather than text.
private func shapeOf(_ d: Node) -> [String] {
    (0 ..< d.childCount).map { d.child($0).type.name }
}

func registerRTFEdgeTests() {
    // MARK: Control symbols

    test("RTF: a line break in the source is formatting, not text") {
        // Producers wrap long lines. The bytes are in the file; none of them
        // belong in the document.
        let d = try RTFParser.parse(edgeRTF("\\pard Hello\nthere\r\nworld\\par"), schema: schema)
        try expectEqual(d, doc(p("Hellothereworld")))
    }

    test("RTF: an escaped newline ends the paragraph, the way \\par does") {
        let d = try RTFParser.parse(edgeRTF("\\pard first\\\nsecond\\par"), schema: schema)
        try expectEqual(shapeOf(d), ["paragraph", "paragraph"])
        try expectEqual(d.textContent, "firstsecond")
    }

    test("RTF: the formatting-only control symbols leave nothing behind") {
        // `\:` is a subentry mark and `\|` a formula character: both are index
        // and field punctuation, and neither is text.
        let d = try RTFParser.parse(edgeRTF(#"\pard a\:b\|c\par"#), schema: schema)
        try expectEqual(d, doc(p("abc")))
    }

    test("RTF: the hyphen controls are kept, dropped, and spaced as each one means") {
        // `\_` is a non-breaking hyphen (a real character), `\-` an optional
        // one (invisible unless the line breaks there), `\~` a non-breaking
        // space.
        let d = try RTFParser.parse(edgeRTF(#"\pard a\_b\-c\~d\par"#), schema: schema)
        try expectEqual(d.textContent, "a\u{2011}bc\u{00A0}d")
    }

    // MARK: Parameters

    test("RTF: a control word whose parameter is a bare minus reads as zero") {
        // `\li-` has a sign and no digits. Left as -1, or as the previous
        // paragraph's indent, it would nest the paragraph into a list.
        let d = try RTFParser.parse(edgeRTF(#"\pard\li- text\par"#), schema: schema)
        try expectEqual(shapeOf(d), ["paragraph"], "indent zero, so no list")
        try expectEqual(d.textContent, "text")
    }

    test("RTF: an absurdly long parameter is bounded rather than overflowing") {
        let d = try RTFParser.parse(edgeRTF(#"\pard\li99999999999999999999 text\par"#), schema: schema)
        try expectEqual(d.textContent, "text")
    }

    // MARK: Symbol-charset text

    test("RTF: a Symbol-font byte reads as the bullet it draws, not as its code page") {
        // Word writes list bullets as `\f3\'b7` in the Symbol charset, which is
        // not text in any code page. cp1252's `·` is the glyph it stands for.
        let d = try RTFParser.parse(edgeRTF(#"\pard\f3\'b7\f0  item\par"#), schema: schema)
        try expect(d.textContent.contains("\u{00B7}"), "got: \(d.textContent)")
    }

    // MARK: Tables

    test("RTF: a table cut off before its last row still yields the rows it has") {
        // A truncated paste, or a producer that left off the final `\row`. The
        // cells that were being filled are closed rather than dropped.
        let body = #"\pard\intbl one\cell two\cell\row \pard\intbl three\cell four\par"#
        let d = try RTFParser.parse(edgeRTF(body), schema: schema)
        try expect(shapeOf(d).contains("table"), "got \(shapeOf(d))")
        var rows = 0
        d.descendants { node, _, _, _ in
            if node.type.name == "tableRow" { rows += 1 }
            return true
        }
        try expectEqual(rows, 2, "the unclosed row is closed, not discarded")
        try expect(d.textContent.contains("three"), "and its content survives")
    }

    test("RTF: a table read into a schema with no table nodes keeps its cells' text") {
        let body = #"\pard\intbl one\cell two\cell\row"#
        let d = try RTFParser.parse(edgeRTF(body), schema: plainSchema)
        try expectEqual(shapeOf(d), ["paragraph", "paragraph"])
        try expect(d.textContent.contains("one") && d.textContent.contains("two"), "got: \(d.textContent)")
    }

    // MARK: Checkboxes in list markers

    test("RTF: a list item that is only a checkbox becomes an empty checked item") {
        // The glyph is the whole of the item's text, so removing it leaves the
        // run empty rather than shortened.
        // U+2611 as RTF spells a Unicode character: decimal, with a fallback char.
        let body = #"\pard\li720\fi-360 {\listtext\t\'b7\t}\u9745?\par"#
        let d = try RTFParser.parse(edgeRTF(body), schema: schema)
        var checked: [AttributeValue?] = []
        d.descendants { node, _, _, _ in
            if node.type.name == "taskItem" { checked.append(node.attrs["checked"]) }
            return true
        }
        try expectEqual(checked, [.bool(true)], "one checked task, with nothing written on it")
    }

    // MARK: Colors

    test("RTF: a background color becomes a highlight when the schema has no background mark") {
        // `plainSchema` declares `highlight` and no `backgroundColor`, which is
        // the shape a note-taking schema usually has.
        let body = #"{\colortbl;\red255\green255\blue0;}\pard \highlight1 marked\highlight0 \par"#
        let d = try RTFParser.parse(edgeRTF(body), schema: plainSchema)
        var names: [String] = []
        d.descendants { node, _, _, _ in
            names.append(contentsOf: node.marks.map(\.type.name))
            return true
        }
        try expect(names.contains("highlight"), "got marks \(names)")
    }

    // MARK: Schemas missing a block type

    test("RTF: monospaced paragraphs become a code block, or plain paragraphs without one") {
        let body = #"\pard\f1 let x = 1\par\pard\f1 let y = 2\par"#
        let rich = try RTFParser.parse(edgeRTF(body), schema: schema)
        try expectEqual(shapeOf(rich), ["codeBlock"], "consecutive monospaced paragraphs are one block")
        try expectEqual(rich.textContent, "let x = 1\nlet y = 2")
        // Without a code block to put them in, they stay the paragraphs they
        // look like — one per line, so nothing is run together.
        let plain = try RTFParser.parse(edgeRTF(body), schema: plainSchema)
        try expectEqual(shapeOf(plain), ["paragraph", "paragraph"])
        try expectEqual(plain.textContent, "let x = 1let y = 2")
    }

    test("RTF: a heading falls back to a paragraph when the schema has no heading") {
        let body = #"\pard\outlinelevel0 Title\par\pard Body\par"#
        let rich = try RTFParser.parse(edgeRTF(body), schema: schema)
        try expectEqual(shapeOf(rich), ["heading", "paragraph"])
        let plain = try RTFParser.parse(edgeRTF(body), schema: plainSchema)
        try expectEqual(shapeOf(plain), ["paragraph", "paragraph"])
        try expectEqual(plain.textContent, "TitleBody")
    }

    // MARK: Not RTF at all

    test("RTF: input that doesn't start with an RTF header is refused") {
        try expectThrows { _ = try RTFParser.parse("<html><p>hi</p></html>", schema: schema) }
        try expectThrows { _ = try RTFParser.parse("", schema: schema) }
        // And the refusal says which one it was.
        do {
            _ = try RTFParser.parse("plain text", schema: schema)
            try expect(false, "should have thrown")
        } catch let error as RTFParseError {
            try expectEqual(error, .notRTF)
        }
    }
}
