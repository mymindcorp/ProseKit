import Foundation
import DocumentModel
import EditorStateKit
import EditorSerialization
import SchemaKit
import TestHarness

// Areas the existing math tests don't reach: math meeting the structural
// coercion, the editor's history and text projection, and the schemas a host
// might actually build.

private func mathEditor() throws -> Editor { try Editor(extensions: fullKit()) }

private func firstMath(_ doc: Node) -> Node? {
    var found: Node?
    doc.descendants { node, _, _, _ in
        if found == nil, node.type.name == "inlineMath" || node.type.name == "blockMath" { found = node }
        return found == nil
    }
    return found
}

func registerMathEdgeCaseTests() {
    test("math: block math pasted inside a paragraph is lifted out") {
        // A `blockMath` is block-level, so arriving in an inline position would
        // make the paragraph invalid — the same shape of problem a block image
        // in a paragraph had.
        let editor = try mathEditor()
        let doc = try HTMLParser.parse(
            "<p>before <div data-type=\"block-math\" data-latex=\"x^2\">$$x^2$$</div> after</p>",
            schema: editor.schema)
        try doc.check()
        try expectEqual(firstMath(doc)?.type.name, "blockMath")
        try expect(doc.textContent.contains("before"), doc.textContent)
        try expect(doc.textContent.contains("after"), doc.textContent)
    }

    test("math: a formula inside a list item stays valid") {
        let editor = try mathEditor()
        // Note: an *inline* formula inside a list item is currently lost, along
        // with every other inline mark there — `<li>` content is parsed as
        // blocks, so `<span>`/`<strong>`/`<em>` inside one are flattened. That
        // is a parser bug of its own, not a math one; see the block forms here.
        for html in ["<ul><li><div data-type=\"block-math\" data-latex=\"x\">$$x$$</div></li></ul>",
                     "<ul><li><math><mi>x</mi></math></li></ul>"] {
            let doc = try HTMLParser.parse(html, schema: editor.schema)
            try doc.check()
            try expect(firstMath(doc) != nil, html)
        }
    }

    test("math: a formula inside a table cell stays valid") {
        let editor = try mathEditor()
        let doc = try HTMLParser.parse(
            "<table><tr><td><math><mi>x</mi></math></td></tr></table>", schema: editor.schema)
        try doc.check()
        try expectNotNil(firstMath(doc))
    }

    test("math: display MathML falls back to the inline node when that's all the schema has") {
        // A host can build a schema with only one of the two math nodes.
        let inlineOnly = try Editor(extensions: starterKit() + [InlineMathExtension()])
        let doc = try HTMLParser.parse("<math display=\"block\"><mi>x</mi></math>", schema: inlineOnly.schema)
        try doc.check()
        try expectEqual(firstMath(doc)?.type.name, "inlineMath", "no block node, so it uses the inline one")

        // …and the other way round.
        let blockOnly = try Editor(extensions: starterKit() + [BlockMathExtension()])
        let inlineDoc = try HTMLParser.parse("<math><mi>x</mi></math>", schema: blockOnly.schema)
        try inlineDoc.check()
        try expectEqual(firstMath(inlineDoc)?.type.name, "blockMath")
    }

    test("math: undo restores a formula's previous source") {
        let editor = try mathEditor()
        try expect(editor.insertInlineMath(latex: "x^2"))
        let pos = try expectUnwrapped(positionOfMath(editor))
        try expect(editor.updateInlineMath(latex: "y^3", at: pos))
        try expectEqual(editor.doc.nodeAt(pos)?.attrs["latex"], .string("y^3"))

        try expect(key(editor, "Mod-z"), "the edit is undoable")
        try expectEqual(editor.doc.nodeAt(pos)?.attrs["latex"], .string("x^2"), "back to the original source")
        try expect(key(editor, "Mod-Shift-z"))
        try expectEqual(editor.doc.nodeAt(pos)?.attrs["latex"], .string("y^3"))
    }

    test("math: a formula reads as its source in the document's plain text") {
        // `leafText` is what copy, search and `getText` all see.
        let editor = try mathEditor()
        let s = editor.schema
        editor.setContent(try s.node("doc", [:], content: Fragment.from([
            try s.node("paragraph", [:], content: Fragment.from([
                s.text("let "), try s.node("inlineMath", ["latex": .string("x^2")]), s.text(" be"),
            ])),
            try s.node("blockMath", ["latex": .string("\\frac{a}{b}")]),
        ])))
        try expect(editor.getText().contains("$x^2$"), editor.getText())
        try expect(editor.getText().contains("$$\\frac{a}{b}$$"), editor.getText())
    }

    test("math: a formula's source is in the text projection but not in search") {
        // `getText` walks leaf text, so a formula reads as `$alpha$`; search
        // matches real text nodes, and an atom has none. Stated because the two
        // disagree and the difference is easy to be surprised by.
        let editor = try mathEditor()
        try type(editor, "before ")
        try expect(editor.insertInlineMath(latex: "alpha"))
        try expect(editor.getText().contains("$alpha$"), editor.getText())
        editor.setSearch("alpha")
        try expect(editor.searchMatches.isEmpty, "search doesn't look inside formulas")
        // Text outside the formula is still found.
        editor.setSearch("before")
        try expect(!editor.searchMatches.isEmpty)
    }

    test("math: an empty formula is still a valid node") {
        // `latex` defaults to empty, and the renderer draws nothing for it —
        // but it must not make the document invalid or vanish on a round-trip.
        let editor = try mathEditor()
        let s = editor.schema
        let doc = try s.node("doc", [:], content: Fragment.from([try s.node("blockMath")]))
        try doc.check()
        editor.setContent(doc)
        try expectEqual(editor.doc.child(0).attrs["latex"], .string(""))
        let restored = try HTMLParser.parse(editor.getHTML(), schema: s)
        try expectEqual(restored, doc)
    }

    test("math: source with markup characters survives HTML") {
        // `<`, `&` and quotes all mean something to both LaTeX and HTML.
        let editor = try mathEditor()
        for latex in ["a < b", "a & b", "x \"quoted\"", "\\text{<tag>}", "a <> b & c"] {
            let s = editor.schema
            let doc = try s.node("doc", [:], content: Fragment.from([
                try s.node("blockMath", ["latex": .string(latex)]),
            ]))
            editor.setContent(doc)
            let restored = try HTMLParser.parse(editor.getHTML(), schema: s)
            try expectEqual(firstMath(restored)?.attrs["latex"], .string(latex), latex)
        }
    }
}

/// The document position of the first math node.
private func positionOfMath(_ editor: Editor) -> Int? {
    var found: Int?
    editor.doc.descendants { node, pos, _, _ in
        if found == nil, node.type.name == "inlineMath" || node.type.name == "blockMath" { found = pos }
        return found == nil
    }
    return found
}

private func expectUnwrapped<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) throws -> T {
    try expect(value != nil, "expected a value", file: file, line: line)
    return value!
}
