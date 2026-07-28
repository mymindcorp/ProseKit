import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import EditorCommands
import SchemaKit
import TestHarness

// Registered into the shared `collector` from main.swift.

/// The position + node of the first math node of the given type, if any.
private func firstMath(_ editor: Editor, _ name: String) -> (pos: Int, node: Node)? {
    var found: (Int, Node)?
    editor.doc.descendants { node, pos, _, _ in
        if found == nil, node.type.name == name { found = (pos, node) }
        return found == nil
    }
    return found
}

private func mathEditor() throws -> Editor { try Editor(extensions: fullKit()) }

func registerMathTests() {
    test("math: the schema has inlineMath and blockMath") {
        let editor = try mathEditor()
        let inline = editor.schema.nodes["inlineMath"]
        let block = editor.schema.nodes["blockMath"]
        try expectNotNil(inline)
        try expectNotNil(block)
        try expectEqual(inline?.defaultAttrs["latex"], .string(""))
        try expectEqual(block?.defaultAttrs["latex"], .string(""))
        try expect(inline?.spec.inline == true, "inline math sits in a line of text")
        try expect(inline?.spec.atom == true)
        try expect(block?.spec.inline == false, "block math owns its row")
        try expect(block?.spec.atom == true)
    }

    test("math: insertInlineMath puts a formula at the cursor") {
        let editor = try mathEditor()
        try type(editor, "let ")
        try expect(editor.insertInlineMath(latex: "x^2"))
        let math = firstMath(editor, "inlineMath")
        try expectEqual(math?.node.attrs["latex"], .string("x^2"))
        try expectEqual(editor.doc.child(0).childCount, 2, "the text and the formula share a paragraph")
    }

    test("math: insertBlockMath adds a block of its own") {
        let editor = try mathEditor()
        try expect(editor.insertBlockMath(latex: "E = mc^2"))
        let math = firstMath(editor, "blockMath")
        try expectNotNil(math)
        try expectEqual(math?.node.attrs["latex"], .string("E = mc^2"))
        try expectEqual(math?.node.nodeSize, 1, "a block formula is a leaf atom")
    }

    test("math: an explicit position inserts there instead of at the selection") {
        let editor = try mathEditor()
        try type(editor, "ab")
        try expect(editor.insertInlineMath(latex: "y", at: 2))
        // "a", formula, "b"
        let paragraph = editor.doc.child(0)
        try expectEqual(paragraph.childCount, 3)
        try expectEqual(paragraph.child(1).type.name, "inlineMath")
        try expectEqual(paragraph.textContent, "a$y$b", "leafText round-trips the source")
    }

    test("math: an out-of-range position is refused") {
        let editor = try mathEditor()
        try expect(!editor.insertInlineMath(latex: "x", at: 9999))
    }

    test("math: updateInlineMath rewrites the source in place") {
        let editor = try mathEditor()
        try expect(editor.insertInlineMath(latex: "x"))
        let pos = firstMath(editor, "inlineMath")!.pos
        try expect(editor.updateInlineMath(latex: "x^2 + 1", at: pos))
        try expectEqual(firstMath(editor, "inlineMath")?.node.attrs["latex"], .string("x^2 + 1"))
    }

    test("math: update and delete find the node the selection addresses") {
        let editor = try mathEditor()
        try expect(editor.insertInlineMath(latex: "a"))
        // The cursor sits right after the formula it just inserted.
        try expect(editor.updateInlineMath(latex: "b"))
        try expectEqual(firstMath(editor, "inlineMath")?.node.attrs["latex"], .string("b"))
        try expect(editor.deleteInlineMath())
        try expectNil(firstMath(editor, "inlineMath"))
    }

    test("math: a NodeSelection over the formula addresses it too") {
        let editor = try mathEditor()
        try expect(editor.insertBlockMath(latex: "a"))
        let pos = firstMath(editor, "blockMath")!.pos
        editor.dispatch(editor.state.tr.setSelection(NodeSelection(editor.doc.resolve(pos))))
        try expect(editor.updateBlockMath(latex: "b"))
        try expectEqual(firstMath(editor, "blockMath")?.node.attrs["latex"], .string("b"))
    }

    test("math: update and delete are no-ops when no formula is addressed") {
        let editor = try mathEditor()
        try type(editor, "plain")
        try expect(!editor.updateInlineMath(latex: "x"))
        try expect(!editor.deleteInlineMath())
        try expect(!editor.deleteBlockMath())
    }

    test("math: deleteBlockMath removes the whole node") {
        let editor = try mathEditor()
        try expect(editor.insertBlockMath(latex: "a"))
        let pos = firstMath(editor, "blockMath")!.pos
        try expect(editor.deleteBlockMath(at: pos))
        try expectNil(firstMath(editor, "blockMath"))
    }

    test("math: typing $…$ converts to an inline formula") {
        let editor = try mathEditor()
        try type(editor, "sum: $x^2")
        try expect(textInput(editor, at: editor.state.selection.from, "$"))
        let math = firstMath(editor, "inlineMath")
        try expectNotNil(math)
        try expectEqual(math?.node.attrs["latex"], .string("x^2"))
        try expectEqual(editor.doc.child(0).textContent, "sum: $x^2$")
    }

    test("math: an empty $$ doesn't become a formula") {
        let editor = try mathEditor()
        try type(editor, "$")
        try expect(!textInput(editor, at: editor.state.selection.from, "$"))
        try expectNil(firstMath(editor, "inlineMath"))
    }

    test("math: a $ followed by a space doesn't open a formula") {
        // "$ 5 and 6$" reads as prose about money, not as math — the rule needs
        // a non-space right after the opening $.
        let editor = try mathEditor()
        try type(editor, "costs $ 5 and 6")
        try expect(!textInput(editor, at: editor.state.selection.from, "$"))
        try expectNil(firstMath(editor, "inlineMath"))
    }

    test("math: typing $$…$$ on its own converts to a block formula") {
        let editor = try mathEditor()
        try type(editor, "$$a^2 + b^2$")
        try expect(textInput(editor, at: editor.state.selection.from, "$"))
        let math = firstMath(editor, "blockMath")
        try expectNotNil(math)
        try expectEqual(math?.node.attrs["latex"], .string("a^2 + b^2"))
    }

    test("math: $$…$$ mid-sentence stays text") {
        let editor = try mathEditor()
        try type(editor, "see $$x$")
        try expect(!textInput(editor, at: editor.state.selection.from, "$"))
        try expectNil(firstMath(editor, "blockMath"))
    }

    test("math: input rules don't fire inside a code block") {
        let editor = try mathEditor()
        try type(editor, "x")
        try expect(editor.run("toggleCodeBlock"))
        let end = editor.doc.content.size - 1
        editor.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.doc, end)))
        let tr = editor.state.tr
        try tr.insertText("$y", end)
        editor.dispatch(tr)
        try expect(!textInput(editor, at: editor.state.selection.from, "$"))
        try expectNil(firstMath(editor, "inlineMath"))
    }

    test("math: migrateMathStrings converts every $…$ run") {
        let editor = try mathEditor()
        try type(editor, "when $x > 0$ then $y = x^2$ holds")
        try expect(editor.migrateMathStrings())
        let paragraph = editor.doc.child(0)
        var formulas: [String] = []
        paragraph.descendants { node, _, _, _ in
            if node.type.name == "inlineMath" { formulas.append(node.attrs["latex"]?.stringValue ?? "") }
            return true
        }
        try expectEqual(formulas, ["x > 0", "y = x^2"])
        try expectEqual(paragraph.textContent, "when $x > 0$ then $y = x^2$ holds",
                        "the plain-text form is unchanged")
    }

    test("math: migrateMathStrings leaves a document without math strings alone") {
        let editor = try mathEditor()
        try type(editor, "no math here")
        try expect(!editor.migrateMathStrings())
    }

    test("math: migrateMathStrings skips code blocks") {
        let editor = try mathEditor()
        try type(editor, "a $b$ c")
        try expect(editor.run("toggleCodeBlock"))
        try expect(!editor.migrateMathStrings(), "a $ in code is literal")
    }

    test("math: migration positions stay right with multi-byte text before a formula") {
        let editor = try mathEditor()
        try type(editor, "héllo 🌍 $x$ tail")
        try expect(editor.migrateMathStrings())
        let math = firstMath(editor, "inlineMath")
        try expectEqual(math?.node.attrs["latex"], .string("x"))
        try expectEqual(editor.doc.child(0).textContent, "héllo 🌍 $x$ tail")
    }

    test("math: the slash-menu commands resolve by name") {
        // The slash menu dispatches by command name, so these have to be in the
        // registry under exactly the names `defaultSlashCommands` uses.
        let names = Set(defaultSlashCommands().map(\.command))
        try expect(names.contains("insertInlineMath"))
        try expect(names.contains("insertBlockMath"))

        let editor = try mathEditor()
        try expect(editor.run("insertBlockMath"), "insertBlockMath should be registered")
        try expectNotNil(firstMath(editor, "blockMath"))

        let inlineEditor = try mathEditor()
        try expect(inlineEditor.run("insertInlineMath"), "insertInlineMath should be registered")
        try expectNotNil(firstMath(inlineEditor, "inlineMath"))
    }
}
